#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

/// Real isolated parent/initializer/owner/journal mechanics, with the existing
/// synthetic binding source only. These cases cannot qualify a signed source.
/// The existing isolated state layout is root/state, not production's home/.local/state.
/// Keeping that contract avoids changing owner/path predicates for this fixture.
enum InstallationBootstrapFixtures {
    typealias B = InstallationBootstrap
    typealias H = InstallationParentPreparationFixtures
    private static func fixture(_ body: (String, StateLocation, B) throws -> Void) throws {
        try H.fixture { root, _ in
            try H.check(mkdir(root + "/state", 0o700) == 0, "bootstrap isolated state parent")
            let bootstrap = try B.testing(root: root)
            try body(root, .isolated(root: root), bootstrap)
            // Synchronous only; no queue, child, socket, command or native peer.
            // Keep the owner through assertions, before identity-bound fixture cleanup.
            withExtendedLifetime(bootstrap) {}
        }
    }
    private static func stored(_ location: StateLocation) throws -> InstallationControlRecord {
        try InstallationControlRecord.decode(Data(contentsOf: URL(fileURLWithPath:
            location.path + "/custody/installation.json")))
    }
    // Authenticated stopped helpers retain the original journal's explicit
    // profile; ordinary fixtures keep the strict default snapshot decoder.
    private static func stored(_ location: StateLocation, bootstrap: B) throws -> InstallationControlRecord {
        guard let journal = bootstrap.testingTerminalJournal() else { throw CustodyRecordError.fenced }
        let profile = journal.testingValidationProfile
        try profile.validateLocation(location)
        return try InstallationControlRecord.decode(Data(contentsOf: URL(fileURLWithPath:
            location.path + "/custody/installation.json")), profile: profile)
    }
    private static func assertGuardHeld(_ root: String) throws {
        let fd = open(root + "/state/.shadow-sync-initialization.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try H.check(fd >= 0, "bootstrap guard contender"); defer { close(fd) }
        let acquired = flock(fd, LOCK_EX | LOCK_NB), code = errno
        try H.check(acquired == -1 && code == EWOULDBLOCK, "bootstrap lost actual initializer guard")
    }
    private static func unchangedReplay(_ root: String, _ bootstrap: B) throws {
        let before = try H.snapshot(root), observation = bootstrap.observation()
        try H.refuses { try bootstrap.reserve(deadline: .init(seconds: 0.750)) }
        try H.check(bootstrap.observation() == observation && H.snapshot(root) == before,
                    "bootstrap replay changed retained failure or disk")
    }
    static func reservation() throws {
        try fixture { root, location, bootstrap in
            var reached: [B.Stage] = []
            try bootstrap.testingConfigure(mutation: { reached.append($0) })
            try bootstrap.reserve(deadline: .init(seconds: 0.750))
            try H.check(reached == B.Stage.allCases, "bootstrap actual owner ordering")
            try H.check(bootstrap.observation() == .init(stage: .reserveComplete, attempted: true, failedClosed: false),
                        "bootstrap reservation observation")
            try H.check(bootstrap.testingRetained() == [true, true, true, true, true, true], "bootstrap exact owners retained")
            let record = try stored(location)
            try H.check(record.revision == 3 && record.phase == .active && record.step?.action == .reserve
                && record.step?.status == .complete && record.step?.ordinal == 1
                && record.readinessCommit == nil && record.transaction?.intent == .install,
                "bootstrap reserve must stop before exclusive preparation")
            try H.check(!FileManager.default.fileExists(atPath: root + "/home/Applications/ShadowSync.app")
                && !FileManager.default.fileExists(atPath: root + "/home/Library/LaunchAgents/com.kleinperkins.shadow-sync.plist"),
                "bootstrap published runnable payload")
            try InstallationOwnershipFixtures.excluded(location)
            try assertGuardHeld(root)
        }
    }
    static func oneUse() throws {
        try fixture { root, location, bootstrap in
            try bootstrap.reserve(deadline: .init(seconds: 0.750))
            let before = try H.snapshot(root)
            try H.check(try bootstrap.testingOneUseRefusals(), "bootstrap original transfer or journal replay accepted")
            try H.check(try H.snapshot(root) == before, "bootstrap one-use refusal changed disk")
            try unchangedReplay(root, bootstrap)
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    static func ownerCuts() throws {
        for (index, cut) in B.Stage.allCases.enumerated() {
            try fixture { root, location, bootstrap in
                try bootstrap.testingConfigure(cut: cut)
                try H.refuses { try bootstrap.reserve(deadline: .init(seconds: 0.750)) }
                try H.check(bootstrap.observation() == .init(stage: cut, attempted: true, failedClosed: true),
                            "bootstrap failure stage replaced with success")
                let expected = [index >= 1, index >= 3, index >= 5, index >= 6, index >= 7, index >= 8]
                try H.check(bootstrap.testingRetained() == expected, "bootstrap retained owners missing at failure cut")
                if index >= 3 { try assertGuardHeld(root) }
                if index >= 4 { try InstallationOwnershipFixtures.excluded(location) }
                if index >= 9 {
                    let record = try stored(location)
                    try H.check(record.step?.action == .reserve && record.step?.status == (index == 10 ? .complete : .intent)
                        && record.readinessCommit == nil, "bootstrap invented durable failure completion")
                }
                try unchangedReplay(root, bootstrap)
            }
        }
    }
    static func parentFailure() throws {
        try fixture { root, _, bootstrap in
            try bootstrap.testingConfigure(parentCut: .afterCreate(.local))
            try H.refuses { try bootstrap.reserve(deadline: .init(seconds: 0.750)) }
            try H.check(bootstrap.observation().stage == .parentsRetained && bootstrap.observation().failedClosed,
                        "bootstrap parent cut not retained")
            try H.check(bootstrap.testingRetained() == [true, false, false, false, false, false], "bootstrap parent failure advanced")
            try H.check(FileManager.default.fileExists(atPath: root + "/home/.local"), "bootstrap deleted partial parent")
            try unchangedReplay(root, bootstrap)
        }
    }
    static func publicationFailure() throws {
        for cut in [FreshStateInitialization.Fault.afterManifest, .afterReady, .afterPublication] {
            try fixture { root, location, bootstrap in
                try bootstrap.testingConfigure(initializationFault: cut)
                try H.refuses { try bootstrap.reserve(deadline: .init(seconds: 0.750)) }
                try H.check(bootstrap.observation().stage == .initializerRetained && bootstrap.observation().failedClosed,
                            "bootstrap publication cut advanced")
                try H.check(bootstrap.testingRetained() == [true, true, false, false, false, false], "bootstrap partial initializer dropped")
                try assertGuardHeld(root)
                if cut == .afterPublication {
                    try InstallationOwnershipFixtures.excluded(location)
                    try H.check(try stored(location).phase == .initial, "bootstrap publication failure began journal")
                } else if cut == .afterReady {
                    let stages = try FileManager.default.contentsOfDirectory(atPath: root + "/state").filter { name in
                        var node = stat()
                        return name.hasPrefix(".shadow-sync-initialization.")
                            && lstat(root + "/state/" + name, &node) == 0 && node.st_mode & S_IFMT == S_IFDIR
                    }
                    try H.check(stages.count == 1, "bootstrap exact unpublished state missing")
                    let staged = StateLocation(anchorPath: root, components: ["state", stages[0]], uid: location.uid)
                    try InstallationOwnershipFixtures.excluded(staged)
                }
                try unchangedReplay(root, bootstrap)
            }
        }
    }
    static func journalFailure() throws {
        for completion in [false, true] {
            try fixture { root, location, bootstrap in
                try bootstrap.testingConfigure(journalCut: .afterReceipt, cutCompletion: completion)
                try H.refuses { try bootstrap.reserve(deadline: .init(seconds: 0.750)) }
                try H.check(bootstrap.observation().stage == (completion ? .reserveIntent : .journalRetained)
                    && bootstrap.observation().failedClosed, "bootstrap receipt cut pretended intent completion")
                try H.check(bootstrap.testingRetained().allSatisfy { $0 }, "bootstrap journal failure lost original owners")
                let record = try stored(location)
                try H.check(record.phase == (completion ? .active : .initial)
                    && record.revision == (completion ? 2 : 1), "bootstrap uncertain receipt replaced control")
                let names = try FileManager.default.contentsOfDirectory(atPath: location.path + "/custody/receipts")
                let steps = names.filter { $0.hasPrefix(InstallationStepReceipt.prefix) }
                try H.check(steps.count == (completion ? 2 : 1), "bootstrap lost pending reserve receipt")
                try unchangedReplay(root, bootstrap)
                try InstallationOwnershipFixtures.excluded(location)
            }
        }
        // The journal factory can persist preimages before it returns. Keep the
        // consumed owner and lifecycle if that factory throws; never reissue it.
        try fixture { root, location, bootstrap in
            try bootstrap.testingConfigure(captureFault: .afterDirectorySync)
            try H.refuses { try bootstrap.reserve(deadline: .init(seconds: 0.750)) }
            try H.check(bootstrap.observation().stage == .lifecycleRetained && bootstrap.observation().failedClosed,
                        "bootstrap capture-constructor failure advanced")
            try H.check(bootstrap.testingRetained() == [true, true, true, true, true, false],
                        "bootstrap unreturned journal was claimed retained")
            try H.check(try stored(location).phase == .initial, "bootstrap failed capture began reserve")
            try H.check(try !FileManager.default.contentsOfDirectory(atPath: location.path + "/custody/receipts").isEmpty,
                        "bootstrap discarded partial preimage evidence")
            try unchangedReplay(root, bootstrap)
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    static func substitution() throws {
        for cut in [B.Stage.parentsPrepared, .statePublished, .authorityRetained, .ownerConsumed, .journalRetained] {
            try fixture { root, location, bootstrap in
                let parentAttack = cut == .parentsPrepared || cut == .journalRetained
                let path = parentAttack ? root + "/home/Applications" : location.path
                let retained = root + "/retained-substituted-node"
                try bootstrap.testingConfigure(mutation: { stage in
                    if stage == cut {
                        try H.check(rename(path, retained) == 0, "bootstrap fixture retain substituted node")
                        try H.check(mkdir(path, 0o700) == 0, "bootstrap fixture replacement")
                    }
                })
                try H.refuses { try bootstrap.reserve(deadline: .init(seconds: 0.750)) }
                try H.check(bootstrap.observation().failedClosed, "bootstrap adopted substitution")
                try H.check(FileManager.default.fileExists(atPath: retained)
                    && FileManager.default.fileExists(atPath: path), "bootstrap deleted unknown replacement")
                try unchangedReplay(root, bootstrap)
                if !parentAttack {
                    // Repoint only the fixture contender at the displaced actual
                    // state. This observation grants no restoration authority.
                    let displaced = StateLocation(anchorPath: root, components: ["retained-substituted-node"], uid: location.uid)
                    try InstallationOwnershipFixtures.excluded(displaced)
                }
            }
        }
    }
    static func unsafeAndExpired() throws {
        try fixture { root, _, bootstrap in
            try H.check(mkdir(root + "/home/Applications", 0o700) == 0, "bootstrap unsafe fixture parent")
            try H.check(chmod(root + "/home/Applications", 0o777) == 0, "bootstrap unsafe fixture mode")
            let before = try H.snapshot(root)
            try H.refuses { try bootstrap.reserve(deadline: .init(seconds: 0.750)) }
            try H.check(try H.snapshot(root) == before, "bootstrap unsafe preflight changed parents")
            try H.check(bootstrap.testingRetained() == [false, false, false, false, false, false], "bootstrap unsafe preflight advanced")
            // Restore only the fixture-owned node for the existing strict cleanup.
            try H.check(chmod(root + "/home/Applications", 0o700) == 0, "bootstrap fixture mode restore")
        }
        try fixture { root, _, bootstrap in
            let before = try H.snapshot(root)
            try H.refuses { try bootstrap.reserve(deadline: .init(seconds: 0)) }
            try H.check(try H.snapshot(root) == before, "bootstrap expired deadline changed account paths")
            try unchangedReplay(root, bootstrap)
        }
    }
    static func productionRefusal() throws {
        // The testing branch precedes current publisher/account lookup. This
        // assertion intentionally performs no real account or host observation.
        try H.refuses { _ = try B.production() }
    }
    // Command-bearing continuation fixtures use the existing registered root
    // guardian. Retain the bootstrap and registry BEFORE configuration/reserve
    // can throw. Pending work prevents root and original-owner disposal.
    private static func exclusiveFixture(diagnostic: String = "installation-absent",
        fault: @escaping @Sendable (String) throws -> Void = { _ in }, afterClaim: (() throws -> Void)? = nil,
        _ body: (String, StateLocation, B, RetainedCleanupRegistry) throws -> Void) throws {
        try InstallationStorageFixtures.fixture { root, location in
            try H.check(mkdir(root + "/home", 0o700) == 0, "bootstrap exclusive fixture home")
            let custody = try RuntimeFixtureSession.installationRoot(root)
            let bootstrap = try B.testing(root: root)
            custody.retain(bootstrap)
            let registry = RetainedCleanupRegistry.testingInstance()
            custody.retain(registry)
            var failure: Error?
            do {
                let candidate = try InstallationExclusivePreparationFixtures.candidate(root)
                try bootstrap.testingConfigureExclusive(candidate: candidate, registry: registry,
                    diagnostic: diagnostic, fault: fault, afterClaim: afterClaim)
                try body(root, location, bootstrap, registry)
            } catch { failure = error }
            if registry.hasRetainedWork { registry.testingRequestCancellation() }
            let cleanup = MonotonicDeadline(seconds: 8)
            while registry.testingCount != 0 || !registry.testingOriginalHelpersReaped {
                guard !cleanup.hasExpired else { throw H.Failure(message: "bootstrap exclusive owned cleanup pending") }
                Thread.sleep(forTimeInterval: 0.005)
            }
            // Service custody is enrolled in the outer guardian before opening.
            // Join before fixture-owned named cleanup; a failure retains root,
            // bootstrap and journal for the guardian instead of deleting live work.
            try bootstrap.testingReleaseFailedStartAliases()
            try bootstrap.testingCloseReadiness(deadline: cleanup)
            try bootstrap.testingRemoveReadinessEndpoint()
            try registry.testingDispose()
            if let failure { throw failure }
        }
    }
    private static func assertExclusiveFence(_ root: String, _ location: StateLocation, _ bootstrap: B) throws {
        try H.check(bootstrap.testingRetained() == [true, true, true, true, true, true],
                    "bootstrap exclusive lost original owners")
        try assertGuardHeld(root)
        try InstallationOwnershipFixtures.excluded(location)
        let record = try stored(location)
        try H.check(record.phase == .active && record.readinessCommit == nil,
                    "bootstrap exclusive opened staged admission")
    }
    private static func unchangedExclusiveReplay(_ root: String, _ bootstrap: B) throws {
        let disk = try H.snapshot(root), reserve = bootstrap.observation(), exclusive = bootstrap.exclusiveObservation()
        try H.refuses { try bootstrap.prepareExclusive() }
        try H.refuses { try bootstrap.reserve(deadline: .init(seconds: 30)) }
        try H.check(try H.snapshot(root) == disk && bootstrap.observation() == reserve
            && bootstrap.exclusiveObservation() == exclusive, "bootstrap exclusive replay changed retained outcome")
    }
    static func exclusiveBeforeReserve() throws {
        try fixture { root, location, bootstrap in
            let disk = try H.snapshot(root), observation = bootstrap.observation()
            try H.refuses { try bootstrap.prepareExclusive() }
            try H.check(try H.snapshot(root) == disk && bootstrap.observation() == observation
                && bootstrap.exclusiveObservation() == .notAttempted, "bootstrap exclusive before-reserve mutated state")
            try bootstrap.reserve(deadline: .init(seconds: 0.750))
            try H.check(try stored(location).step?.action == .reserve
                && bootstrap.exclusiveObservation() == .notAttempted, "bootstrap exclusive refusal consumed reservation")
        }
    }
    /// The lifecycle fault callback is Sendable. Its action log therefore
    /// owns synchronization for every append and snapshot.
    private final class ExclusiveActions: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ value: String) {
            lock.lock(); values.append(value); lock.unlock()
        }
        func snapshot() -> [String] {
            lock.lock(); defer { lock.unlock() }; return values
        }
    }
    static func exclusiveOrdered() throws {
        let actions = ExclusiveActions()
        try exclusiveFixture(fault: { stage in
            if stage.hasPrefix("exclusive-after-action-") { actions.append(stage) }
        }) { root, location, bootstrap, registry in
            let deadline = MonotonicDeadline(seconds: 30)
            try bootstrap.reserve(deadline: deadline)
            let reserved = try stored(location)
            let log = try Data(contentsOf: URL(fileURLWithPath: location.path + "/latest.log"))
            try bootstrap.prepareExclusive()
            let prepared = try stored(location)
            try H.check(actions.snapshot() == [InstallationAction.stageApplication, .stagePlist, .retireApplication, .retirePlist,
                .retireCoordination, .translateState, .moveStateForward, .promoteApplication, .promotePlist]
                .map { "exclusive-after-action-" + $0.rawValue }, "bootstrap exclusive action order")
            try H.check(reserved.revision == 3 && prepared.revision == 23
                && prepared.transaction?.id == reserved.transaction?.id
                && prepared.state == reserved.state && prepared.transaction?.candidate == reserved.transaction?.candidate,
                "bootstrap exclusive replaced original transaction")
            try H.check(prepared.step?.action == .promotePlist && prepared.step?.status == .complete
                && prepared.step?.ordinal == 11 && bootstrap.exclusiveObservation() == .complete
                && !bootstrap.observation().failedClosed, "bootstrap exclusive exact stop missing")
            try H.check(prepared.transaction?.slots.images[.application]?.node != nil
                && prepared.transaction?.slots.images[.launchPlist]?.node != nil
                && prepared.transaction?.slots.images[.applicationIncoming]?.node == nil
                && prepared.transaction?.slots.images[.plistIncoming]?.node == nil, "bootstrap exclusive postimages missing")
            let artifact = try BundleArtifactIdentity.inspect(bundlePath: root + "/home/Applications/ShadowSync.app", requireProduction: true)
            try H.check(artifact.canonicalSHA256 == prepared.transaction?.candidate?.bundleDigest
                && Data(contentsOf: URL(fileURLWithPath: location.path + "/latest.log")) == log,
                "bootstrap exclusive changed candidate or state preimage")
            try H.check(!registry.hasRetainedWork && registry.testingOriginalHelpersReaped,
                        "bootstrap exclusive diagnostic not retired")
            try H.check(try bootstrap.testingOneUseRefusals(), "bootstrap exclusive original owner replay accepted")
            try assertExclusiveFence(root, location, bootstrap)
            try unchangedExclusiveReplay(root, bootstrap)
        }
    }
    static func exclusiveOriginalDeadline() throws {
        try exclusiveFixture { root, location, bootstrap, registry in
            let original = MonotonicDeadline(seconds: 0.750)
            try bootstrap.reserve(deadline: original)
            let disk = try H.snapshot(root), reserved = try stored(location)
            // A fresh caller budget cannot replace the reservation's deadline.
            try H.refuses { try bootstrap.reserve(deadline: .init(seconds: 30)) }
            while !original.hasExpired { Thread.sleep(forTimeInterval: 0.001) }
            try H.refuses { try bootstrap.prepareExclusive() }
            try H.check(try H.snapshot(root) == disk && stored(location) == reserved
                && bootstrap.exclusiveObservation() == .failed && bootstrap.observation().failedClosed,
                "bootstrap exclusive extended original deadline")
            try H.check(!registry.hasRetainedWork && registry.testingOriginalHelpersReaped,
                        "bootstrap exclusive expired invocation started command")
            try assertExclusiveFence(root, location, bootstrap)
            try unchangedExclusiveReplay(root, bootstrap)
        }
    }
    private final class ExclusiveGate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    }
    private final class ExclusiveCall: @unchecked Sendable {
        let bootstrap: B
        init(_ bootstrap: B) { self.bootstrap = bootstrap }
    }
    static func exclusiveConcurrentReplay() throws {
        let gate = ExclusiveGate(), deadline = MonotonicDeadline(seconds: 30)
        try exclusiveFixture(afterClaim: {
            gate.entered.signal()
            guard gate.release.wait(timeout: .init(uptimeNanoseconds: deadline.absoluteUptimeNanoseconds)) == .success else {
                throw CustodyRecordError.busy
            }
        }) { root, location, bootstrap, _ in
            try bootstrap.reserve(deadline: deadline)
            let custody = try RuntimeFixtureSession.installationRoot(root), call = ExclusiveCall(bootstrap)
            let work = custody.startWork { try call.bootstrap.prepareExclusive() }
            defer { gate.release.signal() }
            try H.check(gate.entered.wait(timeout: .init(uptimeNanoseconds: deadline.absoluteUptimeNanoseconds)) == .success,
                        "bootstrap exclusive claimed work not reached")
            // These synchronous observations/replays would deadlock if the
            // bootstrap mutex spanned the actual continuation work.
            try H.check(bootstrap.exclusiveObservation() == .running, "bootstrap exclusive running claim missing")
            try unchangedExclusiveReplay(root, bootstrap)
            try assertExclusiveFence(root, location, bootstrap)
            gate.release.signal()
            try work.value(deadline: deadline)
            try H.check(bootstrap.exclusiveObservation() == .complete && stored(location).step?.action == .promotePlist,
                        "bootstrap exclusive concurrent refusal replaced first outcome")
            try unchangedExclusiveReplay(root, bootstrap)
        }
    }
    static func exclusivePartialFailures() throws {
        for action in [InstallationAction.stageApplication, .stagePlist, .promoteApplication, .promotePlist] {
            try exclusiveFixture(fault: { stage in
                if stage == "exclusive-after-action-" + action.rawValue { throw CustodyRecordError.injectedFailure }
            }) { root, location, bootstrap, registry in
                try bootstrap.reserve(deadline: .init(seconds: 30))
                let reserved = try stored(location)
                try H.refuses { try bootstrap.prepareExclusive() }
                let partial = try stored(location)
                try H.check(partial.transaction?.id == reserved.transaction?.id
                    && partial.step?.action == action && partial.step?.status == .intent
                    && bootstrap.exclusiveObservation() == .failed && bootstrap.observation().failedClosed,
                    "bootstrap exclusive partial effect invented completion")
                let promoted = action == .promoteApplication || action == .promotePlist
                try H.check(FileManager.default.fileExists(atPath: root + "/home/Applications/"
                    + (promoted ? "ShadowSync.app" : ".ShadowSync.app.incoming")), "bootstrap exclusive partial bytes discarded")
                try H.check(!registry.hasRetainedWork && registry.testingOriginalHelpersReaped,
                            "bootstrap exclusive partial action retained diagnostic")
                try assertExclusiveFence(root, location, bootstrap)
                try unchangedExclusiveReplay(root, bootstrap)
            }
        }
    }
    static func exclusiveSubstitution() throws {
        try exclusiveFixture { root, location, bootstrap, _ in
            try bootstrap.reserve(deadline: .init(seconds: 30))
            let reserved = try stored(location), path = root + "/home/Applications", retained = root + "/retained-applications"
            try H.check(rename(path, retained) == 0 && mkdir(path, 0o700) == 0, "bootstrap exclusive substitute parent")
            let disk = try H.snapshot(root)
            try H.refuses { try bootstrap.prepareExclusive() }
            try H.check(try H.snapshot(root) == disk && stored(location) == reserved
                && bootstrap.exclusiveObservation() == .failed, "bootstrap exclusive adopted replacement parent")
            try assertExclusiveFence(root, location, bootstrap)
            try unchangedExclusiveReplay(root, bootstrap)
        }
        let cut = InstallationExclusivePreparationFixtures.Cut()
        cut.action = "exclusive-before-promote-application"; cut.replaceApplication = true
        try exclusiveFixture(fault: { try cut.visit($0) }) { root, location, bootstrap, _ in
            cut.root = root
            try bootstrap.reserve(deadline: .init(seconds: 30))
            try H.refuses { try bootstrap.prepareExclusive() }
            let partial = try stored(location)
            try H.check(partial.step?.action == .promoteApplication && partial.step?.status == .intent
                && !FileManager.default.fileExists(atPath: root + "/home/Applications/ShadowSync.app")
                && FileManager.default.fileExists(atPath: root + "/replaced-incoming-app"),
                "bootstrap exclusive promoted substituted candidate")
            let replacement = try BundleArtifactIdentity.inspect(
                bundlePath: root + "/home/Applications/.ShadowSync.app.incoming", requireProduction: true)
            try H.check(replacement.canonicalSHA256 == partial.transaction?.candidate?.bundleDigest
                && bootstrap.exclusiveObservation() == .failed && bootstrap.observation().failedClosed,
                "bootstrap exclusive replacement setup or failure latch missing")
            try assertExclusiveFence(root, location, bootstrap)
            try unchangedExclusiveReplay(root, bootstrap)
        }
    }
    static func exclusiveDiagnosticFailure() throws {
        try exclusiveFixture(diagnostic: "complete") { root, location, bootstrap, registry in
            try bootstrap.reserve(deadline: .init(seconds: 30))
            try H.refuses { try bootstrap.prepareExclusive() }
            let partial = try stored(location)
            try H.check(partial.step?.action == .drainPrior && partial.step?.status == .intent
                && bootstrap.exclusiveObservation() == .failed && bootstrap.observation().failedClosed,
                "bootstrap exclusive accepted unproved service absence")
            try H.check(!registry.hasRetainedWork && registry.testingOriginalHelpersReaped,
                        "bootstrap exclusive failed diagnostic not retired")
            try assertExclusiveFence(root, location, bootstrap)
            try unchangedExclusiveReplay(root, bootstrap)
        }
    }
    private static func sharedProbe(_ location: StateLocation, _ name: String, succeeds: Bool) throws {
        let fd = open(location.path + "/" + name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try H.check(fd >= 0, "bootstrap staged shared probe"); defer { close(fd) }
        let result = flock(fd, LOCK_SH | LOCK_NB), code = errno
        try H.check(succeeds ? result == 0 : result == -1 && code == EWOULDBLOCK,
                    "bootstrap staged shared admission")
    }
    private static func stagedFence(_ location: StateLocation, _ bootstrap: B) throws {
        let current = try stored(location)
        try H.check(current.phase == .active && current.readinessCommit == nil,
                    "bootstrap staged transition invented readiness")
        try InstallationOwnershipFixtures.excluded(location)
        try sharedProbe(location, "operation.lock", succeeds: false)
        try H.check(bootstrap.testingRetained()[3], "bootstrap staged lost consumed owner")
    }
    private static func refusedStagedReplay(_ root: String, _ bootstrap: B) throws {
        let disk = try H.snapshot(root), observation = bootstrap.observation(), transfer = bootstrap.stagedObservation()
        try H.refuses { try bootstrap.transferToStagedAdmission() }
        try H.refuses { try bootstrap.prepareExclusive() }
        try H.refuses { try bootstrap.reserve(deadline: .init(seconds: 30)) }
        try H.check(try H.snapshot(root) == disk && bootstrap.observation() == observation
            && bootstrap.stagedObservation() == transfer, "bootstrap staged replay replaced outcome")
    }
    static func stagedBeforePreparation() throws {
        try fixture { root, location, bootstrap in
            try H.refuses { try bootstrap.transferToStagedAdmission() }
            try bootstrap.reserve(deadline: .init(seconds: 0.750))
            let disk = try H.snapshot(root)
            try H.refuses { try bootstrap.transferToStagedAdmission() }
            try H.check(try H.snapshot(root) == disk && bootstrap.stagedObservation() == .notAttempted
                && stored(location).step?.action == .reserve && !bootstrap.observation().failedClosed,
                "bootstrap staged wrong order mutated reservation")
        }
    }
    // These same callbacks serve the transfer assertions and the early-failure
    // lifetime regression. Fixture custody, not a self-capture, retains the owner
    // until real registry drainage and identity-bound root cleanup finish.
    private static func configureStagedPositive(_ root: String, _ location: StateLocation, _ bootstrap: B) throws {
        try bootstrap.testingConfigureStagedTransfer(checkpoint: { [weak bootstrap] point in
            guard let bootstrap else { throw H.Failure(message: "bootstrap staged callback owner missing") }
            if point == .aliasesReleased {
                try H.check(bootstrap.testingStagedRetention().prefix(3).allSatisfy { $0 },
                            "bootstrap staged actual aliases remain")
                // Prove the actual initializer guard was released, rather
                // than merely hiding its owner from an observation array.
                let fd = open(root + "/state/.shadow-sync-initialization.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                try H.check(fd >= 0, "bootstrap released initializer probe"); defer { close(fd) }
                try H.check(flock(fd, LOCK_EX | LOCK_NB) == 0, "bootstrap initializer still live")
            }
        }, acquisition: { [weak bootstrap] in
            guard let bootstrap else { throw H.Failure(message: "bootstrap staged callback owner missing") }
            try H.check(bootstrap.stagedObservation() == .running, "bootstrap staged mutex spans acquisition")
            try stagedFence(location, bootstrap)
        })
    }
    private static func configureStagedReentrant(_ bootstrap: B) throws {
        try bootstrap.testingConfigureStagedTransfer(checkpoint: { [weak bootstrap] point in
            guard let bootstrap else { throw H.Failure(message: "bootstrap staged callback owner missing") }
            if point == .claimed {
                try H.check(bootstrap.stagedObservation() == .running, "bootstrap staged claim invisible")
                try H.refuses { try bootstrap.transferToStagedAdmission() }
                try H.refuses { try bootstrap.prepareExclusive() }
            }
        })
    }
    private static func configureStagedFailure(_ location: StateLocation, _ bootstrap: B, postflight: Bool) throws {
        let fail: () throws -> Void = { [weak bootstrap] in
            guard let bootstrap else { throw H.Failure(message: "bootstrap staged callback owner missing") }
            try H.check(bootstrap.testingStagedRetention().prefix(3).allSatisfy { $0 },
                        "bootstrap transfer hook retained actual exclusive aliases")
            try stagedFence(location, bootstrap)
            throw CustodyRecordError.injectedFailure
        }
        try bootstrap.testingConfigureStagedTransfer(acquisition: postflight ? nil : fail,
            postflight: postflight ? fail : nil)
    }
    private static func stagedCallbackLifetime(reserveFailure: Bool,
        configure: (String, StateLocation, B) throws -> Void) throws {
        weak var releasedBootstrap: B?
        var initializerProbe: Int32 = -1
        var removedRoot = ""
        defer { if initializerProbe >= 0 { close(initializerProbe) } }
        try exclusiveFixture(afterClaim: { throw CustodyRecordError.injectedFailure }) { root, location, bootstrap, registry in
            releasedBootstrap = bootstrap; removedRoot = root
            try configure(root, location, bootstrap)
            if reserveFailure { try bootstrap.testingConfigure(cut: .reserveComplete) }
            do {
                try bootstrap.reserve(deadline: .init(seconds: 30))
                try bootstrap.prepareExclusive()
                throw H.Failure(message: "bootstrap pre-transfer injection not reached")
            } catch CustodyRecordError.injectedFailure {}
            try H.check(bootstrap.observation().failedClosed && bootstrap.stagedObservation() == .notAttempted
                && bootstrap.exclusiveObservation() == (reserveFailure ? .notAttempted : .failed),
                "bootstrap pre-transfer failure stage changed")
            try assertExclusiveFence(root, location, bootstrap)
            try sharedProbe(location, "operation.lock", succeeds: false)
            try H.check(!registry.hasRetainedWork && registry.testingCount == 0 && registry.testingOriginalHelpersReaped,
                        "bootstrap pre-transfer registry not drained")
            initializerProbe = open(root + "/state/.shadow-sync-initialization.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            try H.check(initializerProbe >= 0, "bootstrap pre-transfer initializer probe")
            let acquired = flock(initializerProbe, LOCK_EX | LOCK_NB), code = errno
            try H.check(acquired == -1 && code == EWOULDBLOCK,
                        "bootstrap pre-transfer initializer released before cleanup")
            // No transfer call or callback clearing: exercise the actual failure
            // path that formerly retained the bootstrap through its own closure.
        }
        try H.check(releasedBootstrap == nil, "bootstrap pre-transfer callback retained owner after cleanup")
        try H.check(!FileManager.default.fileExists(atPath: removedRoot), "bootstrap pre-transfer root cleanup incomplete")
        var retired = stat()
        try H.check(fstat(initializerProbe, &retired) == 0 && retired.st_nlink == 0,
                    "bootstrap pre-transfer initializer probe lost removed inode")
        try H.check(flock(initializerProbe, LOCK_EX | LOCK_NB) == 0,
                    "bootstrap pre-transfer initializer remains locked after cleanup")
    }
    static func stagedPositive() throws {
        try exclusiveFixture { root, location, bootstrap, registry in
            try configureStagedPositive(root, location, bootstrap)
            try bootstrap.reserve(deadline: .init(seconds: 30)); try bootstrap.prepareExclusive()
            let prepared = try stored(location)
            try bootstrap.transferToStagedAdmission()
            let staged = try stored(location)
            try H.check(bootstrap.stagedObservation() == .complete && !bootstrap.observation().failedClosed
                && bootstrap.exclusiveObservation() == .complete && bootstrap.observation().stage == .reserveComplete,
                "bootstrap staged observation conflated stages")
            try H.check(bootstrap.testingRetained() == [true, false, true, true, false, false]
                && bootstrap.testingStagedRetention().allSatisfy { $0 }
                && bootstrap.testingStagedIdentity(), "bootstrap staged same actual owners/intent missing")
            try H.check(staged.transaction?.id == prepared.transaction?.id && staged.state == prepared.state
                && staged.step?.action == .openStagedAdmission && staged.step?.status == .intent
                && staged.step?.ordinal == 12 && staged.revision == prepared.revision + 1,
                "bootstrap staged replaced transaction or fabricated completion")
            try H.check(!registry.hasRetainedWork && registry.testingCount == 0 && registry.testingOriginalHelpersReaped,
                        "bootstrap staged actual preparation registry pending")
            try sharedProbe(location, "latest.log", succeeds: true)
            try sharedProbe(location, "lifecycle.lock", succeeds: true)
            try InstallationOwnershipFixtures.excluded(location, name: "run.lock", expected: false)
            try stagedFence(location, bootstrap); try refusedStagedReplay(root, bootstrap)
        }
    }
    static func stagedOriginalDeadline() throws {
        try exclusiveFixture { root, location, bootstrap, _ in
            // Expire precisely after real preparation, using the invocation's
            // same budget; the continuation accepts no replacement deadline.
            let original = MonotonicDeadline(seconds: 3)
            try bootstrap.reserve(deadline: original); try bootstrap.prepareExclusive()
            let disk = try H.snapshot(root), prepared = try stored(location)
            while !original.hasExpired { Thread.sleep(forTimeInterval: 0.001) }
            try H.refuses { try bootstrap.transferToStagedAdmission() }
            try H.check(try H.snapshot(root) == disk && stored(location) == prepared
                && bootstrap.stagedObservation() == .failed && bootstrap.observation().failedClosed,
                "bootstrap staged extended original deadline")
            try stagedFence(location, bootstrap); try refusedStagedReplay(root, bootstrap)
        }
        try exclusiveFixture { root, location, bootstrap, _ in
            let original = MonotonicDeadline(seconds: 3)
            try bootstrap.testingConfigureStagedTransfer(acquisition: {
                while !original.hasExpired { Thread.sleep(forTimeInterval: 0.001) }
            })
            try bootstrap.reserve(deadline: original); try bootstrap.prepareExclusive()
            try H.refuses { try bootstrap.transferToStagedAdmission() }
            try H.check(bootstrap.stagedObservation() == .failed && bootstrap.observation().failedClosed
                && bootstrap.testingStagedRetention() == [true, true, true, true, false, true, true]
                && stored(location).step?.action == .openStagedAdmission
                && stored(location).step?.status == .intent,
                "bootstrap acquisition extended original deadline or lost durable fence")
            try stagedFence(location, bootstrap); try refusedStagedReplay(root, bootstrap)
        }
    }
    static func stagedReentrantClaim() throws {
        try exclusiveFixture { root, location, bootstrap, _ in
            try configureStagedReentrant(bootstrap)
            try bootstrap.reserve(deadline: .init(seconds: 30)); try bootstrap.prepareExclusive()
            try bootstrap.transferToStagedAdmission()
            try H.check(bootstrap.stagedObservation() == .complete, "bootstrap staged reentry displaced first call")
            try stagedFence(location, bootstrap); try refusedStagedReplay(root, bootstrap)
        }
    }
    static func stagedLiveBorrowRefuses() throws {
        try exclusiveFixture { root, location, bootstrap, _ in
            try bootstrap.testingConfigureStagedTransfer(holdBorrow: true)
            defer { bootstrap.testingReleaseTransferBorrow() }
            try bootstrap.reserve(deadline: .init(seconds: 30)); try bootstrap.prepareExclusive()
            try H.refuses { try bootstrap.transferToStagedAdmission() }
            try H.check(bootstrap.stagedObservation() == .failed && bootstrap.observation().failedClosed
                && bootstrap.testingStagedRetention() == [true, true, true, true, false, true, true]
                && bootstrap.testingStagedIdentity(), "bootstrap live borrow did not close actual owner")
            try sharedProbe(location, "lifecycle.lock", succeeds: false)
            bootstrap.testingReleaseTransferBorrow()
            try stagedFence(location, bootstrap); try refusedStagedReplay(root, bootstrap)
        }
    }
    static func stagedPendingRegistryRefuses() throws {
        try exclusiveFixture { root, location, bootstrap, registry in
            try bootstrap.reserve(deadline: .init(seconds: 30)); try bootstrap.prepareExclusive()
            // A separate disposable read scope creates actual pending work in
            // the SAME registry, with no lease alias of this installation.
            try InstallationStorageFixtures.fixture { otherRoot, otherLocation in
                try TestIsolation.initializeState(at: otherLocation)
                let original = try RunAuthority.acquireRun(at: otherLocation)
                do { try CustodyCatalogStore.testingInitialize(leases: original.retainCommandLeases(), root: otherRoot) }
                catch { original.release(); throw error }
                original.release()
                let scope = try CustodyMetadataScope(leases: .retainReadLeases(at: otherLocation),
                    releaseSHA256: String(repeating: "c", count: 64), generation: RunIdentity.make())
                let cwd = try scope.leases.duplicateStateDirectory().0
                let resources = try CustodyRequestResources(scope: scope, kind: .launchctlRead,
                    arguments: ["resist"], environment: [:],
                    budget: .make(kind: .launchctlRead, workSeconds: 2, termSeconds: 0.1, killSeconds: 0.2, receiptSeconds: 0.2),
                    stdoutLimit: 65_536, stderrLimit: 65_536, workingDirectory: cwd)
                try RuntimeFixtureSession.installationRoot(otherRoot).retain(registry)
                let handle = try registry.start(resources: resources, helper: .testingCustodian())
                var failure: Error?
                do {
                    let ready = MonotonicDeadline(seconds: 3)
                    while handle.snapshot().stdout.isEmpty {
                        guard !ready.hasExpired else { throw H.Failure(message: "bootstrap pending registry fixture not running") }
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                    try H.check(registry.hasRetainedWork, "bootstrap pending registry reservation absent")
                    try H.refuses { try bootstrap.transferToStagedAdmission() }
                    try H.check(bootstrap.testingStagedRetention() == [true, true, true, true, false, true, true]
                        && bootstrap.testingStagedIdentity() && bootstrap.stagedObservation() == .failed,
                        "bootstrap accepted pending actual registry")
                    try stagedFence(location, bootstrap); try refusedStagedReplay(root, bootstrap)
                } catch { failure = error }
                handle.cancel(); _ = handle.wait(); scope.close()
                let cleanup = MonotonicDeadline(seconds: 8)
                while registry.hasRetainedWork || !registry.testingOriginalHelpersReaped {
                    guard !cleanup.hasExpired else { throw H.Failure(message: "bootstrap pending registry owned cleanup") }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                if let failure { throw failure }
            }
        }
    }
    static func stagedIntentCuts() throws {
        for receiptCut in [false, true] {
            try exclusiveFixture { root, location, bootstrap, _ in
                try bootstrap.testingConfigureStagedTransfer(intentReceiptCut: receiptCut, checkpoint: { point in
                    if !receiptCut && point == .intentRetained { throw CustodyRecordError.injectedFailure }
                })
                try bootstrap.reserve(deadline: .init(seconds: 30)); try bootstrap.prepareExclusive()
                try H.refuses { try bootstrap.transferToStagedAdmission() }
                let current = try stored(location)
                try H.check(current.step?.action == (receiptCut ? .promotePlist : .openStagedAdmission)
                    && current.step?.status == (receiptCut ? .complete : .intent)
                    && bootstrap.testingRetained().allSatisfy { $0 }
                    && bootstrap.stagedObservation() == .failed && bootstrap.observation().failedClosed,
                    "bootstrap intent cut invented transfer or dropped original owners")
                let receipts = try FileManager.default.contentsOfDirectory(atPath: location.path + "/custody/receipts")
                try H.check(receipts.filter { $0.hasPrefix(InstallationStepReceipt.prefix) }.count == 23,
                            "bootstrap intent cut discarded durable receipt")
                try stagedFence(location, bootstrap); try refusedStagedReplay(root, bootstrap)
            }
        }
    }
    static func stagedIdentityDrift() throws {
        try exclusiveFixture { root, location, bootstrap, _ in
            let path = location.path + "/custody/installation.json", retained = root + "/bootstrap-retained-control"
            try bootstrap.testingConfigureStagedTransfer(acquisition: {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                try H.check(rename(path, retained) == 0, "bootstrap staged retain control")
                try bytes.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
                try H.check(chmod(path, 0o600) == 0, "bootstrap staged replacement mode")
            })
            try bootstrap.reserve(deadline: .init(seconds: 30)); try bootstrap.prepareExclusive()
            try H.refuses { try bootstrap.transferToStagedAdmission() }
            try H.check(bootstrap.stagedObservation() == .failed && bootstrap.observation().failedClosed,
                        "bootstrap staged adopted same-byte replacement")
            try H.check(unlink(path) == 0 && rename(retained, path) == 0, "bootstrap staged restore fixture control")
            try stagedFence(location, bootstrap); try refusedStagedReplay(root, bootstrap)
        }
    }
    static func stagedTransferFailures() throws {
        for reserveFailure in [true, false] {
            try stagedCallbackLifetime(reserveFailure: reserveFailure, configure: configureStagedPositive)
            try stagedCallbackLifetime(reserveFailure: reserveFailure) { _, _, bootstrap in
                try configureStagedReentrant(bootstrap)
            }
            for postflight in [false, true] {
                try stagedCallbackLifetime(reserveFailure: reserveFailure) { _, location, bootstrap in
                    try configureStagedFailure(location, bootstrap, postflight: postflight)
                }
            }
        }
        for postflight in [false, true] {
            try exclusiveFixture { root, location, bootstrap, _ in
                try configureStagedFailure(location, bootstrap, postflight: postflight)
                try bootstrap.reserve(deadline: .init(seconds: 30)); try bootstrap.prepareExclusive()
                try H.refuses { try bootstrap.transferToStagedAdmission() }
                try H.check(bootstrap.stagedObservation() == .failed && bootstrap.observation().failedClosed
                    && bootstrap.testingStagedRetention() == [true, true, true, true, false, true, true],
                    "bootstrap transfer failure lost intent/owner fence")
                try H.check(try stored(location).step?.action == .openStagedAdmission
                    && stored(location).step?.status == .intent, "bootstrap failed transfer invented completion")
                try stagedFence(location, bootstrap); try refusedStagedReplay(root, bootstrap)
            }
        }
    }


    private static func journalTransferred(_ bootstrap: B, deadline: MonotonicDeadline = .init(seconds: 30)) throws {
        try bootstrap.reserve(deadline: deadline)
        try bootstrap.prepareExclusive()
        try bootstrap.transferToStagedAdmission()
    }
    private static func journalIntentFence(_ location: StateLocation, _ bootstrap: B) throws {
        let current = try stored(location)
        try H.check(current.step?.action == .openStagedAdmission && current.step?.status == .intent
            && current.step?.ordinal == 12 && current.readinessCommit == nil,
            "bootstrap journal completed admission or invented readiness")
        try stagedFence(location, bootstrap)
    }
    private static func journalReplayRefuses(_ root: String, _ bootstrap: B) throws {
        let disk = try H.snapshot(root), observation = bootstrap.observation()
        let continuation = bootstrap.stagedJournalObservation(), retained = bootstrap.testingStagedJournalRetention()
        try H.refuses { try bootstrap.continueStagedJournal() }
        try H.check(try H.snapshot(root) == disk && bootstrap.observation() == observation
            && bootstrap.stagedJournalObservation() == continuation && bootstrap.testingStagedJournalRetention() == retained,
            "bootstrap journal replay reconstructed or discarded actual owners")
        try refusedStagedReplay(root, bootstrap)
    }
    static func journalBeforeTransfer() throws {
        try exclusiveFixture { root, _, bootstrap, _ in
            func refusesUnclaimed() throws {
                let disk = try H.snapshot(root), observation = bootstrap.observation()
                let retained = bootstrap.testingRetained(), staged = bootstrap.testingStagedRetention()
                try H.refuses { try bootstrap.continueStagedJournal() }
                try H.check(try H.snapshot(root) == disk && bootstrap.observation() == observation
                    && bootstrap.testingRetained() == retained && bootstrap.testingStagedRetention() == staged
                    && bootstrap.stagedJournalObservation() == .notAttempted,
                    "bootstrap journal invalid order consumed ownership or continuation")
            }
            try refusesUnclaimed()
            try bootstrap.reserve(deadline: .init(seconds: 30)); try refusesUnclaimed()
            try bootstrap.prepareExclusive(); try refusesUnclaimed()
            // Preclaim refusals leave the one real continuation available.
            try bootstrap.transferToStagedAdmission(); try bootstrap.continueStagedJournal()
            try H.check(bootstrap.stagedJournalObservation() == .complete, "bootstrap journal preclaim refusal poisoned success")
        }
    }
    static func journalPositive() throws {
        try exclusiveFixture { root, location, bootstrap, registry in
            try journalTransferred(bootstrap)
            let disk = try H.snapshot(root), intent = try stored(location)
            try bootstrap.continueStagedJournal()
            try H.check(bootstrap.stagedJournalObservation() == .complete && !bootstrap.observation().failedClosed
                && bootstrap.stagedObservation() == .complete && bootstrap.exclusiveObservation() == .complete,
                "bootstrap journal conflated transfer, continuation or admission")
            try H.check(bootstrap.testingStagedJournalRetention() == [true, true, true, true, true, false]
                && bootstrap.testingStagedRetention().allSatisfy { $0 } && bootstrap.testingStagedIdentity(),
                "bootstrap journal did not retain same consumed owner, intent and actual journal")
            try H.check(try H.snapshot(root) == disk && stored(location) == intent,
                        "bootstrap journal changed exact nodes, receipt bytes or file set")
            try H.check(!registry.hasRetainedWork && registry.testingCount == 0 && registry.testingOriginalHelpersReaped,
                        "bootstrap journal created command or registry work")
            try H.check(try !bootstrap.testingStagedJournalStartsRefused(), "bootstrap successful journal closed staged admission")
            try journalIntentFence(location, bootstrap); try journalReplayRefuses(root, bootstrap)
        }
    }
    static func journalReentrantReplay() throws {
        try exclusiveFixture { root, location, bootstrap, _ in
            var claims = 0, returns = 0
            try bootstrap.testingConfigureStagedJournal(afterClaim: { [weak bootstrap] in
                guard let bootstrap else { throw H.Failure(message: "bootstrap journal claim callback owner missing") }
                claims += 1
                try H.check(bootstrap.stagedJournalObservation() == .running
                    && !bootstrap.testingStagedJournalRetention()[0], "bootstrap journal claim hidden or constructor ran early")
                try journalReplayRefuses(root, bootstrap)
            }, afterReturn: { [weak bootstrap] in
                guard let bootstrap else { throw H.Failure(message: "bootstrap journal return callback owner missing") }
                returns += 1
                try H.check(bootstrap.stagedJournalObservation() == .running
                    && bootstrap.testingStagedJournalRetention()[0], "bootstrap journal return not retained before postflight")
                try journalReplayRefuses(root, bootstrap)
            })
            try journalTransferred(bootstrap); try bootstrap.continueStagedJournal()
            try journalReplayRefuses(root, bootstrap)
            try H.check(claims == 1 && returns == 1 && bootstrap.stagedJournalObservation() == .complete,
                        "bootstrap journal reentry invoked a second constructor or hook")
            try journalIntentFence(location, bootstrap)
        }
    }
    static func journalOriginalDeadline() throws {
        // Expire before continuation, after claim, and after actual return.
        // All three use reserve's absolute budget; no replacement is accepted.
        for point in 0..<3 {
            try exclusiveFixture { root, location, bootstrap, _ in
                let original = MonotonicDeadline(seconds: 3)
                let expire: () throws -> Void = {
                    while !original.hasExpired { Thread.sleep(forTimeInterval: 0.001) }
                }
                try bootstrap.testingConfigureStagedJournal(afterClaim: point == 1 ? expire : nil,
                    afterReturn: point == 2 ? expire : nil)
                try journalTransferred(bootstrap, deadline: original)
                let disk = try H.snapshot(root)
                if point == 0 { try expire() }
                try H.refuses { try bootstrap.continueStagedJournal() }
                try H.check(bootstrap.stagedJournalObservation() == .failed && bootstrap.observation().failedClosed
                    && bootstrap.testingStagedJournalRetention() == [point == 2, true, true, true, true, false]
                    && bootstrap.testingStagedJournalStartsRefused(), "bootstrap journal refreshed budget or lost returned owner")
                try H.check(try H.snapshot(root) == disk, "bootstrap journal expired continuation changed disk")
                try journalIntentFence(location, bootstrap); try journalReplayRefuses(root, bootstrap)
            }
        }
    }
    static func journalDurableDrift() throws {
        // Same-byte replacement still changes the pinned durable node. The app
        // root replacement tests detached prepared-slot identity independently.
        for kind in ["control", "catalog", "guard", "receipt", "slot"] {
            try exclusiveFixture { root, location, bootstrap, _ in
                try journalTransferred(bootstrap)
                let path: String
                if kind == "slot" { path = root + "/home/Applications/ShadowSync.app" }
                else if kind == "receipt" {
                    let names = try FileManager.default.contentsOfDirectory(atPath: location.path + "/custody/receipts")
                    guard let name = names.sorted().first(where: { $0.hasPrefix(InstallationStepReceipt.prefix) }) else {
                        throw H.Failure(message: "bootstrap journal actual receipt missing")
                    }
                    path = location.path + "/custody/receipts/" + name
                } else {
                    let name = kind == "control" ? "installation.json" : (kind == "catalog" ? "catalog.json" : "catalog.lock")
                    path = location.path + "/custody/" + name
                }
                let retained = root + "/bootstrap-journal-retained-node"
                let bytes = kind == "slot" ? nil : try Data(contentsOf: URL(fileURLWithPath: path))
                try H.check(rename(path, retained) == 0, "bootstrap journal retain substituted node")
                if let bytes {
                    try bytes.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
                    try H.check(chmod(path, 0o600) == 0, "bootstrap journal replacement mode")
                } else { try H.check(mkdir(path, 0o700) == 0, "bootstrap journal replacement slot") }
                let disk = try H.snapshot(root)
                try H.refuses { try bootstrap.continueStagedJournal() }
                try H.check(bootstrap.stagedJournalObservation() == .failed && bootstrap.observation().failedClosed
                    && bootstrap.testingStagedJournalRetention() == [false, true, true, true, true, false]
                    && bootstrap.testingStagedJournalStartsRefused(), "bootstrap journal adopted drift or dropped actual owner")
                try H.check(try H.snapshot(root) == disk, "bootstrap journal drift refusal changed evidence")
                try journalReplayRefuses(root, bootstrap)
                // Restore only the fixture-created replacement so the original
                // pinned fence can be observed. This never reopens the bootstrap.
                try H.check((kind == "slot" ? rmdir(path) : unlink(path)) == 0 && rename(retained, path) == 0,
                            "bootstrap journal restore fixture node")
                try H.check(try bootstrap.testingStagedJournalStartsRefused(),
                            "bootstrap journal restored durable node reopened staged starts")
                try journalIntentFence(location, bootstrap)
            }
        }
    }
    static func journalClaimFailure() throws {
        try exclusiveFixture { root, location, bootstrap, _ in
            var claims = 0
            try bootstrap.testingConfigureStagedJournal(afterClaim: { [weak bootstrap] in
                guard let bootstrap else { throw H.Failure(message: "bootstrap journal failing claim owner missing") }
                claims += 1
                try H.check(bootstrap.stagedJournalObservation() == .running, "bootstrap journal failure claim missing")
                throw CustodyRecordError.injectedFailure
            })
            try journalTransferred(bootstrap)
            let disk = try H.snapshot(root)
            try H.refuses { try bootstrap.continueStagedJournal() }
            try H.check(bootstrap.stagedJournalObservation() == .failed && bootstrap.observation().failedClosed
                && bootstrap.testingStagedJournalRetention() == [false, true, true, true, true, false]
                && bootstrap.testingStagedJournalStartsRefused(), "bootstrap journal preconstructor failure reopened starts")
            try journalReplayRefuses(root, bootstrap)
            try H.check(claims == 1 && H.snapshot(root) == disk, "bootstrap journal failed claim retried or changed disk")
            try journalIntentFence(location, bootstrap)
        }
    }
    static func journalReturnedFailure() throws {
        for holdBorrow in [false, true] {
            try exclusiveFixture { root, location, bootstrap, _ in
                var returns = 0
                try bootstrap.testingConfigureStagedJournal(holdBorrow: holdBorrow, afterReturn: { [weak bootstrap] in
                    guard let bootstrap else { throw H.Failure(message: "bootstrap journal failing return owner missing") }
                    returns += 1
                    try H.check(bootstrap.testingStagedJournalRetention() == [true, true, true, true, true, holdBorrow],
                                "bootstrap journal actual result missing before failing postflight")
                    throw CustodyRecordError.injectedFailure
                })
                defer { bootstrap.testingReleaseStagedJournalBorrow() }
                try journalTransferred(bootstrap)
                let disk = try H.snapshot(root)
                try H.refuses { try bootstrap.continueStagedJournal() }
                try H.check(bootstrap.stagedJournalObservation() == .failed && bootstrap.observation().failedClosed
                    && bootstrap.testingStagedJournalRetention() == [true, true, true, true, true, holdBorrow]
                    && bootstrap.testingStagedJournalStartsRefused(), "bootstrap journal failure dropped result or reopened starts")
                // With a live actual alias, closeStarts refuses drainage. The
                // alias remains retained while all future borrowing is fenced;
                // no retirement or cleanup result is manufactured here.
                try journalReplayRefuses(root, bootstrap)
                try H.check(returns == 1 && H.snapshot(root) == disk, "bootstrap journal failed postflight retried or changed disk")
                bootstrap.testingReleaseStagedJournalBorrow()
                try H.check(bootstrap.testingStagedJournalRetention() == [true, true, true, true, true, false]
                    && bootstrap.testingStagedJournalStartsRefused(), "bootstrap journal fixture alias release reopened starts")
                try journalIntentFence(location, bootstrap)
            }
        }
        // A real metadata postflight failure, rather than an injected throw:
        // the returned journal must already be held when the mode drifts.
        try exclusiveFixture { root, location, bootstrap, _ in
            let path = location.path + "/custody/installation.json"
            var postflightDisk: [String: H.Snapshot]?
            try bootstrap.testingConfigureStagedJournal(afterReturn: { [weak bootstrap] in
                guard let bootstrap else { throw H.Failure(message: "bootstrap journal metadata callback owner missing") }
                try H.check(bootstrap.testingStagedJournalRetention()[0], "bootstrap journal result missing before metadata drift")
                try H.check(chmod(path, 0o644) == 0, "bootstrap journal fixture postflight mode drift")
                postflightDisk = try H.snapshot(root)
            })
            try journalTransferred(bootstrap)
            try H.refuses { try bootstrap.continueStagedJournal() }
            try H.check(bootstrap.stagedJournalObservation() == .failed && bootstrap.observation().failedClosed
                && bootstrap.testingStagedJournalRetention() == [true, true, true, true, true, false]
                && bootstrap.testingStagedJournalStartsRefused(), "bootstrap journal postflight adopted drift or lost result")
            guard let postflightDisk else { throw H.Failure(message: "bootstrap journal metadata postflight not reached") }
            try H.check(try H.snapshot(root) == postflightDisk, "bootstrap journal postflight refusal rewrote evidence")
            try journalReplayRefuses(root, bootstrap)
            try H.check(chmod(path, 0o600) == 0, "bootstrap journal restore fixture control mode")
            try H.check(try bootstrap.testingStagedJournalStartsRefused(), "bootstrap journal restored metadata reopened starts")
            try journalIntentFence(location, bootstrap)
        }
    }

    private static func readinessPrepared(_ bootstrap: B, deadline: MonotonicDeadline = .init(seconds: 30)) throws {
        try journalTransferred(bootstrap, deadline: deadline)
        try bootstrap.continueStagedJournal()
    }
    // A UNIX socket cannot be opened as a regular ACL snapshot descriptor.
    // Capture its named node here; the causal endpoint owner validates socket
    // ACL/generation after the actual queue joins. Never race that queue's lock.
    private static func readinessDisk(_ root: String) throws -> [String: H.Snapshot] {
        var result: [String: H.Snapshot] = [:]
        func visit(_ path: String) throws {
            var node = stat(); try H.check(lstat(path, &node) == 0, "bootstrap readiness disk snapshot")
            let kind = node.st_mode & S_IFMT
            result[path] = H.Snapshot(identity: FileIdentity(node),
                bytes: kind == S_IFREG ? try Data(contentsOf: URL(fileURLWithPath: path)) : nil,
                link: kind == S_IFLNK ? try FileManager.default.destinationOfSymbolicLink(atPath: path) : nil,
                flags: node.st_flags, acl: kind == S_IFLNK || kind == S_IFSOCK ? nil : try H.rawACL(path))
            if kind == S_IFDIR {
                for name in try FileManager.default.contentsOfDirectory(atPath: path).sorted() { try visit(path + "/" + name) }
            }
        }
        try visit(root); return result
    }
    private static func readinessReplayRefuses(_ root: String, _ bootstrap: B) throws {
        let disk = try readinessDisk(root), observation = bootstrap.observation()
        let opening = bootstrap.stagedReadinessObservation(), closure = bootstrap.stagedReadinessClosureObservation()
        let retained = bootstrap.testingReadinessRetention()
        try H.refuses { try bootstrap.openStagedReadiness() }
        try H.check(try readinessDisk(root) == disk && bootstrap.observation() == observation
            && bootstrap.stagedReadinessObservation() == opening
            && bootstrap.stagedReadinessClosureObservation() == closure
            && bootstrap.testingReadinessRetention() == retained,
            "bootstrap readiness replay changed actual owners or durable evidence")
    }
    static func readinessBeforeJournal() throws {
        try exclusiveFixture { root, _, bootstrap, _ in
            func refusesUnclaimed() throws {
                try readinessReplayRefuses(root, bootstrap)
                try H.check(bootstrap.stagedReadinessObservation() == .notAttempted,
                            "bootstrap readiness preclaim consumed valid later attempt")
            }
            try refusesUnclaimed()
            try bootstrap.reserve(deadline: .init(seconds: 30)); try refusesUnclaimed()
            try bootstrap.prepareExclusive(); try refusesUnclaimed()
            try bootstrap.transferToStagedAdmission(); try refusesUnclaimed()
            try bootstrap.continueStagedJournal(); try bootstrap.openStagedReadiness()
            try H.check(bootstrap.stagedReadinessObservation() == .complete,
                        "bootstrap readiness preclaim refusal poisoned valid opening")
        }
    }
    static func readinessPositive() throws {
        try exclusiveFixture { root, location, bootstrap, registry in
            try readinessPrepared(bootstrap)
            let before = try stored(location)
            try bootstrap.openStagedReadiness()
            let completed = try stored(location)
            try H.check(bootstrap.stagedReadinessObservation() == .complete && !bootstrap.observation().failedClosed
                && bootstrap.stagedReadinessClosureObservation() == .notAttempted
                && bootstrap.testingReadinessRetention().allSatisfy { $0 },
                "bootstrap readiness successful opening lost retained outcome")
            try H.check(completed.revision == before.revision + 1 && completed.step?.ordinal == 12
                && completed.step?.action == .openStagedAdmission && completed.step?.status == .complete
                && completed.phase == .active && completed.readinessCommit == nil
                && completed.transaction?.sameBinding(as: before.transaction!) == true
                && completed.state == before.state
                && completed.transaction?.slots.images[.stateDestination] == before.transaction?.slots.images[.stateDestination],
                "bootstrap readiness changed original transaction or state generation")
            guard let endpoint = bootstrap.testingReadinessEndpoint(), let session = bootstrap.testingReadinessSession(),
                  let node = completed.transaction?.slots.images[.installationSocket]?.node else {
                throw H.Failure(message: "bootstrap readiness actual session or endpoint missing")
            }
            try H.check(node.type == .socket && node.mode == 0o140600 && node.links == 1
                && before.transaction?.slots.images[.installationSocket]?.node == nil,
                "bootstrap readiness socket completion differs from actual intent")
            let receiptName = try FileManager.default.contentsOfDirectory(atPath: location.path + "/custody/receipts")
                .filter { $0.hasPrefix(InstallationStepReceipt.prefix) }
            let decodedReceipts: [InstallationStepReceipt] = try receiptName.map { name in
                let receiptURL = URL(fileURLWithPath: location.path + "/custody/receipts/" + name)
                let receiptBytes = try Data(contentsOf: receiptURL)
                return try InstallationStepReceipt.decode(receiptBytes, uid: location.uid)
            }
            let receipts = decodedReceipts.sorted { left, right in
                if left.ordinal == right.ordinal {
                    return left.status == .intent && right.status == .complete
                }
                return left.ordinal < right.ordinal
            }
            try completed.validateReceiptChain(receipts)
            try H.check(!registry.hasRetainedWork && registry.testingCount == 0 && registry.testingOriginalHelpersReaped
                && session.testingAnchoredDeadline == nil, "bootstrap readiness launched command or reset readiness clock")
            try InstallationOwnershipFixtures.excluded(location)
            try readinessReplayRefuses(root, bootstrap)
            try bootstrap.testingCloseReadiness(deadline: .init(seconds: 3))
            try H.check(bootstrap.testingReadinessSession() == nil && bootstrap.testingReadinessEndpoint() === endpoint,
                        "bootstrap readiness join lost named custody or kept service")
            try endpoint.revalidate()
        }
    }
    static func readinessReentrantReplay() throws {
        try exclusiveFixture { root, _, bootstrap, _ in
            var claims = 0, returns = 0
            try bootstrap.testingConfigureStagedReadiness(afterClaim: { [weak bootstrap] in
                guard let bootstrap else { throw H.Failure(message: "bootstrap readiness claim missing owner") }
                claims += 1
                try H.check(bootstrap.stagedReadinessObservation() == .running
                    && !bootstrap.testingReadinessRetention()[0], "bootstrap readiness unclaimed completion")
                try readinessReplayRefuses(root, bootstrap)
            }, afterReturn: { [weak bootstrap] in
                guard let bootstrap else { throw H.Failure(message: "bootstrap readiness return missing owner") }
                returns += 1
                try H.check(bootstrap.stagedReadinessObservation() == .running
                    && bootstrap.testingReadinessRetention()[0] && bootstrap.testingReadinessJournalLockAvailable(),
                    "bootstrap readiness postflight spans lock or lost actual result")
                try readinessReplayRefuses(root, bootstrap)
            })
            try readinessPrepared(bootstrap); try bootstrap.openStagedReadiness()
            try readinessReplayRefuses(root, bootstrap)
            try H.check(claims == 1 && returns == 1 && bootstrap.stagedReadinessObservation() == .complete,
                        "bootstrap readiness reentry repeated claimed work")
        }
    }
    static func readinessOriginalDeadline() throws {
        for point in 0..<3 {
            try exclusiveFixture { root, location, bootstrap, _ in
                let original = MonotonicDeadline(seconds: 0.750)
                let expire: () throws -> Void = {
                    while !original.hasExpired { Thread.sleep(forTimeInterval: 0.001) }
                }
                try bootstrap.testingConfigureStagedReadiness(afterClaim: point == 1 ? expire : nil,
                    afterReturn: point == 2 ? expire : nil)
                try readinessPrepared(bootstrap, deadline: original)
                let before = try stored(location)
                if point == 0 { try expire() }
                try H.refuses { try bootstrap.openStagedReadiness() }
                try H.check(original.hasExpired && bootstrap.stagedReadinessObservation() == .failed
                    && bootstrap.observation().failedClosed && bootstrap.testingStagedJournalStartsRefused()
                    && bootstrap.stagedReadinessClosureObservation() == .pending
                    && bootstrap.testingReadinessRetention() == [point == 2, true, true, true, true],
                    "bootstrap readiness refreshed original deadline or lost failed owner")
                let after = try stored(location)
                try H.check(after.revision == before.revision + (point == 2 ? 1 : 0)
                    && after.step?.status == (point == 2 ? .complete : .intent)
                    && after.phase == .active && after.readinessCommit == nil,
                    "bootstrap readiness expiration fabricated or discarded durable completion")
                try InstallationOwnershipFixtures.excluded(location)
                try readinessReplayRefuses(root, bootstrap)
            }
        }
    }
    static func readinessPartialPublication() throws {
        for point in 0..<3 {
            try exclusiveFixture { root, location, bootstrap, _ in
                try bootstrap.testingConfigureStagedReadiness(
                    endpointCut: point == 0 ? .afterMode : (point == 1 ? .afterListen : nil), receiptCut: point == 2)
                try readinessPrepared(bootstrap)
                let before = try stored(location)
                let oldReceipts = try FileManager.default.contentsOfDirectory(atPath: location.path + "/custody/receipts")
                try H.refuses { try bootstrap.openStagedReadiness() }
                guard let endpoint = bootstrap.testingReadinessEndpoint() else {
                    throw H.Failure(message: "bootstrap readiness partial creator lost")
                }
                try H.check(bootstrap.stagedReadinessObservation() == .failed && bootstrap.observation().failedClosed
                    && bootstrap.stagedReadinessClosureObservation() == .joined
                    && bootstrap.testingReadinessRetention() == [false, true, true, true, true]
                    && bootstrap.testingReadinessSession() == nil && bootstrap.testingStagedJournalStartsRefused(),
                    "bootstrap readiness partial publication released owner or claimed completion")
                try H.check(try stored(location) == before, "bootstrap readiness partial publication rewrote intent")
                var node = stat()
                try H.check(lstat(location.path + "/installation.sock", &node) == 0 && node.st_mode == S_IFSOCK | 0o600,
                            "bootstrap readiness partial socket evidence erased")
                let newReceipts = try FileManager.default.contentsOfDirectory(atPath: location.path + "/custody/receipts")
                try H.check(newReceipts.count == oldReceipts.count + (point == 2 ? 1 : 0),
                            "bootstrap readiness partial receipt evidence lost")
                try endpoint.requireServiceClosed()
                try InstallationOwnershipFixtures.excluded(location); try readinessReplayRefuses(root, bootstrap)
            }
        }
    }
    static func readinessReturnedFailure() throws {
        for drift in 0..<3 {
            try exclusiveFixture { root, location, bootstrap, _ in
                weak var actualEndpoint: InstallationReadinessEndpoint?
                weak var actualSession: InstallationPrecommitSession?
                let path = location.path + "/custody/installation.json", saved = root + "/retained-readiness-control"
                try bootstrap.testingConfigureStagedReadiness(afterReturn: { [weak bootstrap] in
                    guard let bootstrap else { throw H.Failure(message: "bootstrap readiness post-return owner missing") }
                    actualEndpoint = bootstrap.testingReadinessEndpoint(); actualSession = bootstrap.testingReadinessSession()
                    try H.check(actualEndpoint != nil && actualSession != nil && bootstrap.testingReadinessRetention()[0],
                                "bootstrap readiness outcome not retained before failing postflight")
                    if drift == 1 { try H.check(chmod(path, 0o644) == 0, "bootstrap readiness metadata drift") }
                    else if drift == 2 {
                        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                        try H.check(rename(path, saved) == 0, "bootstrap readiness retain substituted control")
                        try bytes.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
                        try H.check(chmod(path, 0o600) == 0, "bootstrap readiness replacement control mode")
                    } else { throw CustodyRecordError.injectedFailure }
                })
                try readinessPrepared(bootstrap)
                try H.refuses { try bootstrap.openStagedReadiness() }
                let released = MonotonicDeadline(seconds: 0.750)
                while actualSession != nil && !released.hasExpired { Thread.sleep(forTimeInterval: 0.001) }
                try H.check(bootstrap.stagedReadinessObservation() == .failed && bootstrap.observation().failedClosed
                    && bootstrap.stagedReadinessClosureObservation() == .joined
                    && bootstrap.testingReadinessRetention().allSatisfy { $0 }
                    && bootstrap.testingStagedJournalStartsRefused()
                    && actualEndpoint != nil && bootstrap.testingReadinessEndpoint() === actualEndpoint
                    && actualSession == nil && bootstrap.testingReadinessSession() == nil,
                    "bootstrap readiness failed postflight dropped actual custody or failed to join")
                if drift == 1 { try H.check(chmod(path, 0o600) == 0, "bootstrap readiness restore fixture metadata") }
                else if drift == 2 {
                    try H.check(unlink(path) == 0 && rename(saved, path) == 0, "bootstrap readiness restore original fixture control")
                }
                let completed = try stored(location)
                try H.check(completed.step?.status == .complete && completed.step?.ordinal == 12
                    && completed.phase == .active && completed.readinessCommit == nil,
                    "bootstrap readiness postflight failure rewrote durable outcome")
                try InstallationOwnershipFixtures.excluded(location); try readinessReplayRefuses(root, bootstrap)
            }
        }
    }
    static func readinessPublicationCancellation() throws {
        for source in [false, true] {
            try exclusiveFixture { root, location, bootstrap, _ in
                let barrier = CustodyLeaseTestingBarrier(), deadline = MonotonicDeadline(seconds: 30)
                defer { barrier.release() }
                try bootstrap.testingConfigureStagedReadiness(publicationBarrier: source ? nil : barrier,
                    sourceBarrier: source ? barrier : nil)
                try readinessPrepared(bootstrap, deadline: deadline)
                let custody = try RuntimeFixtureSession.installationRoot(root), call = ExclusiveCall(bootstrap)
                let work = custody.startWork { try H.refuses { try call.bootstrap.openStagedReadiness() } }
                try H.check(barrier.waitUntilEntered(), "bootstrap readiness publication barrier not entered")
                try H.check(bootstrap.stagedReadinessObservation() == .running && bootstrap.testingReadinessJournalLockAvailable(),
                            "bootstrap readiness blocking source/publication held mutex")
                try readinessReplayRefuses(root, bootstrap)
                if source {
                    try H.refuses { try bootstrap.testingCloseReadiness(deadline: .init(seconds: 0.02)) }
                    try H.check(bootstrap.testingReadinessEndpoint() == nil, "bootstrap readiness created socket before source boundary")
                } else {
                    guard let session = bootstrap.testingReadinessSession() else {
                        throw H.Failure(message: "bootstrap readiness unpublished queue owner missing")
                    }
                    try bootstrap.testingCloseReadiness(deadline: .init(seconds: 0.750))
                    try H.check(bootstrap.testingReadinessSession() == nil && !session.start(),
                                "bootstrap readiness cancelled reservation launched queue")
                }
                barrier.release(); try work.value(deadline: deadline)
                try H.check(bootstrap.stagedReadinessObservation() == .failed
                    && bootstrap.stagedReadinessClosureObservation() == .joined && bootstrap.testingStagedJournalStartsRefused(),
                    "bootstrap readiness cancellation reopened claimed owner")
                try InstallationOwnershipFixtures.excluded(location)
            }
        }
    }
    static func readinessFailedJoinCustody() throws {
        try exclusiveFixture { root, location, bootstrap, _ in
            let barrier = CustodyLeaseTestingBarrier(), deadline = MonotonicDeadline(seconds: 3)
            defer { barrier.release() }
            var peer: Int32 = -1
            defer { if peer >= 0 { close(peer) } }
            weak var actualSession: InstallationPrecommitSession?
            weak var actualEndpoint: InstallationReadinessEndpoint?
            try bootstrap.testingConfigureStagedReadiness(afterReturn: { [weak bootstrap] in
                guard let bootstrap, let session = bootstrap.testingReadinessSession() else {
                    throw H.Failure(message: "bootstrap readiness failed-join actual session missing")
                }
                actualSession = session; actualEndpoint = bootstrap.testingReadinessEndpoint()
                session.testingPauseVerification(barrier)
                peer = socket(AF_UNIX, SOCK_STREAM, 0)
                try H.check(peer >= 0, "bootstrap readiness untrusted fixture peer")
                var address = try HostControlIO.address(path: location.path + "/installation.sock")
                let connected = withUnsafePointer(to: &address) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(peer, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                try H.check(connected == 0 && barrier.waitUntilEntered(), "bootstrap readiness actual verification queue not reached")
                try H.check(bootstrap.testingReadinessJournalLockAvailable(), "bootstrap readiness verifier held metadata lock")
                throw CustodyRecordError.injectedFailure
            })
            try readinessPrepared(bootstrap, deadline: deadline)
            try H.refuses { try bootstrap.openStagedReadiness() }
            try H.check(deadline.hasExpired && bootstrap.stagedReadinessObservation() == .failed
                && bootstrap.stagedReadinessClosureObservation() == .pending && bootstrap.testingStagedJournalStartsRefused()
                && actualSession != nil && bootstrap.testingReadinessSession() === actualSession
                && actualEndpoint != nil && bootstrap.testingReadinessEndpoint() === actualEndpoint,
                "bootstrap readiness failed join discarded actual service owner")
            let custody = try RuntimeFixtureSession.installationRoot(root)
            try H.refuses { try custody.finish(deadline: .init(seconds: 0.02)) }
            var info = stat()
            try H.check(lstat(root, &info) == 0 && RuntimeFixtureSession.installationRoot(root) === custody
                && bootstrap.testingReadinessSession() === actualSession,
                "bootstrap readiness failed join removed root or unresolved custody")
            try InstallationOwnershipFixtures.excluded(location); try readinessReplayRefuses(root, bootstrap)
            barrier.release()
            try bootstrap.testingCloseReadiness(deadline: .init(seconds: 3))
            let released = MonotonicDeadline(seconds: 0.750)
            while actualSession != nil && !released.hasExpired { Thread.sleep(forTimeInterval: 0.001) }
            try H.check(bootstrap.testingReadinessSession() == nil && actualSession == nil
                && bootstrap.testingReadinessEndpoint() === actualEndpoint,
                "bootstrap readiness released verifier did not join actual session")
            // Fixture drainage does not rewrite the failed production attempt.
            try H.check(bootstrap.stagedReadinessClosureObservation() == .pending,
                        "bootstrap readiness fixture cleanup manufactured production completion")
        }
    }

    static func readinessConcurrentSession() throws {
        try exclusiveFixture { root, location, bootstrap, _ in
            let barrier = CustodyLeaseTestingBarrier()
            defer { barrier.release() }
            var peer: Int32 = -1
            defer { if peer >= 0 { close(peer) } }
            weak var actualSession: InstallationPrecommitSession?
            try bootstrap.testingConfigureStagedReadiness(afterReturn: { [weak bootstrap] in
                guard let bootstrap, let session = bootstrap.testingReadinessSession() else {
                    throw H.Failure(message: "bootstrap readiness concurrent actual session missing")
                }
                actualSession = session
                session.testingPauseVerification(barrier)
                peer = socket(AF_UNIX, SOCK_STREAM, 0)
                try H.check(peer >= 0, "bootstrap readiness concurrent untrusted peer")
                var address = try HostControlIO.address(path: location.path + "/installation.sock")
                let connected = withUnsafePointer(to: &address) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(peer, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                try H.check(connected == 0 && barrier.waitUntilEntered(), "bootstrap readiness concurrent verifier not reached")
            })
            try readinessPrepared(bootstrap); try bootstrap.openStagedReadiness()
            try H.check(bootstrap.stagedReadinessObservation() == .complete && actualSession != nil
                && bootstrap.testingReadinessSession() === actualSession && bootstrap.testingReadinessJournalLockAvailable(),
                "bootstrap readiness live queue prevented exact journal postflight")
            try H.refuses { try bootstrap.testingCloseReadiness(deadline: .init(seconds: 0.02)) }
            try H.check(bootstrap.testingReadinessSession() === actualSession,
                        "bootstrap readiness live verification owner dropped on pending join")
            try InstallationOwnershipFixtures.excluded(location); try readinessReplayRefuses(root, bootstrap)
            barrier.release(); try bootstrap.testingCloseReadiness(deadline: .init(seconds: 3))
            try H.check(bootstrap.testingReadinessSession() == nil,
                        "bootstrap readiness concurrent actual queue not joined")
        }
    }

    private static func prepareStartCommandFixture(_ root: String) throws {
        // Existing actual-custodian fixture mode: suppress serial telemetry only;
        // the real three-child graph, EOF, reap and retirement are unchanged.
        _ = try TestIsolation.validateRoot(root)
        let marker = root + "/home/.staged-completion-quiet"
        let fd = open(marker, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try H.check(fd >= 0, "bootstrap start fixture marker")
        defer { close(fd) }
        let bytes = Data("staged-completion-quiet/v1\n".utf8)
        try bytes.withUnsafeBytes {
            try H.check(Darwin.write(fd, $0.baseAddress, $0.count) == $0.count && fsync(fd) == 0,
                        "bootstrap start fixture marker durability")
        }
    }
    private static func startPrepared(_ root: String, _ bootstrap: B,
        deadline: MonotonicDeadline = .init(seconds: 30)) throws {
        try prepareStartCommandFixture(root)
        try readinessPrepared(bootstrap, deadline: deadline)
        try bootstrap.openStagedReadiness()
    }
    private static func startReplayRefuses(_ bootstrap: B) throws {
        let before = bootstrap.bootstrapStartObservation(), kickstart = bootstrap.kickstartStartObservation()
        let failed = bootstrap.observation().failedClosed
        try H.refuses { try bootstrap.bootstrapCandidate() }
        try H.refuses { try bootstrap.kickstartCandidate() }
        try H.check(before == bootstrap.bootstrapStartObservation() && kickstart == bootstrap.kickstartStartObservation()
            && failed == bootstrap.observation().failedClosed, "bootstrap start replay changed claimed state")
    }
    /// Only pending token/scope observations are retried. A fixture failure or
    /// unrelated error escapes; this never supplies a fresh production deadline.
    private static func collectFailedStarts(_ bootstrap: B, deadline: MonotonicDeadline) throws {
        while bootstrap.failedStartRetirementObservation() != .retired {
            try H.check(bootstrap.testingFailedStartRetirementDeadline() == deadline.absoluteUptimeNanoseconds,
                        "retirement observation replaced the original absolute ceiling")
            guard !deadline.hasExpired else { throw H.Failure(message: "failed start original retirement deadline") }
            do { try bootstrap.retireFailedStartCommands() }
            catch CustodyRecordError.fenced { Thread.sleep(forTimeInterval: 0.001) }
            catch CustodyRecordError.busy { Thread.sleep(forTimeInterval: 0.001) }
        }
    }
    // Observes real registry events/candidates; it cannot construct a proof or
    // replace an outcome. Synchronization does not retain command resources.
    private final class RetirementProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        private var archives = 0
        private var candidate: RetainedCleanupRegistry.StagedRecoveryRetirement?
        func observe(_ point: RetainedCleanupRegistry.TestFinalizationPoint) {
            lock.lock(); defer { lock.unlock() }
            if point == .beforeArchive { attempts += 1 } else { archives += 1 }
        }
        func capture(_ token: RetainedCleanupRegistry.StagedRecoveryRetirement) {
            lock.lock(); candidate = token; lock.unlock()
        }
        var counts: [Int] { lock.lock(); defer { lock.unlock() }; return [attempts, archives] }
        var token: RetainedCleanupRegistry.StagedRecoveryRetirement? {
            lock.lock(); defer { lock.unlock() }; return candidate
        }
    }
    private static func waitForOriginalReap(_ registry: RetainedCleanupRegistry, deadline: MonotonicDeadline) throws {
        while !registry.testingOriginalHelpersReaped {
            guard !deadline.hasExpired else { throw H.Failure(message: "original fixture reap exceeded its bound") }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
    private static func refusedOriginalPoison() throws {
        for cut in [RetainedCleanupRegistry.TestCut.beforeSpawn, .afterAnchor, .afterOwner] {
            try exclusiveFixture { root, location, bootstrap, registry in
                let original = MonotonicDeadline(seconds: 30), probe = RetirementProbe()
                try bootstrap.testingConfigureStarts(checkpoint: { [weak bootstrap] operation, point in
                    guard operation == .bootstrap, point == .commandRetained,
                          let context = bootstrap?.testingStartContext(kickstart: false) else { return }
                    registry.testingFault(cut)
                    registry.testingObserveFinalization { [weak context] point in
                        probe.observe(point)
                        if point == .beforeArchive {
                            guard let context else { throw H.Failure(message: "original poison context disappeared") }
                            context.testingScope.markPending()
                            throw CustodyRecordError.injectedFailure
                        }
                    }
                })
                try startPrepared(root, bootstrap, deadline: original)
                try H.refuses { try bootstrap.bootstrapCandidate() }
                guard let handle = bootstrap.testingStartHandle(kickstart: false) else { throw H.Failure(message: "original poison handle missing") }
                let control = try stored(location)
                for _ in 0..<3 {
                    registry.testingRevisitFinalization(handle)
                    try H.refuses { _ = try handle.stagedRecoveryRetirement() }
                    try H.refuses { try bootstrap.retireFailedStartCommands() }
                    try H.check(probe.counts == [1, 0] && registry.hasRetainedWork
                        && handle.snapshot().phase == .cleanupPending
                        && bootstrap.failedStartRetirementObservation() == .pending
                        && (try stored(location)) == control,
                        "real original poison was cleared or archival retried")
                }
                try startReplayRefuses(bootstrap); try InstallationOwnershipFixtures.excluded(location)
                try waitForOriginalReap(registry, deadline: original)
                // Only the fixture's reaped originals are disposed; pending is
                // never reported as a production retirement receipt.
                try registry.testingDispose()
            }
        }
    }
    private static func stagedArchiveAttemptIsSingle() throws {
        // Refusal, resumed/open and resumed/ordinary-close all claim before the
        // same actual archive fault. No counter supplies custody evidence.
        for route in 0..<3 {
            try exclusiveFixture { root, location, bootstrap, registry in
                let original = MonotonicDeadline(seconds: 30), probe = RetirementProbe()
                try bootstrap.testingConfigureStarts(checkpoint: { [weak bootstrap] operation, point in
                    guard operation == .bootstrap, point == .commandRetained,
                          let context = bootstrap?.testingStartContext(kickstart: false) else { return }
                    if route == 0 { registry.testingFault(.beforeSpawn) }
                    context.testingScope.testingFault(.afterArchive)
                    registry.testingObserveFinalization { [weak context] point in
                        probe.observe(point)
                        if point == .beforeArchive && route == 2 { context?.testingScope.close() }
                    }
                })
                try startPrepared(root, bootstrap, deadline: original)
                try H.refuses { try bootstrap.bootstrapCandidate() }
                guard let handle = bootstrap.testingStartHandle(kickstart: false) else { throw H.Failure(message: "archive fault original handle missing") }
                let control = try stored(location)
                for _ in 0..<3 {
                    registry.testingRevisitFinalization(handle)
                    try H.refuses { _ = try handle.stagedRecoveryRetirement() }
                    try H.check(probe.counts == [1, 0] && registry.hasRetainedWork
                        && handle.snapshot().phase == .cleanupPending && (try stored(location)) == control,
                        "partial archive was replayed or treated as retirement")
                }
                try H.refuses { try bootstrap.retireFailedStartCommands() }
                try startReplayRefuses(bootstrap); try InstallationOwnershipFixtures.excluded(location)
                try waitForOriginalReap(registry, deadline: original)
                try registry.testingDispose()
            }
        }
    }
    private static func stagedProspectiveCloseFailure() throws {
        for closed in [false, true] {
            try exclusiveFixture { root, location, bootstrap, registry in
                let original = MonotonicDeadline(seconds: 30), probe = RetirementProbe()
                try bootstrap.testingConfigureStarts(checkpoint: { operation, point in
                    guard operation == .bootstrap else { return }
                    if point == .commandRetained {
                        if closed { registry.testingFault(.beforeSpawn) }
                        registry.testingObserveProspectiveRecovery { token, resources in
                            probe.capture(token)
                            if !closed { resources.scope.close() }
                            try resources.testingUncertainStagedResourceClose()
                        }
                    }
                })
                try startPrepared(root, bootstrap, deadline: original)
                try H.refuses { try bootstrap.bootstrapCandidate() }
                guard let handle = bootstrap.testingStartHandle(kickstart: false), let candidate = probe.token else {
                    throw H.Failure(message: "actual prospective recovery candidate was not observed")
                }
                try H.check(handle.snapshot().phase == .cleanupPending && handle.snapshot().reason == .ioFailure
                    && !registry.hasRetainedWork && registry.testingOriginalHelpersReaped,
                    "uncertain resource close lost removal facts or delivered success")
                let control = try stored(location)
                try H.refuses { _ = try handle.stagedRecoveryRetirement() }
                try H.refuses { _ = try handle.stagedCompletion() }
                try H.refuses { _ = try candidate.validate() }
                // Dispose caller aliases only in this fixture, proving the exact
                // false checked-close record cannot become true by weak expiry.
                try bootstrap.testingReleaseFailedStartAliases()
                for _ in 0..<2 {
                    try H.refuses { _ = try candidate.validate() }
                    try H.refuses { try bootstrap.retireFailedStartCommands() }
                    try H.check((try stored(location)) == control && bootstrap.observation().failedClosed,
                        "vanishing aliases repaired a false checked-close seal")
                }
                try startReplayRefuses(bootstrap); try InstallationOwnershipFixtures.excluded(location)
            }
        }
    }
    private static func retiredBootstrapOutlivesCommandReceipt() throws {
        try exclusiveFixture { root, location, bootstrap, registry in
            let original = MonotonicDeadline(seconds: 30)
            var firstReceipt: UInt64?
            var firstToken: RetainedCleanupRegistry.StagedRecoveryRetirement?
            try bootstrap.testingConfigureStarts(checkpoint: { [weak bootstrap] operation, point in
                guard let bootstrap else { throw H.Failure(message: "old token original bootstrap lost") }
                if operation == .bootstrap && point == .commandRetained {
                    firstReceipt = bootstrap.testingStartBudget(kickstart: false)?.receipt
                }
                if operation == .bootstrap && point == .retired {
                    firstToken = try bootstrap.testingStartHandle(kickstart: false)?.stagedRecoveryRetirement()
                }
                if operation == .kickstart && point == .commandRetained { registry.testingFault(.beforeSpawn) }
            })
            try startPrepared(root, bootstrap, deadline: original)
            try bootstrap.bootstrapCandidate()
            guard let firstReceipt, let firstToken else { throw H.Failure(message: "old token exact original evidence missing") }
            while DispatchTime.now().uptimeNanoseconds <= firstReceipt {
                guard !original.hasExpired else { throw H.Failure(message: "old token fixture exhausted invocation") }
                Thread.sleep(forTimeInterval: 0.001)
            }
            try H.refuses { try bootstrap.kickstartCandidate() }
            let control = try stored(location)
            try collectFailedStarts(bootstrap, deadline: original)
            guard let firstHandle = bootstrap.testingStartHandle(kickstart: false) else { throw H.Failure(message: "old token handle replaced") }
            try H.check(try firstHandle.stagedRecoveryRetirement() === firstToken,
                        "collector replaced earlier genuine bootstrap token")
            _ = try firstToken.validate()
            try H.check(!original.hasExpired && bootstrap.failedStartRetirementObservation() == .retired
                && bootstrap.bootstrapStartObservation() == .complete && bootstrap.kickstartStartObservation() == .failed
                && (try stored(location)) == control, "old command receipt became a new token-expiry cutoff")
            try startReplayRefuses(bootstrap); try InstallationOwnershipFixtures.excluded(location)
        }
    }
    private final class StagedObserverProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [RepositoryCommandObservation.Phase] = []
        func accept(_ event: RepositoryCommandObservation) -> Bool {
            lock.lock(); values.append(event.phase); lock.unlock(); return true
        }
        var observed: [RepositoryCommandObservation.Phase] {
            lock.lock(); defer { lock.unlock() }; return values
        }
    }
    private static func stagedTimedOutDrainedRetires() throws {
        for closed in [false, true] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                let operation = MonotonicDeadline(seconds: 30)
                _ = try journal.completeAdmission(deadline: operation)
                let intent = try journal.bootstrapCandidateIntent(deadline: operation)
                var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
                let budget = try CustodyBudget.make(kind: .launchctlRead, workSeconds: 1,
                    termSeconds: 0.2, killSeconds: 0.2, receiptSeconds: 1)
                var command: PreparedCustodyCommand? = try context!.testingInstallationDiagnostic("resist", budget: budget)
                let probe = RetirementProbe(), observerProbe = StagedObserverProbe()
                registry.testingObserveProspectiveRecovery { token, _ in probe.capture(token) }
                registry.testingDeferNextRead(.outputUntilReleased)
                let observer = RepositoryCommandObserver(requestID: command!.resources.request.binding.requestID) {
                    observerProbe.accept($0)
                }
                let scheduling = RetainedCleanupRegistry.StagedTickSchedulingProbe()
                defer { scheduling.barrier.release() }
                let handle = try registry.start(command!, repositoryObserver: observer)
                var failure: Error?
                do {
                    try registry.testingPauseStagedTick(handle, scheduling)
                    try H.check(scheduling.barrier.waitUntilEntered(), "staged timeout did not reach actual pre-consume cut")
                    guard let captured = scheduling.bounds else { throw H.Failure(message: "staged timeout missing cut bounds") }
                    try H.check(captured.sampled < captured.work && captured.work == budget.work
                        && captured.receipt == budget.receipt && captured.operation == operation.absoluteUptimeNanoseconds,
                        "staged timeout pause changed original bounds or missed pre-work tick")
                    // Read only the original durable record while its queue is
                    // paused. On release only normal poll/consume/finish may
                    // establish terminal/EOF/reap; this file is not custody proof.
                    let journalPath = location.path + "/custody/" + command!.resources.request.binding.requestID + ".json"
                    while true {
                        if let bytes = try? Data(contentsOf: URL(fileURLWithPath: journalPath)),
                           let terminal = try? CustodyJournal.decode(bytes), terminal.phase == .terminal {
                            try H.check(terminal.outcome == .timedOutDrained && terminal.reason == .timeout
                                && terminal.budget == budget, "staged timeout helper did not produce original timed-out terminal")
                            break
                        }
                        guard DispatchTime.now().uptimeNanoseconds < captured.receipt else {
                            throw H.Failure(message: "staged timeout original terminal not durable inside receipt")
                        }
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    // Same original owner, non-consuming WNOWAIT scheduling
                    // signal only. Normal registry poll/consume establishes all
                    // actual reap, terminal, EOF and retirement evidence.
                    while !scheduling.originalTerminationAvailable {
                        guard DispatchTime.now().uptimeNanoseconds < captured.receipt else {
                            throw H.Failure(message: "staged timeout original termination not observable inside receipt")
                        }
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    scheduling.barrier.release()
                    while registry.testingReadObservation(handle)?.terminalReceived != true {
                        guard DispatchTime.now().uptimeNanoseconds < budget.receipt else {
                            throw H.Failure(message: "staged timeout lacked original terminal inside receipt")
                        }
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    guard let before = registry.testingStagedExpiryObservation(handle) else {
                        throw H.Failure(message: "staged timeout lost original resumed entry")
                    }
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard let read = registry.testingReadObservation(handle) else {
                        throw H.Failure(message: "staged timeout lost actual original stream observations")
                    }
                    try H.check(registry.testingPoll(handle) == .reaped(0)
                        && read.terminalReceived && read.statusEOF && !read.outputEOF && !read.traceEOF,
                        "staged timeout lacked original helper-zero/status EOF or released held output prematurely")
                    try H.check(before.resumed && before.request.budget == budget
                        && now >= budget.work && now < before.effectiveReceipt
                        && before.effectiveReceipt <= budget.receipt
                        && before.operation == operation.absoluteUptimeNanoseconds && !operation.hasExpired
                        && !before.cleanupEntered && !before.archiveAttempted,
                        "staged timeout changed W0/Re/Dop or entered expired cleanup")
                    if closed { context!.close() }
                    try H.refuses { _ = try handle.stagedRecoveryRetirement() }
                    registry.testingReleaseDeferredRead(handle)
                    let result = handle.wait()
                    try H.check(result.phase == .finished && result.journal?.outcome == .timedOutDrained
                        && result.journal?.reason == .timeout && result.journal?.budget == budget
                        && DispatchTime.now().uptimeNanoseconds < before.effectiveReceipt
                        && !operation.hasExpired && !registry.hasRetainedWork,
                        "actual staged timeout was refused, relabelled completed, or retired after its cap")
                    let token = try handle.stagedRecoveryRetirement()
                    try H.check(token === probe.token && observerProbe.observed == [.admission, .retired],
                        "staged timeout bypassed genuine observer delivery or replaced prospective evidence")
                    guard let seal = token.testingIssuanceObservation() else {
                        throw H.Failure(message: "staged timeout lacked actual checked seal")
                    }
                    try H.check(seal.closedArchive == closed && seal.checkedClose && seal.exactRemoval && seal.validBounds
                        && seal.originalWork == budget.work && seal.retiredAt >= budget.work
                        && seal.effectiveReceipt == before.effectiveReceipt && seal.operation == before.operation
                        && seal.retiredAt < before.effectiveReceipt && seal.retiredAt < before.operation,
                        "staged timeout used the wrong archive or lacked bounded original checked retirement")
                    command = nil; context!.close(); context = nil
                    while (try? token.validate()) == nil {
                        guard !operation.hasExpired else { throw H.Failure(message: "staged timeout genuine token invalid") }
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    try H.refuses { _ = try token.serviceState() }
                    try H.refuses { _ = try handle.stagedCompletion() }
                    try H.check((try stored(location)) == intent.binding.control
                        && registry.testingOriginalHelpersReaped,
                        "staged timeout recovery changed installation intent or lost original reap")
                    try InstallationOwnershipFixtures.excluded(location)
                } catch { failure = error }
                // Failure paths also release only this original read hold and
                // drain the original owner. Unknown ownership stops handback.
                scheduling.barrier.release()
                registry.testingReleaseDeferredRead(handle)
                if registry.hasRetainedWork {
                    registry.testingRequestCancellation()
                    let teardown = MonotonicDeadline(seconds: 8)
                    while registry.hasRetainedWork {
                        if let read = registry.testingReadObservation(handle), read.statusEOF,
                           read.outputEOF, read.traceEOF, registry.testingOriginalHelpersReaped {
                            try registry.testingDispose(); break
                        }
                        guard !teardown.hasExpired else { throw H.Failure(message: "staged timeout original teardown unresolved") }
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                }
                command = nil; context?.close(); context = nil
                try H.check(!registry.hasRetainedWork && registry.testingOriginalHelpersReaped,
                    "staged timeout handback retained an original helper")
                if let failure { throw failure }
            }
        }
    }
    private static func stagedExpiredTransportNegatives() throws {
        for fault in ["malformed-status", "nonzero-helper", "poisoned-output"] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                _ = try TestIsolation.validateRoot(root)
                let markerPath = root + "/home/.staged-expired-transport-fault"
                let marker = OwnedFileDescriptor(open(markerPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
                guard marker.value >= 0 else { throw H.Failure(message: "staged negative marker create") }
                let bytes = Data(fault.utf8)
                try H.check(bytes.withUnsafeBytes { Darwin.write(marker.value, $0.baseAddress, $0.count) } == bytes.count
                    && fsync(marker.value) == 0 && marker.retireChecked() == .succeeded,
                    "staged negative marker durability/close")
                let operation = MonotonicDeadline(seconds: 3), probe = ExpiryCleanupProbe(), observerProbe = StagedObserverProbe()
                _ = try journal.completeAdmission(deadline: operation)
                let intent = try journal.bootstrapCandidateIntent(deadline: operation)
                var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
                let budget = try CustodyBudget.make(kind: .launchctlRead, workSeconds: 10)
                var command: PreparedCustodyCommand? = try context!.testingInstallationDiagnostic("complete", budget: budget)
                let resources = command!.resources, scope = context!.testingScope
                let requestID = resources.request.binding.requestID
                let catalogPath = location.path + "/custody/catalog.json"
                let journalPath = location.path + "/custody/" + requestID + ".json"
                let archivePath = location.path + "/custody/receipts/" + requestID + ".json"
                let callerPath = location.path + "/custody/receipts/" + requestID + ".caller.json"
                registry.testingDeferNextRead(.outputUntilReleased)
                registry.testingObserveExpiredCleanup { probe.capture($0) }
                let observer = RepositoryCommandObserver(requestID: requestID) { observerProbe.accept($0) }
                let handle = try registry.start(command!, repositoryObserver: observer)
                var failure: Error?
                do {
                    while registry.testingReadObservation(handle)?.terminalReceived != true {
                        guard !operation.hasExpired else { throw H.Failure(message: "staged negative lacked original on-time terminal") }
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    guard let original = registry.testingStagedExpiryObservation(handle),
                          let ticket = registry.testingTicket(handle) else {
                        throw H.Failure(message: "staged negative lost original staged custody")
                    }
                    try H.check(original.resumed && !original.cleanupEntered && !original.statusPoisoned
                        && !original.outputPoisoned && !original.archiveAttempted
                        && original.request == resources.request && original.request.budget == budget
                        && original.operation == operation.absoluteUptimeNanoseconds,
                        "negative began with synthetic, poisoned, or replaced original evidence")
                    let catalogBefore = try Data(contentsOf: URL(fileURLWithPath: catalogPath))
                    let journalBefore = try Data(contentsOf: URL(fileURLWithPath: journalPath))
                    let terminal = try CustodyJournal.decode(journalBefore)
                    try H.check(terminal.phase == .terminal && terminal.outcome == .completed,
                        "negative fixture did not first obtain real target drainage and durable terminal")
                    while !operation.hasExpired { Thread.sleep(forTimeInterval: 0.001) }
                    registry.testingRevisitFinalization(handle)
                    guard let expired = registry.testingStagedExpiryObservation(handle) else {
                        throw H.Failure(message: "staged negative disappeared at original expiry")
                    }
                    try H.check(expired.cleanupEntered && !expired.archiveAttempted
                        && handle.snapshot().phase == .cleanupPending && registry.hasRetainedWork
                        && expired.effectiveReceipt <= original.effectiveReceipt
                        && expired.operation == original.operation,
                        "staged negative bypassed actual unissued-expiry entry or renewed its bounds")
                    registry.testingReleaseDeferredRead(handle)
                    let observation = MonotonicDeadline(seconds: 8) // fixture observation/handback only
                    while true {
                        if let read = registry.testingReadObservation(handle), read.statusEOF,
                           read.outputEOF, read.traceEOF, registry.testingOriginalHelpersReaped { break }
                        guard !observation.hasExpired else { throw H.Failure(message: "staged negative original streams/reap unresolved") }
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    registry.testingRevisitFinalization(handle)
                    guard let rejected = registry.testingStagedExpiryObservation(handle),
                          case .reaped(let raw)? = registry.testingPoll(handle) else {
                        throw H.Failure(message: "staged negative lost original reap/entry")
                    }
                    try H.check(rejected.cleanupEntered && rejected.cleanupUncertain
                        && !rejected.archiveAttempted && probe.observed.isEmpty
                        && rejected.statusPoisoned == (fault == "malformed-status")
                        && rejected.outputPoisoned == (fault == "poisoned-output")
                        && raw == (fault == "nonzero-helper" ? 77 << 8 : 0)
                        && rejected.request == original.request && rejected.operation == original.operation
                        && rejected.effectiveReceipt <= original.effectiveReceipt
                        && registry.hasRetainedWork && !registry.testingCleanupOnlyRemoved(handle)
                        && !resources.installationRetiredSuccessfully && scope.observation == .pending
                        && ticket.testingJournal.phase == .prepared,
                        "staged negative cleared poison, forged cleanup, changed owner/budget, or reached metadata read")
                    try H.check((try stored(location)) == intent.binding.control
                        && (try Data(contentsOf: URL(fileURLWithPath: catalogPath))) == catalogBefore
                        && (try Data(contentsOf: URL(fileURLWithPath: journalPath))) == journalBefore
                        && !FileManager.default.fileExists(atPath: archivePath)
                        && !FileManager.default.fileExists(atPath: callerPath)
                        && observerProbe.observed == [.admission],
                        "staged negative mutated durable fence or delivered successful observer")
                    for _ in 0..<2 {
                        registry.testingRevisitFinalization(handle)
                        try H.refuses { _ = try handle.stagedCompletion() }
                        try H.refuses { _ = try handle.stagedRecoveryRetirement() }
                        try H.check(probe.observed.isEmpty && registry.hasRetainedWork
                            && handle.snapshot().phase == .cleanupPending,
                            "staged negative retry removed custody or started archival/read")
                    }
                    try InstallationOwnershipFixtures.excluded(location)
                } catch { failure = error }
                // Teardown is a separate fixture operation. It grants no
                // production cleanup witness and never signals an unknown owner.
                registry.testingReleaseDeferredRead(handle)
                registry.testingCloseControl(handle)
                let teardown = MonotonicDeadline(seconds: 8)
                while true {
                    if let read = registry.testingReadObservation(handle), read.statusEOF,
                       read.outputEOF, read.traceEOF, registry.testingOriginalHelpersReaped { break }
                    guard !teardown.hasExpired else { throw H.Failure(message: "staged negative exact original teardown unresolved") }
                    Thread.sleep(forTimeInterval: 0.001)
                }
                try H.check(registry.hasRetainedWork && !registry.testingCleanupOnlyRemoved(handle),
                    "negative fixture teardown was mislabeled production cleanup")
                try registry.testingDispose()
                resources.retire()
                try H.check(resources.installationRetiredSuccessfully
                    && !registry.hasRetainedWork && registry.testingOriginalHelpersReaped,
                    "negative original checked resource teardown failed")
                try H.refuses { _ = try handle.stagedRecoveryRetirement() }
                try InstallationOwnershipFixtures.excluded(location)
                command = nil; context!.close(); context = nil
                if let failure { throw failure }
            }
        }
    }
    private static func resumedRetirementAfterWork() throws {
        for closed in [false, true] {
            try exclusiveFixture { root, location, bootstrap, registry in
                let original = MonotonicDeadline(seconds: 30)
                var work: UInt64?, receipt: UInt64?
                try bootstrap.testingConfigureStarts(checkpoint: { [weak bootstrap] operation, point in
                    guard operation == .bootstrap, let bootstrap else { return }
                    if point == .commandRetained {
                        guard let budget = bootstrap.testingStartBudget(kickstart: false) else { throw H.Failure(message: "after-work original budget missing") }
                        work = budget.work; receipt = budget.receipt
                        registry.testingDeferNextRead(.outputUntilReleased)
                    }
                    if point == .submitted {
                        guard let handle = bootstrap.testingStartHandle(kickstart: false), let work, let receipt else {
                            throw H.Failure(message: "after-work original command missing")
                        }
                        while registry.testingReadObservation(handle)?.terminalReceived != true {
                            guard DispatchTime.now().uptimeNanoseconds < work else { throw H.Failure(message: "target did not complete during original work") }
                            Thread.sleep(forTimeInterval: 0.001)
                        }
                        if closed { bootstrap.testingStartContext(kickstart: false)?.close() }
                        while DispatchTime.now().uptimeNanoseconds <= work {
                            guard !original.hasExpired else { throw H.Failure(message: "after-work invocation expired") }
                            Thread.sleep(forTimeInterval: 0.001)
                        }
                        try H.check(DispatchTime.now().uptimeNanoseconds < receipt && registry.hasRetainedWork,
                                    "after-work fixture lost its original receipt window")
                        try H.refuses { _ = try handle.stagedRecoveryRetirement() }
                        registry.testingReleaseDeferredRead(handle)
                        let result = handle.wait()
                        try H.check(result.phase == .finished && result.journal?.outcome == .completed
                            && result.journal?.reason == CustodyReason.none
                            && DispatchTime.now().uptimeNanoseconds < receipt,
                            "lawful original terminal/EOF/reap after work was refused or reclassified")
                        throw CustodyRecordError.injectedFailure
                    }
                })
                try startPrepared(root, bootstrap, deadline: original)
                try H.refuses { try bootstrap.bootstrapCandidate() }
                let control = try stored(location)
                try collectFailedStarts(bootstrap, deadline: original)
                try H.check(bootstrap.failedStartRetirementObservation() == .retired
                    && bootstrap.bootstrapStartObservation() == .failed && bootstrap.observation().failedClosed
                    && !registry.hasRetainedWork && registry.testingOriginalHelpersReaped
                    && (try stored(location)) == control, "after-work recovery changed failed start/control")
                try startReplayRefuses(bootstrap); try InstallationOwnershipFixtures.excluded(location)
            }
        }
    }
    private static func genuineDeliveryAfterReceipt() throws {
        try exclusiveFixture { root, location, bootstrap, registry in
            let original = MonotonicDeadline(seconds: 30), barrier = CustodyLeaseTestingBarrier()
            defer { barrier.release() }
            var receipt: UInt64?
            try bootstrap.testingConfigureStarts(checkpoint: { [weak bootstrap] operation, point in
                guard operation == .bootstrap else { return }
                if point == .commandRetained {
                    receipt = bootstrap?.testingStartBudget(kickstart: false)?.receipt
                    registry.testingPauseNextRetirement(barrier)
                }
                if point == .submitted {
                    try H.check(barrier.waitUntilEntered(), "late delivery did not reach real removed-entry boundary")
                    // No queue.sync while its callback barrier is held.
                    try H.check(!registry.hasRetainedWork, "late delivery paused before actual removal")
                    throw CustodyRecordError.injectedFailure
                }
            })
            try startPrepared(root, bootstrap, deadline: original)
            try H.refuses { try bootstrap.bootstrapCandidate() }
            guard let handle = bootstrap.testingStartHandle(kickstart: false), let receipt else { throw H.Failure(message: "late delivery original handle/budget missing") }
            let control = try stored(location)
            while DispatchTime.now().uptimeNanoseconds <= receipt {
                guard !original.hasExpired else { throw H.Failure(message: "late delivery consumed invocation") }
                Thread.sleep(forTimeInterval: 0.001)
            }
            try H.check(handle.wait().phase == .cleanupPending, "late callback renewed Handle.wait receipt")
            try H.refuses { _ = try handle.stagedRecoveryRetirement() }
            barrier.release()
            try collectFailedStarts(bootstrap, deadline: original)
            let token = try handle.stagedRecoveryRetirement()
            _ = try token.validate()
            try H.check(handle.snapshot().phase == .finished && !registry.hasRetainedWork
                && bootstrap.failedStartRetirementObservation() == .retired && !original.hasExpired
                && (try stored(location)) == control && bootstrap.observation().failedClosed,
                "genuine in-budget retirement was poisoned by later callback delivery")
            try startReplayRefuses(bootstrap); try InstallationOwnershipFixtures.excluded(location)
        }
    }
    private final class OriginalChildProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var originalAnchor: OwnedSpawnAnchor?
        private var originalOwner: OwnedDirectChild?
        func capture(_ anchor: OwnedSpawnAnchor?, _ owner: OwnedDirectChild?) {
            lock.lock(); originalAnchor = anchor; originalOwner = owner; lock.unlock()
        }
        var objects: (OwnedSpawnAnchor?, OwnedDirectChild?) {
            lock.lock(); defer { lock.unlock() }; return (originalAnchor, originalOwner)
        }
    }
    private static func originalRefusalHoldAndCancellation() throws {
        for cut in [RetainedCleanupRegistry.TestCut.afterAnchor, .afterOwner] {
            for expire in [false, true] {
                try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                    let operation = MonotonicDeadline(seconds: 30), probe = OriginalChildProbe()
                    _ = try journal.completeAdmission(deadline: operation)
                    let intent = try journal.bootstrapCandidateIntent(deadline: operation)
                    var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
                    let budget = try CustodyBudget.make(kind: .launchctlMutation, workSeconds: 10,
                        termSeconds: 0.2, killSeconds: 0.2, receiptSeconds: 0.2)
                    var command: PreparedCustodyCommand? = try context!.testingStagedLifecycle(.bootstrap, budget: budget)
                    registry.testingFault(cut)
                    registry.testingHoldNextOriginalRefusal { anchor, owner in probe.capture(anchor, owner) }
                    let handle = try registry.start(command!)
                    guard let before = registry.testingRefusalBounds(handle), let anchor = probe.objects.0 else {
                        throw H.Failure(message: "held refusal lost exact original spawn")
                    }
                    try H.check(anchor.unexecutedProof() == nil && handle.snapshot().phase == .starting
                        && registry.hasRetainedWork && before.effectiveReceipt == before.originalReceipt,
                        "held suspended original fabricated reap or terminal delivery")
                    try H.refuses { _ = try handle.stagedRecoveryRetirement() }
                    try InstallationOwnershipFixtures.excluded(location)
                    handle.cancel()
                    guard let shortened = registry.testingRefusalBounds(handle) else { throw H.Failure(message: "original cancellation lost refusal route") }
                    try H.check(shortened.effectiveReceipt < shortened.originalReceipt
                        && shortened.effectiveReceipt < shortened.work && shortened.work == before.work
                        && shortened.operation == before.operation,
                        "original cancellation renewed receipt or replaced original work/invocation")
                    if expire {
                        while DispatchTime.now().uptimeNanoseconds < shortened.effectiveReceipt {
                            Thread.sleep(forTimeInterval: 0.001)
                        }
                    }
                    registry.testingReleaseOriginalRefusal(handle)
                    if expire {
                        try H.check(DispatchTime.now().uptimeNanoseconds >= shortened.effectiveReceipt
                            && DispatchTime.now().uptimeNanoseconds < shortened.originalReceipt,
                            "shortened receipt negative did not precede original receipt")
                        try H.refuses { _ = try handle.stagedRecoveryRetirement() }
                        registry.testingRevisitFinalization(handle)
                        try H.check(handle.snapshot().phase == .cleanupPending && registry.hasRetainedWork,
                            "expired shortened receipt admitted original refusal archive")
                        try waitForOriginalReap(registry, deadline: operation)
                        try registry.testingDispose()
                    } else {
                        let result = handle.wait()
                        try H.check(result.phase == .finished && result.journal?.outcome == .admissionRefused
                            && DispatchTime.now().uptimeNanoseconds < shortened.effectiveReceipt
                            && anchor.unexecutedProof() != nil,
                            "cancelled original refusal lacked actual in-budget original reap")
                        let token = try handle.stagedRecoveryRetirement()
                        command = nil; context!.close(); context = nil
                        while (try? token.validate()) == nil {
                            guard !operation.hasExpired else { throw H.Failure(message: "original refusal token did not validate") }
                            Thread.sleep(forTimeInterval: 0.001)
                        }
                    }
                    try H.check((try stored(location)) == intent.binding.control,
                        "refusal cancellation changed original installation control")
                    command = nil; context?.close(); context = nil
                    try InstallationOwnershipFixtures.excluded(location)
                }
            }
        }
    }
    private static func originalWaitAndSignalFailures() throws {
        // Inject at the existing actual wait syscall seam. EINTR then ECHILD
        // reaches the wait inside the original owner's SIGKILL call, exercising
        // a real false signal return without forging a successful child exit.
        let waitErrors: [[Int32]] = [[ECHILD], [EINTR, ECHILD]]
        for errors in waitErrors {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                let operation = MonotonicDeadline(seconds: 30), probe = OriginalChildProbe()
                _ = try journal.completeAdmission(deadline: operation)
                let intent = try journal.bootstrapCandidateIntent(deadline: operation)
                var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
                var command: PreparedCustodyCommand? = try context!.testingStagedLifecycle(.bootstrap)
                registry.testingFault(.afterOwner)
                registry.testingObserveOriginalRefusal { anchor, owner in
                    probe.capture(anchor, owner); owner?.testingInjectWaitErrors(errors)
                }
                let handle = try registry.start(command!)
                _ = handle.wait()
                guard let owner = probe.objects.1, let anchor = probe.objects.0 else { throw H.Failure(message: "wait fault original owner missing") }
                try H.check(owner.observation == .ownershipFailure(ECHILD) && anchor.unexecutedProof() == nil
                    && handle.snapshot().phase == .cleanupPending && registry.hasRetainedWork,
                    "actual ECHILD/failed signal became original refusal proof")
                try H.refuses { _ = try handle.stagedRecoveryRetirement() }
                // The pre-existing testing-only owner seam cleans only this
                // injected original suspended child; it is not production recovery.
                while owner.testingRuntimeStep(.init(reason: .assertion, escalate: true), streamsDrained: true) != .reaped {
                    guard !operation.hasExpired else { throw H.Failure(message: "injected original wait-fault teardown") }
                    Thread.sleep(forTimeInterval: 0.001)
                }
                registry.testingRevisitFinalization(handle)
                try H.refuses { _ = try handle.stagedRecoveryRetirement() }
                try H.check(registry.hasRetainedWork && handle.snapshot().phase == .cleanupPending
                    && (try stored(location)) == intent.binding.control,
                    "later fixture-only original reap cleared sticky custody failure")
                try InstallationOwnershipFixtures.excluded(location)
                try registry.testingDispose(); command = nil; context!.close(); context = nil
            }
        }
    }
    private static func actualObserverDeliveryDisposition() throws {
        for accept in [false, true] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                let operation = MonotonicDeadline(seconds: 30), barrier = CustodyLeaseTestingBarrier(), probe = RetirementProbe()
                defer { barrier.release() }
                _ = try journal.completeAdmission(deadline: operation)
                let intent = try journal.bootstrapCandidateIntent(deadline: operation)
                var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
                let budget = try CustodyBudget.make(kind: .launchctlMutation, workSeconds: 2,
                    termSeconds: 0.2, killSeconds: 0.2, receiptSeconds: 0.2)
                var command: PreparedCustodyCommand? = try context!.testingStagedLifecycle(.bootstrap, budget: budget)
                registry.testingObserveProspectiveRecovery { token, _ in probe.capture(token) }
                let observer = RepositoryCommandObserver(requestID: command!.resources.request.binding.requestID) { event in
                    if event.phase == .admission { return true }
                    return barrier.pause() && accept
                }
                let handle = try registry.start(command!, repositoryObserver: observer)
                try H.check(barrier.waitUntilEntered() && !registry.hasRetainedWork,
                    "observer callback did not follow actual checked removal")
                guard let candidate = probe.token else { throw H.Failure(message: "observer original prospective token missing") }
                try H.refuses { _ = try candidate.validate() }
                while DispatchTime.now().uptimeNanoseconds <= budget.receipt {
                    guard !operation.hasExpired else { throw H.Failure(message: "observer fixture invocation expired") }
                    Thread.sleep(forTimeInterval: 0.001)
                }
                try H.check(handle.wait().phase == .cleanupPending, "observer renewed original receipt wait")
                barrier.release()
                command = nil; context!.close(); context = nil
                while handle.snapshot().phase != .finished {
                    guard !operation.hasExpired else { throw H.Failure(message: "actual observer return not delivered") }
                    Thread.sleep(forTimeInterval: 0.001)
                }
                if accept {
                    let token = try handle.stagedRecoveryRetirement()
                    try H.check(token === candidate, "observer replaced original candidate token")
                    while (try? token.validate()) == nil {
                        guard !operation.hasExpired else { throw H.Failure(message: "accepted late observer token invalid") }
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                } else {
                    try H.refuses { _ = try handle.stagedRecoveryRetirement() }
                    try H.refuses { _ = try candidate.validate() }
                    try H.check(handle.snapshot().reason == .ioFailure, "observer rejection lost original ioFailure")
                }
                try H.check((try stored(location)) == intent.binding.control, "observer retirement completed installation action")
                try InstallationOwnershipFixtures.excluded(location)
            }
        }
    }
    private static func closedArchivePinIntegrity() throws {
        for suffix in [".json", ".caller.json"] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                let operation = MonotonicDeadline(seconds: 30)
                _ = try journal.completeAdmission(deadline: operation)
                let intent = try journal.bootstrapCandidateIntent(deadline: operation)
                var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
                var command: PreparedCustodyCommand? = try context!.testingStagedLifecycle(.bootstrap)
                registry.testingFault(.beforeSpawn)
                let handle = try registry.start(command!), result = handle.wait()
                guard let journalRecord = result.journal else { throw H.Failure(message: "closed archive original journal missing") }
                let token = try handle.stagedRecoveryRetirement()
                command = nil; context!.close(); context = nil
                while (try? token.validate()) == nil {
                    guard !operation.hasExpired else { throw H.Failure(message: "closed archive positive token failed") }
                    Thread.sleep(forTimeInterval: 0.001)
                }
                let path = location.path + "/custody/receipts/" + journalRecord.binding.requestID + suffix
                let descriptor = OwnedFileDescriptor(open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC))
                guard descriptor.value >= 0 else { throw H.Failure(message: "closed archive pin fixture open") }
                var original: UInt8 = 0
                try H.check(pread(descriptor.value, &original, 1, 0) == 1, "closed archive pin fixture read")
                var changed = original ^ 1
                try H.check(pwrite(descriptor.value, &changed, 1, 0) == 1 && fsync(descriptor.value) == 0,
                    "closed archive pin fault did not persist")
                try H.refuses { _ = try token.validate() }
                try H.check(pwrite(descriptor.value, &original, 1, 0) == 1 && fsync(descriptor.value) == 0,
                    "closed archive creator restoration failed")
                try H.check(descriptor.retireChecked() == .succeeded, "closed archive fixture descriptor close failed")
                _ = try token.validate()
                // Current names and inode identity are required even when a
                // replacement has the exact archived bytes.
                let saved = path + ".fixture-held"
                var originalNode = stat(), currentName = stat()
                try H.check(lstat(path, &originalNode) == 0 && originalNode.st_nlink == 1
                    && lstat(saved, &currentName) == -1 && errno == ENOENT,
                    "closed archive replacement fixture did not own its names")
                let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                try H.check(rename(path, saved) == 0, "closed archive original pin move failed")
                let replacement = OwnedFileDescriptor(open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
                guard replacement.value >= 0 else { throw H.Failure(message: "closed archive replacement create failed") }
                let wrote = bytes.withUnsafeBytes { Darwin.write(replacement.value, $0.baseAddress, $0.count) }
                try H.check(wrote == bytes.count && fsync(replacement.value) == 0,
                    "closed archive replacement bytes not durable")
                try H.refuses { _ = try token.validate() }
                var replacementNode = stat()
                try H.check(fstat(replacement.value, &replacementNode) == 0
                    && lstat(path, &currentName) == 0 && FileIdentity(currentName) == FileIdentity(replacementNode)
                    && lstat(saved, &currentName) == 0 && FileIdentity(currentName) == FileIdentity(originalNode),
                    "closed archive fixture replacement identity drifted")
                try H.check(unlink(path) == 0 && rename(saved, path) == 0
                    && replacement.retireChecked() == .succeeded, "closed archive fixture restore failed")
                _ = try token.validate()
                let extraPath = location.path + "/custody/receipts/fixture-extra.json"
                let extra = OwnedFileDescriptor(open(extraPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
                guard extra.value >= 0 else { throw H.Failure(message: "extra archive receipt fixture create failed") }
                try H.refuses { _ = try token.validate() }
                var extraNode = stat()
                try H.check(fstat(extra.value, &extraNode) == 0 && lstat(extraPath, &currentName) == 0
                    && FileIdentity(extraNode) == FileIdentity(currentName) && unlink(extraPath) == 0
                    && extra.retireChecked() == .succeeded, "extra archive receipt fixture cleanup failed")
                _ = try token.validate()
                try H.check((try stored(location)) == intent.binding.control,
                    "closed archive validation mutated installation control")
                try InstallationOwnershipFixtures.excluded(location)
            }
        }
    }
    private final class ExpiryCleanupProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var points: [RetainedCleanupRegistry.TestExpiredCleanupPoint] = []
        func capture(_ point: RetainedCleanupRegistry.TestExpiredCleanupPoint) { lock.lock(); points.append(point); lock.unlock() }
        var observed: [RetainedCleanupRegistry.TestExpiredCleanupPoint] { lock.lock(); defer { lock.unlock() }; return points }
    }
    private static func expiredCleanupRejectsForeignOriginals() throws {
        for kind in [RetainedCleanupRegistry.TestExpiredSubstitution.ticket, .record, .helper, .message] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                try InstallationStagedJournalFixtures.fixture { otherRoot, otherLocation, _, _, otherAdmission, otherJournal, otherRegistry in
                    let operation = MonotonicDeadline(seconds: 3), otherOperation = MonotonicDeadline(seconds: 30)
                    let probe = ExpiryCleanupProbe()
                    _ = try journal.completeAdmission(deadline: operation)
                    _ = try otherJournal.completeAdmission(deadline: otherOperation)
                    let intent = try journal.bootstrapCandidateIntent(deadline: operation)
                    let otherIntent = try otherJournal.bootstrapCandidateIntent(deadline: otherOperation)
                    var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
                    var otherContext: CommandCustodyContext? = try .testingStaged(otherAdmission, intent: otherIntent, root: otherRoot)
                    let budget = try CustodyBudget.make(kind: .launchctlMutation, workSeconds: 10)
                        .clipped(to: operation, kind: .launchctlMutation, permittedWorkSeconds: 10)
                    var command: PreparedCustodyCommand? = try context!.testingStagedLifecycle(.bootstrap, budget: budget)
                    var otherCommand: PreparedCustodyCommand? = try otherContext!.testingStagedLifecycle(.bootstrap)
                    registry.testingDeferNextRead(.outputUntilReleased)
                    otherRegistry.testingDeferNextRead(.outputUntilReleased)
                    registry.testingObserveExpiredCleanup { probe.capture($0) }
                    let handle = try registry.start(command!), other = try otherRegistry.start(otherCommand!)
                    while registry.testingReadObservation(handle)?.terminalReceived != true
                        || otherRegistry.testingReadObservation(other)?.terminalReceived != true {
                        guard !operation.hasExpired else { throw H.Failure(message: "substitution lacked two actual on-time terminals") }
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    let before = try stored(location), otherBefore = try stored(otherLocation)
                    try waitForOriginalReap(registry, deadline: operation)
                    try waitForOriginalReap(otherRegistry, deadline: operation)
                    while !operation.hasExpired { Thread.sleep(forTimeInterval: 0.001) }
                    registry.testingRevisitFinalization(handle)
                    try registry.testingRejectExpiredSubstitution(handle, from: other, kind: kind)
                    registry.testingRevisitFinalization(handle)
                    let expected: [RetainedCleanupRegistry.TestExpiredCleanupPoint] = kind == .message ? [.beforeRead] : []
                    try H.check(probe.observed == expected && registry.hasRetainedWork
                        && handle.snapshot().phase == .cleanupPending && !registry.testingCleanupOnlyRemoved(handle)
                        && (try stored(location)) == before && (try stored(otherLocation)) == otherBefore,
                        "foreign original evidence retired expiry custody or retried its failed read")
                    try H.refuses { _ = try handle.stagedCompletion() }
                    try H.refuses { _ = try handle.stagedRecoveryRetirement() }
                    try InstallationOwnershipFixtures.excluded(location)
                    try InstallationOwnershipFixtures.excluded(otherLocation)
                    // Restore only the fixture's original references, then use
                    // the existing original-owner teardown for this negative.
                    try registry.testingDispose()
                    otherRegistry.testingReleaseDeferredRead(other)
                    try H.check(other.wait().phase == .finished, "untampered second original failed retirement")
                    command = nil; otherCommand = nil
                    context!.close(); context = nil; otherContext!.close(); otherContext = nil
                }
            }
        }
    }
    private static func unissuedExpiryCleansOnlyOriginalResources() throws {
        // These are additional negatives, not replacements for the unchanged
        // original 750ms / eight-second Bootstrap cleanup acceptance.
        for fault in ["none", "before-poison", "later-poison", "journal", "catalog-busy", "close", "before-archive", "partial-archive"] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                let operation = MonotonicDeadline(seconds: 3), probe = ExpiryCleanupProbe()
                _ = try journal.completeAdmission(deadline: operation)
                let intent = try journal.bootstrapCandidateIntent(deadline: operation)
                var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
                let budget = try CustodyBudget.make(kind: .launchctlMutation, workSeconds: 10)
                    .clipped(to: operation, kind: .launchctlMutation, permittedWorkSeconds: 10)
                var command: PreparedCustodyCommand? = try context!.testingStagedLifecycle(.bootstrap, budget: budget)
                let scope = context!.testingScope
                if fault == "close" { try command!.resources.testingUncertainStagedResourceClose() }
                if fault == "partial-archive" { scope.testingFault(.afterArchive) }
                else if fault == "before-archive" {
                    registry.testingObserveFinalization { point in
                        if point == .beforeArchive { throw CustodyRecordError.injectedFailure }
                    }
                } else { registry.testingDeferNextRead(.outputUntilReleased) }
                registry.testingObserveExpiredCleanup { probe.capture($0) }
                let handle = try registry.start(command!)
                if fault == "partial-archive" || fault == "before-archive" { _ = handle.wait() }
                else {
                    while registry.testingReadObservation(handle)?.terminalReceived != true {
                        guard !operation.hasExpired else { throw H.Failure(message: "expiry fixture lacked on-time original terminal") }
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                }
                guard let ticket = registry.testingTicket(handle) else { throw H.Failure(message: "expiry original ticket disappeared") }
                try H.refuses { _ = try command!.resources.takeSpawnResources() }
                try H.check(command!.resources.installationReadyForCheckedRetirement,
                    "resumed expiry command allowed a new transfer or lost original resource ownership")
                let requestID = command!.resources.request.binding.requestID
                let catalogPath = location.path + "/custody/catalog.json"
                let journalPath = location.path + "/custody/" + requestID + ".json"
                let controlBefore = try stored(location)
                let catalogBefore = try Data(contentsOf: URL(fileURLWithPath: catalogPath))
                let journalBefore = try Data(contentsOf: URL(fileURLWithPath: journalPath))
                let archivePath = location.path + "/custody/receipts/" + requestID + ".json"
                let callerPath = location.path + "/custody/receipts/" + requestID + ".caller.json"
                let archiveBefore = FileManager.default.fileExists(atPath: archivePath)
                let callerBefore = FileManager.default.fileExists(atPath: callerPath)
                if fault == "before-poison" { scope.markPending() }
                while !operation.hasExpired { Thread.sleep(forTimeInterval: 0.001) }
                _ = handle.wait()
                registry.testingRevisitFinalization(handle)
                try H.check(registry.hasRetainedWork && handle.snapshot().phase == .cleanupPending,
                    "expiry released original custody before complete proof")
                try H.refuses { _ = try handle.stagedCompletion() }
                try H.refuses { _ = try handle.stagedRecoveryRetirement() }
                try InstallationOwnershipFixtures.excluded(location)
                var guardOwner: OwnedFileDescriptor?
                var changedJournal: OwnedFileDescriptor?
                if fault == "later-poison" { scope.markPending() }
                if fault == "catalog-busy" {
                    guardOwner = OwnedFileDescriptor(open(location.path + "/custody/catalog.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC))
                    try H.check(guardOwner!.value >= 0 && flock(guardOwner!.value, LOCK_EX | LOCK_NB) == 0,
                        "expiry contention fixture did not hold independent catalog description")
                }
                if fault == "journal" {
                    changedJournal = OwnedFileDescriptor(open(journalPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC))
                    guard changedJournal!.value >= 0 else { throw H.Failure(message: "expiry original journal fault open") }
                    var bad = journalBefore[0] ^ 1
                    try H.check(pwrite(changedJournal!.value, &bad, 1, 0) == 1 && fsync(changedJournal!.value) == 0,
                        "expiry actual journal fault was not durable")
                }
                if fault != "partial-archive" && fault != "before-archive" { registry.testingReleaseDeferredRead(handle) }
                let cleanup = MonotonicDeadline(seconds: 8) // fixture observation only
                try waitForOriginalReap(registry, deadline: cleanup)
                registry.testingRevisitFinalization(handle)
                if let guardOwner {
                    try H.check(flock(guardOwner.value, LOCK_UN) == 0 && guardOwner.retireChecked() == .succeeded,
                        "expiry contention fixture release failed")
                }
                if let changedJournal {
                    var first = journalBefore[0]
                    try H.check(pwrite(changedJournal.value, &first, 1, 0) == 1 && fsync(changedJournal.value) == 0
                        && changedJournal.retireChecked() == .succeeded, "expiry original journal fixture restoration failed")
                }
                registry.testingRevisitFinalization(handle)
                if fault == "none" {
                    while registry.hasRetainedWork {
                        guard !cleanup.hasExpired else { throw H.Failure(message: "positive expiry original physical cleanup did not settle") }
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    try H.check(probe.observed == [.beforeRead, .afterRead, .checkedClose, .removed]
                        && registry.testingCleanupOnlyRemoved(handle) && scope.observation == .pending
                        && ticket.testingJournal.phase == .prepared
                        && !(try scope.testingRead()).entries.isEmpty,
                        "expiry cleanup changed durable/live reservation or issued retirement")
                } else {
                    let expected: [RetainedCleanupRegistry.TestExpiredCleanupPoint]
                    if ["before-poison", "later-poison", "before-archive", "partial-archive"].contains(fault) { expected = [] }
                    else if fault == "close" { expected = [.beforeRead, .afterRead] }
                    else { expected = [.beforeRead] }
                    try H.check(probe.observed == expected && registry.hasRetainedWork
                        && !registry.testingCleanupOnlyRemoved(handle),
                        "uncertain expiry cleanup retried read/close or removed original evidence")
                }
                try H.check(handle.snapshot().phase == .cleanupPending
                    && (try stored(location)) == controlBefore
                    && (try Data(contentsOf: URL(fileURLWithPath: catalogPath))) == catalogBefore
                    && (try Data(contentsOf: URL(fileURLWithPath: journalPath))) == journalBefore
                    && FileManager.default.fileExists(atPath: archivePath) == archiveBefore
                    && FileManager.default.fileExists(atPath: callerPath) == callerBefore,
                    "cleanup-only expiry archived, rewrote a durable fence or changed failed control")
                try H.refuses { _ = try handle.stagedCompletion() }
                try H.refuses { _ = try handle.stagedRecoveryRetirement() }
                try InstallationOwnershipFixtures.excluded(location)
                if fault != "none" { try registry.testingDispose() }
                command = nil; context!.close(); context = nil
            }
        }
    }
    private static func failedStartDelayedRetirement() throws {
        try exclusiveFixture { root, location, bootstrap, registry in
            let original = MonotonicDeadline(seconds: 30)
            try bootstrap.testingConfigureStarts(checkpoint: { [weak bootstrap] operation, point in
                guard operation == .bootstrap else { return }
                if point == .commandRetained { registry.testingDeferNextRead(.outputUntilReleased) }
                if point == .submitted {
                    guard let handle = bootstrap?.testingStartHandle(kickstart: false) else {
                        throw H.Failure(message: "failed start delayed original handle")
                    }
                    while registry.testingReadObservation(handle)?.terminalReceived != true {
                        guard !original.hasExpired else { throw H.Failure(message: "failed start delayed terminal") }
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    throw CustodyRecordError.injectedFailure
                }
            })
            try startPrepared(root, bootstrap, deadline: original)
            try H.refuses { try bootstrap.bootstrapCandidate() }
            guard let handle = bootstrap.testingStartHandle(kickstart: false) else {
                throw H.Failure(message: "failed start delayed custody lost")
            }
            defer { registry.testingReleaseDeferredRead(handle) }
            let before = try stored(location)
            try H.refuses { try bootstrap.retireFailedStartCommands() }
            try H.check(bootstrap.failedStartRetirementObservation() == .pending
                && bootstrap.testingFailedStartRetirementRetention(kickstart: false) == [false, true, false]
                && registry.hasRetainedWork && bootstrap.testingStartHandle(kickstart: false) === handle,
                "pending EOF released original command aliases")
            try InstallationOwnershipFixtures.excluded(location)
            registry.testingReleaseDeferredRead(handle)
            while registry.hasRetainedWork {
                guard !original.hasExpired else { throw H.Failure(message: "delayed EOF original registry settlement") }
                Thread.sleep(forTimeInterval: 0.001)
            }
            // Closing the original context before registry retirement cannot
            // produce staged evidence through today's open-scope-only API.
            // Preserve that distinction even after real EOF/reap/removal.
            try H.refuses { try bootstrap.retireFailedStartCommands() }
            try H.check(bootstrap.testingFailedStartRetirementRetention(kickstart: false) == [false, true, false]
                && bootstrap.failedStartRetirementObservation() == .pending
                && !registry.hasRetainedWork && registry.testingOriginalHelpersReaped
                && (try stored(location)) == before && bootstrap.observation().failedClosed,
                "late EOF manufactured missing original recovery authority")
            try startReplayRefuses(bootstrap); try InstallationOwnershipFixtures.excluded(location)
        }
    }
    private static func failedStartDelayedToken() throws {
        try exclusiveFixture { root, location, bootstrap, registry in
            let original = MonotonicDeadline(seconds: 30), barrier = CustodyLeaseTestingBarrier()
            defer { barrier.release() }
            try bootstrap.testingConfigureStarts(checkpoint: { operation, point in
                guard operation == .bootstrap else { return }
                if point == .commandRetained { registry.testingPauseNextRetirement(barrier) }
                if point == .submitted {
                    try H.check(barrier.waitUntilEntered(), "actual original retirement delivery barrier missing")
                    throw CustodyRecordError.injectedFailure
                }
            })
            try startPrepared(root, bootstrap, deadline: original)
            try H.refuses { try bootstrap.bootstrapCandidate() }
            let control = try stored(location)
            try H.refuses { try bootstrap.retireFailedStartCommands() }
            try H.check(bootstrap.failedStartRetirementObservation() == .pending
                && bootstrap.testingFailedStartRetirementRetention(kickstart: false) == [false, true, false],
                "undelivered actual token released command aliases")
            barrier.release()
            try collectFailedStarts(bootstrap, deadline: original)
            try H.check(bootstrap.testingFailedStartRetirementRetention(kickstart: false) == [true, true, true]
                && registry.testingCount == 0 && registry.testingOriginalHelpersReaped
                && (try stored(location)) == control && bootstrap.observation().failedClosed,
                "delayed actual token changed failed start or failed to release aliases")
            try H.refuses { try bootstrap.retireFailedStartCommands() }
            try startReplayRefuses(bootstrap); try InstallationOwnershipFixtures.excluded(location)
        }
    }
    private static func failedStartQueuedSubmission() throws {
        try exclusiveFixture { root, location, bootstrap, registry in
            let original = MonotonicDeadline(seconds: 30), barrier = CustodyLeaseTestingBarrier()
            defer { barrier.release() }
            try bootstrap.testingConfigureStarts(checkpoint: { [weak bootstrap] operation, point in
                guard operation == .kickstart else { return }
                if point == .commandRetained {
                    guard let prior = bootstrap?.testingStartHandle(kickstart: false) else {
                        throw H.Failure(message: "queued failure lost original preceding handle")
                    }
                    registry.testingCancelAndPauseQueue(prior, barrier)
                    try H.check(barrier.waitUntilEntered(), "queued failure barrier not entered")
                }
                if point == .submitted { throw CustodyRecordError.injectedFailure }
            })
            try startPrepared(root, bootstrap, deadline: original)
            try bootstrap.bootstrapCandidate()
            try H.refuses { try bootstrap.kickstartCandidate() }
            guard let handle = bootstrap.testingStartHandle(kickstart: true) else {
                throw H.Failure(message: "queued failure did not retain returned handle")
            }
            let control = try stored(location)
            try H.refuses { try bootstrap.retireFailedStartCommands() }
            try H.check(bootstrap.failedStartRetirementObservation() == .pending
                && bootstrap.testingFailedStartRetirementRetention(kickstart: true) == [false, true, false]
                && registry.hasRetainedWork && bootstrap.testingStartHandle(kickstart: true) === handle,
                "queued submission was mistaken for never submitted retirement")
            barrier.release()
            while registry.hasRetainedWork {
                guard !original.hasExpired else { throw H.Failure(message: "queued original registry failed to settle") }
                Thread.sleep(forTimeInterval: 0.001)
            }
            // The actual registry rejected the closed context before metadata.
            // It supplies no staged recovery token; an empty registry is not one.
            try H.refuses { try bootstrap.retireFailedStartCommands() }
            try H.check(bootstrap.failedStartRetirementObservation() == .pending
                && bootstrap.testingFailedStartRetirementRetention(kickstart: true) == [false, true, false]
                && (try stored(location)) == control,
                "empty registry fabricated queued-command retirement authority")
            try startReplayRefuses(bootstrap); try InstallationOwnershipFixtures.excluded(location)
        }
    }
    private static func failedStartRefusedCommands() throws {
        for cut in [RetainedCleanupRegistry.TestCut.beforeSpawn, .afterAnchor, .afterOwner] {
            try exclusiveFixture { root, location, bootstrap, registry in
                let original = MonotonicDeadline(seconds: 30)
                try bootstrap.testingConfigureStarts(checkpoint: { [weak bootstrap] operation, point in
                    guard operation == .bootstrap else { return }
                    if point == .commandRetained { registry.testingFault(cut) }
                    if point == .submitted {
                        guard let handle = bootstrap?.testingStartHandle(kickstart: false) else {
                            throw H.Failure(message: "refused original command lost handle")
                        }
                        let result = handle.wait()
                        try H.check(result.phase == .finished && result.journal?.outcome == .admissionRefused,
                                    "refused command lacks actual terminal outcome")
                        throw CustodyRecordError.injectedFailure
                    }
                })
                try startPrepared(root, bootstrap, deadline: original)
                try H.refuses { try bootstrap.bootstrapCandidate() }
                guard let handle = bootstrap.testingStartHandle(kickstart: false) else {
                    throw H.Failure(message: "refused command handle lost after return")
                }
                let control = try stored(location), result = handle.snapshot()
                try collectFailedStarts(bootstrap, deadline: original)
                try H.check(bootstrap.failedStartRetirementObservation() == .retired
                    && result.journal?.outcome == .admissionRefused
                    && handle.snapshot().journal == result.journal
                    && bootstrap.bootstrapStartObservation() == .failed
                    && bootstrap.testingFailedStartRetirementRetention(kickstart: false) == [true, true, true]
                    && (try stored(location)) == control,
                    "retirement converted actual refusal into successful command")
                try H.refuses { try bootstrap.retireFailedStartCommands() }
                try startReplayRefuses(bootstrap); try InstallationOwnershipFixtures.excluded(location)
            }
        }
    }
    private static func failedStartPartialAndPoison() throws {
        try failedStartQueuedSubmission()
        try failedStartRefusedCommands()
        for cut in [B.StartCheckpoint.claimed, .intentRetained, .contextRetained, .commandRetained] {
            try exclusiveFixture { root, location, bootstrap, registry in
                try bootstrap.testingConfigureStarts(checkpoint: { operation, point in
                    if operation == .bootstrap && point == cut { throw CustodyRecordError.injectedFailure }
                })
                try startPrepared(root, bootstrap)
                try H.refuses { try bootstrap.bootstrapCandidate() }
                let before = bootstrap.testingStartRetention(kickstart: false), control = try stored(location)
                try H.check(bootstrap.testingStartHandle(kickstart: false) == nil && !registry.hasRetainedWork,
                            "partial fixture unexpectedly submitted command")
                for _ in 0..<2 {
                    try H.refuses { try bootstrap.retireFailedStartCommands() }
                    try H.check(bootstrap.failedStartRetirementObservation() == .pending
                        && bootstrap.testingStartRetention(kickstart: false) == before
                        && !bootstrap.testingFailedStartRetirementRetention(kickstart: false)[0]
                        && (try stored(location)) == control,
                        "missing handle was treated as safe resource retirement")
                }
                try startReplayRefuses(bootstrap); try InstallationOwnershipFixtures.excluded(location)
            }
        }
        try exclusiveFixture { root, location, bootstrap, _ in
            try bootstrap.testingConfigureStarts(checkpoint: { [weak bootstrap] operation, point in
                if operation == .bootstrap && point == .retirementReceived {
                    guard let context = bootstrap?.testingStartContext(kickstart: false) else {
                        throw H.Failure(message: "poison fixture lost original scope")
                    }
                    // Negative-only poison of the actual owner; no proof is minted.
                    context.testingScope.markPending()
                    throw CustodyRecordError.injectedFailure
                }
            })
            try startPrepared(root, bootstrap)
            try H.refuses { try bootstrap.bootstrapCandidate() }
            let control = try stored(location)
            for _ in 0..<2 {
                try H.refuses { try bootstrap.retireFailedStartCommands() }
                try H.check(bootstrap.failedStartRetirementObservation() == .pending
                    && bootstrap.testingFailedStartRetirementRetention(kickstart: false) == [true, true, true]
                    && (try stored(location)) == control,
                    "poisoned real token was discarded or accepted")
            }
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    private static func failedStartTokenAndConcurrentTurns() throws {
        try exclusiveFixture { root, location, bootstrap, _ in
            let original = MonotonicDeadline(seconds: 30), barrier = CustodyLeaseTestingBarrier()
            defer { barrier.release() }
            var retainedEvents = 0, releasedEvents = 0
            try bootstrap.testingConfigureStarts(checkpoint: { operation, point in
                if operation == .bootstrap && point == .retirementReceived { throw CustodyRecordError.injectedFailure }
            }, failedRetirementCheckpoint: { [weak bootstrap] point in
                guard let bootstrap else { throw H.Failure(message: "failed retirement owner lost") }
                try H.check(bootstrap.testingReadinessJournalLockAvailable(), "retirement callback holds metadata lock")
                if point == .retirementRetained {
                    retainedEvents += 1
                    try H.check(barrier.pause(), "failed retirement token barrier")
                    throw CustodyRecordError.injectedFailure
                }
                if point == .aliasesReleased { releasedEvents += 1 }
            })
            try startPrepared(root, bootstrap, deadline: original)
            try H.refuses { try bootstrap.bootstrapCandidate() }
            let control = try stored(location), call = ExclusiveCall(bootstrap)
            let work = try RuntimeFixtureSession.installationRoot(root).startWork {
                try H.refuses { try call.bootstrap.retireFailedStartCommands() }
            }
            try H.check(barrier.waitUntilEntered(), "failed retirement token was not retained")
            try H.check(bootstrap.failedStartRetirementObservation() == .collecting
                && bootstrap.testingFailedStartRetirementRetention(kickstart: false) == [true, true, false],
                "fallible retirement callback preceded token retention")
            try H.refuses { try bootstrap.retireFailedStartCommands() }
            try InstallationOwnershipFixtures.excluded(location)
            barrier.release(); try work.value(deadline: original)
            try H.check(bootstrap.failedStartRetirementObservation() == .pending
                && retainedEvents == 1 && releasedEvents == 0,
                "concurrent turn released or recollected original token")
            try collectFailedStarts(bootstrap, deadline: original)
            try H.refuses { try bootstrap.retireFailedStartCommands() }
            try H.check(retainedEvents == 1 && releasedEvents == 1
                && bootstrap.testingFailedStartRetirementRetention(kickstart: false) == [true, true, true]
                && (try stored(location)) == control && bootstrap.observation().failedClosed,
                "repeated retirement double-released aliases or changed failure")
            try startReplayRefuses(bootstrap); try InstallationOwnershipFixtures.excluded(location)
        }
    }

    static func startBeforeReadiness() throws {
        try exclusiveFixture { root, _, bootstrap, _ in
            try startReplayRefuses(bootstrap)
            try readinessPrepared(bootstrap)
            try startReplayRefuses(bootstrap)
            try H.check(bootstrap.bootstrapStartObservation() == .notAttempted
                && bootstrap.kickstartStartObservation() == .notAttempted,
                "bootstrap start preclaim refusal consumed valid attempt")
            // Marker is needed only by command fixtures, not admission itself.
            let marker = root + "/home/.staged-completion-quiet"
            try Data("staged-completion-quiet/v1\n".utf8).write(to: URL(fileURLWithPath: marker), options: .withoutOverwriting)
            try H.check(chmod(marker, 0o600) == 0, "bootstrap start order marker mode")
            try bootstrap.openStagedReadiness()
            try H.refuses { try bootstrap.kickstartCandidate() }
            try H.check(bootstrap.kickstartStartObservation() == .notAttempted,
                        "bootstrap kickstart before bootstrap claimed execution")
            try bootstrap.bootstrapCandidate(); try bootstrap.kickstartCandidate()
            try startReplayRefuses(bootstrap)
        }
    }
    static func startSequence() throws {
        try exclusiveFixture { root, location, bootstrap, registry in
            let deadline = MonotonicDeadline(seconds: 30)
            var events: [String] = []
            weak var actualContext: CommandCustodyContext?
            try bootstrap.testingConfigureStarts(checkpoint: { [weak bootstrap] operation, point in
                guard let bootstrap else { throw H.Failure(message: "bootstrap start owner lost") }
                let kickstart = operation == .kickstart
                events.append("\(kickstart):\(point)")
                try H.check(bootstrap.testingReadinessJournalLockAvailable(), "bootstrap start callback held metadata lock")
                if point == .contextRetained {
                    actualContext = bootstrap.testingStartContext(kickstart: kickstart)
                    try H.check(actualContext != nil, "bootstrap start context not retained before boundary")
                }
                if point == .commandRetained {
                    guard let budget = bootstrap.testingStartBudget(kickstart: kickstart) else {
                        throw H.Failure(message: "bootstrap start missing actual command budget")
                    }
                    try budget.validate(kind: .launchctlMutation, permittedWorkSeconds: 10,
                        now: DispatchTime.now().uptimeNanoseconds)
                    try H.check([budget.work, budget.term, budget.kill, budget.receipt].allSatisfy {
                        $0 <= deadline.absoluteUptimeNanoseconds
                    }, "bootstrap start command escaped original caller ceiling")
                }
                if point == .retired {
                    try H.check(actualContext == nil && registry.testingCount == 0 && registry.testingOriginalHelpersReaped
                        && bootstrap.testingStartRetention(kickstart: kickstart) == [true, false, false, true, true, false],
                        "bootstrap start published completion with retained command aliases")
                    try H.check(try stored(location).step?.status == .intent, "bootstrap start completed before actual retirement")
                }
            })
            try startPrepared(root, bootstrap, deadline: deadline)
            let original = try stored(location)
            try bootstrap.bootstrapCandidate()
            let first = try stored(location)
            try H.check(first.step?.ordinal == 13 && first.step?.action == .bootstrapCandidate
                && first.step?.status == .complete && first.revision == original.revision + 2,
                "bootstrap start did not complete same journal bootstrap")
            try bootstrap.kickstartCandidate()
            let second = try stored(location)
            try H.check(second.step?.ordinal == 14 && second.step?.action == .kickstartCandidate
                && second.step?.status == .complete && second.revision == first.revision + 2
                && second.phase == .active && second.readinessCommit == nil && second.state == original.state
                && second.transaction?.sameBinding(as: original.transaction!) == true,
                "bootstrap start changed transaction or invented candidate readiness")
            let expected = ["claimed", "intentRetained", "contextRetained", "commandRetained", "submitted", "retirementReceived", "aliasesReleased", "retired", "completed"]
            try H.check(events == [false, true].flatMap { value in expected.map { "\(value):\($0)" } }
                && bootstrap.bootstrapStartObservation() == .complete && bootstrap.kickstartStartObservation() == .complete
                && !bootstrap.observation().failedClosed,
                "bootstrap start fixed command sequence differs")
            try H.check(try bootstrap.testingStartReadinessDeadline() == bootstrap.testingReadinessSession()?.testingAnchoredDeadline?.absoluteUptimeNanoseconds,
                        "bootstrap start restarted retirement-anchored readiness clock")
            try InstallationOwnershipFixtures.excluded(location)
            let disk = try readinessDisk(root)
            try startReplayRefuses(bootstrap)
            try H.check(try readinessDisk(root) == disk, "bootstrap start replay changed durable bytes")
        }
    }
    static func startConcurrent() throws {
        try exclusiveFixture { root, location, bootstrap, registry in
            let barrier = CustodyLeaseTestingBarrier()
            defer { barrier.release() }
            try bootstrap.testingConfigureStarts(checkpoint: { [weak bootstrap] operation, point in
                guard operation == .bootstrap && point == .submitted else { return }
                guard let bootstrap else { throw H.Failure(message: "bootstrap concurrent owner lost") }
                try startReplayRefuses(bootstrap)
                try H.check(barrier.pause(), "bootstrap concurrent barrier timed out")
            })
            try startPrepared(root, bootstrap)
            let call = ExclusiveCall(bootstrap), custody = try RuntimeFixtureSession.installationRoot(root)
            let work = custody.startWork { try call.bootstrap.bootstrapCandidate() }
            try H.check(barrier.waitUntilEntered(), "bootstrap concurrent submission not reached")
            try H.check(bootstrap.bootstrapStartObservation() == .running
                && bootstrap.testingReadinessJournalLockAvailable(), "bootstrap wait retained metadata mutex")
            try startReplayRefuses(bootstrap)
            try InstallationOwnershipFixtures.excluded(location)
            barrier.release(); try work.value(deadline: .init(seconds: 8))
            try H.check(bootstrap.bootstrapStartObservation() == .complete && !registry.hasRetainedWork,
                        "bootstrap concurrent winner did not retire")
            try bootstrap.kickstartCandidate()
        }
    }
    static func startOriginalDeadline() throws {
        for point in 0..<4 {
            try exclusiveFixture { root, location, bootstrap, _ in
                let original = MonotonicDeadline(seconds: 0.750)
                let expire = { while !original.hasExpired { Thread.sleep(forTimeInterval: 0.001) } }
                try bootstrap.testingConfigureStarts(checkpoint: { operation, checkpoint in
                    guard operation == .bootstrap else { return }
                    if (point == 1 && checkpoint == .claimed) || (point == 2 && checkpoint == .commandRetained)
                        || (point == 3 && checkpoint == .completed) { expire() }
                })
                try startPrepared(root, bootstrap, deadline: original)
                let before = try stored(location)
                if point == 0 { expire() }
                try H.refuses { try bootstrap.bootstrapCandidate() }
                let after = try stored(location)
                try H.check(original.hasExpired && bootstrap.bootstrapStartObservation() == .failed
                    && bootstrap.observation().failedClosed && bootstrap.testingStagedJournalStartsRefused()
                    && bootstrap.stagedReadinessClosureObservation() == .pending,
                    "bootstrap start refreshed caller or cleanup deadline")
                try H.check(after.revision == before.revision + (point < 2 ? 0 : (point == 2 ? 1 : 2))
                    && after.phase == .active && after.readinessCommit == nil,
                    "bootstrap expired command lost durable outcome")
                try InstallationOwnershipFixtures.excluded(location); try startReplayRefuses(bootstrap)
            }
        }
    }
    static func startPendingEOF() throws {
        try expiredCleanupRejectsForeignOriginals()
        try stagedTimedOutDrainedRetires()
        try stagedExpiredTransportNegatives()
        try unissuedExpiryCleansOnlyOriginalResources()
        try resumedRetirementAfterWork()
        try failedStartDelayedRetirement()
        try failedStartDelayedToken()
        try exclusiveFixture { root, location, bootstrap, registry in
            let original = MonotonicDeadline(seconds: 0.750)
            var terminalWithoutEOF = false
            try bootstrap.testingConfigureStarts(checkpoint: { [weak bootstrap] operation, point in
                if operation == .bootstrap && point == .commandRetained {
                    registry.testingDeferNextRead(.outputUntilReleased)
                }
                if operation == .bootstrap && point == .submitted {
                    guard let handle = bootstrap?.testingStartHandle(kickstart: false) else {
                        throw H.Failure(message: "bootstrap EOF observation lost handle")
                    }
                    while !terminalWithoutEOF {
                        guard !original.hasExpired else { throw H.Failure(message: "bootstrap EOF terminal not observed") }
                        if let observed = registry.testingReadObservation(handle) {
                            terminalWithoutEOF = observed.terminalReceived && !observed.outputEOF
                        }
                        if !terminalWithoutEOF { Thread.sleep(forTimeInterval: 0.001) }
                    }
                }
            })
            try startPrepared(root, bootstrap, deadline: original)
            let call = ExclusiveCall(bootstrap), custody = try RuntimeFixtureSession.installationRoot(root)
            let work = custody.startWork { try H.refuses { try call.bootstrap.bootstrapCandidate() } }
            try work.value(deadline: .init(seconds: 2))
            guard let handle = bootstrap.testingStartHandle(kickstart: false) else {
                throw H.Failure(message: "bootstrap EOF pending lost exact handle")
            }
            defer { registry.testingReleaseDeferredRead(handle) }
            try H.check(terminalWithoutEOF && original.hasExpired && bootstrap.bootstrapStartObservation() == .failed
                && bootstrap.testingStartRetention(kickstart: false) == [true, true, true, true, false, false]
                && bootstrap.testingStartContext(kickstart: false)?.isClosed == true
                && registry.hasRetainedWork && bootstrap.testingStagedJournalStartsRefused(),
                "bootstrap pending EOF dropped uncertain command or manufactured retirement")
            try H.refuses { _ = try handle.stagedCompletion() }
            try H.refuses { try bootstrap.retireFailedStartCommands() }
            try H.check(bootstrap.failedStartRetirementObservation() == .pending
                && bootstrap.testingFailedStartRetirementRetention(kickstart: false) == [false, true, false],
                "expired original attempt manufactured retirement or released aliases")
            let control = try stored(location)
            try H.check(control.step?.action == .bootstrapCandidate && control.step?.status == .intent
                && control.readinessCommit == nil, "bootstrap pending EOF published completion")
            try InstallationOwnershipFixtures.excluded(location); try startReplayRefuses(bootstrap)
            registry.testingReleaseDeferredRead(handle)
            let cleanup = MonotonicDeadline(seconds: 8)
            while registry.hasRetainedWork {
                guard !cleanup.hasExpired else { throw H.Failure(message: "bootstrap pending fixture retirement") }
                Thread.sleep(forTimeInterval: 0.005)
            }
            try H.check(try stored(location) == control && bootstrap.bootstrapStartObservation() == .failed,
                        "bootstrap late retirement retried failed start")
            try H.refuses { try bootstrap.retireFailedStartCommands() }
            try H.check(bootstrap.testingFailedStartRetirementRetention(kickstart: false) == [false, true, false]
                && bootstrap.failedStartRetirementObservation() == .pending,
                "late actual retirement refreshed expired invocation budget")
        }
    }
    static func startFailureAndAlias() throws {
        try originalRefusalHoldAndCancellation()
        try originalWaitAndSignalFailures()
        try refusedOriginalPoison()
        try failedStartPartialAndPoison()
        for alias in [false, true] {
            try exclusiveFixture { root, location, bootstrap, registry in
                var heldAlias: CustodyAuthorityLeaseSet?
                defer { heldAlias = nil }
                try bootstrap.testingConfigureStarts(checkpoint: { [weak bootstrap] operation, point in
                    guard operation == .bootstrap, let bootstrap else { return }
                    if point == .contextRetained && alias {
                        heldAlias = try bootstrap.testingStartContext(kickstart: false)!.testingScope.leases.duplicate()
                    }
                    if point == .commandRetained && !alias { registry.testingFault(.beforeSpawn) }
                })
                let original = MonotonicDeadline(seconds: 30)
                try startPrepared(root, bootstrap, deadline: original)
                try H.refuses { try bootstrap.bootstrapCandidate() }
                let current = try stored(location)
                try H.check(bootstrap.observation().failedClosed && bootstrap.bootstrapStartObservation() == .failed
                    && bootstrap.testingStagedJournalStartsRefused() && current.step?.status == .intent
                    && current.step?.action == .bootstrapCandidate && current.readinessCommit == nil,
                    "bootstrap failed or borrowed command became durable completion")
                if alias {
                    try withExtendedLifetime(heldAlias) {
                        try H.check(bootstrap.testingStartRetention(kickstart: false) == [true, false, false, true, true, false],
                                    "bootstrap alias refusal lost actual retired token")
                    }
                }
                heldAlias = nil
                try H.refuses { try bootstrap.retireFailedStartCommands() }
                try H.check(original.hasExpired && bootstrap.failedStartRetirementObservation() == .pending
                    && (try stored(location)) == current,
                    "expired command/alias failure obtained renewed retirement budget")
                try InstallationOwnershipFixtures.excluded(location); try startReplayRefuses(bootstrap)
            }
        }
    }
    static func startPublicationFailure() throws {
        try stagedArchiveAttemptIsSingle()
        for kickstart in [false, true] {
            for completion in [false, true] {
                try exclusiveFixture { root, location, bootstrap, _ in
                    let action: InstallationAction = kickstart ? .kickstartCandidate : .bootstrapCandidate
                    let probe = CustodyCatalogStore.InstallationStagedJournal.TestingPublicationProbe(
                        action: action, status: completion ? .complete : .intent, failure: .afterReceipt)
                    try bootstrap.testingConfigureStarts(publicationProbe: probe)
                    try startPrepared(root, bootstrap)
                    if kickstart { try bootstrap.bootstrapCandidate() }
                    let before = try stored(location)
                    if kickstart { try H.refuses { try bootstrap.kickstartCandidate() } }
                    else { try H.refuses { try bootstrap.bootstrapCandidate() } }
                    guard let observed = probe.observed else { throw H.Failure(message: "bootstrap start persistence cut missed") }
                    let current = try stored(location)
                    try H.check(observed.before == current && current.revision == before.revision + (completion ? 1 : 0)
                        && observed.after.step?.action == action && current.readinessCommit == nil
                        && bootstrap.observation().failedClosed && bootstrap.testingStagedJournalStartsRefused(),
                        "bootstrap start persistence uncertainty rewritten or unfenced")
                    try H.check(bootstrap.testingStartRetention(kickstart: kickstart)
                        == (completion ? [true, false, false, true, true, false] : [false, false, false, false, false, false]),
                        "bootstrap start partial persistence lost retained execution")
                    try InstallationOwnershipFixtures.excluded(location); try startReplayRefuses(bootstrap)
                }
            }
        }
    }
    static func startReturnedFailure() throws {
        try actualObserverDeliveryDisposition()
        try closedArchivePinIntegrity()
        try genuineDeliveryAfterReceipt()
        try stagedProspectiveCloseFailure()
        try retiredBootstrapOutlivesCommandReceipt()
        try failedStartTokenAndConcurrentTurns()
        for kickstart in [false, true] {
            try exclusiveFixture { root, location, bootstrap, _ in
                try bootstrap.testingConfigureStarts(checkpoint: { operation, point in
                    if (operation == .kickstart) == kickstart && point == .completed {
                        throw CustodyRecordError.injectedFailure
                    }
                })
                let original = MonotonicDeadline(seconds: 30)
                try startPrepared(root, bootstrap, deadline: original)
                if kickstart { try bootstrap.bootstrapCandidate() }
                if kickstart { try H.refuses { try bootstrap.kickstartCandidate() } }
                else { try H.refuses { try bootstrap.bootstrapCandidate() } }
                let current = try stored(location)
                try H.check(current.step?.action == (kickstart ? .kickstartCandidate : .bootstrapCandidate)
                    && current.step?.status == .complete && current.phase == .active && current.readinessCommit == nil
                    && bootstrap.testingStartRetention(kickstart: kickstart) == [true, false, false, true, true, true]
                    && bootstrap.testingStagedJournalStartsRefused(),
                    "bootstrap returned command completion was dropped or became installation success")
                try collectFailedStarts(bootstrap, deadline: original)
                try H.check(bootstrap.failedStartRetirementObservation() == .retired
                    && bootstrap.testingFailedStartRetirementRetention(kickstart: kickstart) == [true, true, true]
                    && bootstrap.observation().failedClosed && (try stored(location)) == current,
                    "retirement of returned failure changed installation outcome")
                try H.refuses { try bootstrap.retireFailedStartCommands() }
                try InstallationOwnershipFixtures.excluded(location); try startReplayRefuses(bootstrap)
            }
        }
    }
    static func startRetirementClock() throws {
        try exclusiveFixture { root, _, bootstrap, registry in
            let probe = RetainedCleanupRegistry.ReadinessSchedulingProbe()
            defer { probe.barrier.release() }
            try bootstrap.testingConfigureStarts(checkpoint: { operation, point in
                if operation == .kickstart && point == .commandRetained { registry.testingPauseReadinessScheduling(probe) }
            })
            try startPrepared(root, bootstrap); try bootstrap.bootstrapCandidate()
            let call = ExclusiveCall(bootstrap)
            let work = try RuntimeFixtureSession.installationRoot(root).startWork { try call.bootstrap.kickstartCandidate() }
            try H.check(probe.barrier.waitUntilEntered(), "bootstrap kickstart retirement scheduling not reached")
            guard let captured = probe.absoluteDeadline else { throw H.Failure(message: "bootstrap retirement timestamp absent") }
            try H.check(bootstrap.kickstartStartObservation() == .running
                && bootstrap.testingStartRetention(kickstart: true)[4] == false,
                "bootstrap kickstart invented token before registry delivery")
            Thread.sleep(forTimeInterval: 0.05)
            probe.barrier.release(); try work.value(deadline: .init(seconds: 8))
            try H.refuses { try bootstrap.retireFailedStartCommands() }
            try H.check(bootstrap.failedStartRetirementObservation() == .notAttempted,
                        "successful starts admitted failed-start retirement")
            try H.check(try bootstrap.testingStartReadinessDeadline() == captured
                && bootstrap.testingReadinessSession()?.testingAnchoredDeadline?.absoluteUptimeNanoseconds == captured,
                "bootstrap command delivery or journal completion reset five-second clock")
        }
    }
    static func startScopeClosureDeadline() throws {
        for expire in [false, true] {
            try exclusiveFixture { root, location, bootstrap, registry in
                let original = MonotonicDeadline(seconds: expire ? 0.750 : 30)
                let barrier = CustodyLeaseTestingBarrier(), aliasesReleased = CustodyLeaseTestingBarrier()
                defer { barrier.release(); aliasesReleased.release() }
                try bootstrap.testingConfigureStarts(checkpoint: { [weak bootstrap] operation, point in
                    guard operation == .bootstrap, let bootstrap else { return }
                    if point == .retirementReceived {
                        guard let handle = bootstrap.testingStartHandle(kickstart: false) else {
                            throw H.Failure(message: "bootstrap scope closure missing handle")
                        }
                        // The command is already removed. Pause that same queue
                        // before closeContext queues its final scope closure.
                        registry.testingCancelAndPauseQueue(handle, barrier)
                        try H.check(barrier.waitUntilEntered(), "bootstrap scope close queue cut missing")
                    }
                    if point == .aliasesReleased {
                        try H.check(aliasesReleased.pause(), "bootstrap alias release barrier failed")
                    }
                })
                try startPrepared(root, bootstrap, deadline: original)
                let call = ExclusiveCall(bootstrap)
                let work = try RuntimeFixtureSession.installationRoot(root).startWork {
                    if expire { try H.refuses { try call.bootstrap.bootstrapCandidate() } }
                    else { try call.bootstrap.bootstrapCandidate() }
                }
                try H.check(aliasesReleased.waitUntilEntered(), "bootstrap scope closure did not release client aliases")
                try H.check(bootstrap.testingStartRetention(kickstart: false) == [true, false, false, true, true, false]
                    && bootstrap.bootstrapStartObservation() == .running && bootstrap.testingReadinessJournalLockAvailable()
                    && (try stored(location)).step?.status == .intent,
                    "bootstrap scope closure assumed terminal delivery was final alias retirement")
                aliasesReleased.release()
                if expire {
                    try work.value(deadline: .init(seconds: 2))
                    try H.check(original.hasExpired && bootstrap.bootstrapStartObservation() == .failed
                        && bootstrap.stagedReadinessClosureObservation() == .pending
                        && (try stored(location)).step?.status == .intent,
                        "bootstrap stalled close reset deadline or completed journal")
                    barrier.release()
                    try H.refuses { try bootstrap.retireFailedStartCommands() }
                    try H.check(bootstrap.failedStartRetirementObservation() == .pending
                        && bootstrap.testingFailedStartRetirementRetention(kickstart: false) == [false, true, true],
                        "scope closure continuation refreshed original deadline")
                    try startReplayRefuses(bootstrap)
                } else {
                    // Give the actual validator a chance to observe pending
                    // scope ownership. No snapshot is used as success evidence.
                    Thread.sleep(forTimeInterval: 0.02)
                    try H.check(bootstrap.bootstrapStartObservation() == .running,
                                "bootstrap scope closure completed while queue retained alias")
                    barrier.release(); try work.value(deadline: .init(seconds: 8))
                    try H.check(bootstrap.bootstrapStartObservation() == .complete,
                                "bootstrap delayed scope close did not converge")
                }
                try InstallationOwnershipFixtures.excluded(location)
            }
        }
    }
    static func startBudgetCeilings() throws {
        let fixed = try CustodyBudget.make(kind: .launchctlMutation, workSeconds: 10)
        let originalEndpoints = [fixed.work, fixed.term, fixed.kill, fixed.receipt]
        let short = MonotonicDeadline(seconds: 0.750)
        let clipped = try fixed.clipped(to: short, kind: .launchctlMutation, permittedWorkSeconds: 10)
        let endpoints = [clipped.work, clipped.term, clipped.kill, clipped.receipt]
        try H.check(zip(endpoints, originalEndpoints).allSatisfy { pair in pair.0 <= pair.1 }
            && endpoints.allSatisfy { $0 <= short.absoluteUptimeNanoseconds }
            && clipped.issued == fixed.issued, "bootstrap caller clipping extended an endpoint")
        let long = try fixed.clipped(to: .init(seconds: 30), kind: .launchctlMutation, permittedWorkSeconds: 10)
        try H.check(long == fixed && fixed.work - fixed.issued == 10_000_000_000
            && fixed.term - fixed.work == 2_000_000_000 && fixed.kill - fixed.term == 2_000_000_000
            && fixed.receipt - fixed.kill == 1_000_000_000, "bootstrap optional ceiling changed default command limits")
        try H.refuses { _ = try fixed.clipped(to: .init(seconds: 0), kind: .launchctlMutation, permittedWorkSeconds: 10) }
    }

    private static func readyReplayRefuses(_ bootstrap: B) throws {
        let before = bootstrap.candidateReadinessObservation(), failed = bootstrap.observation().failedClosed
        let retained = bootstrap.testingCandidateReadyRetention()
        // The same retained state must back every diagnostic observation; a
        // refused replay may not expose a context, handle or command budget.
        try H.check((bootstrap.testingCandidateReadyContext() != nil) == retained[1]
            && (bootstrap.testingCandidateReadyHandle() != nil) == retained[3]
            && (bootstrap.testingCandidateReadyBudget() != nil) == retained[2],
            "ready observations disagree with actual retained command custody")
        try H.refuses { try bootstrap.confirmCandidateReady() }
        try H.check(bootstrap.candidateReadinessObservation() == before
            && bootstrap.observation().failedClosed == failed
            && bootstrap.testingCandidateReadyRetention() == retained,
            "bootstrap ready replay changed claim or retained custody")
    }
    static func readyBeforeKickstart() throws {
        try exclusiveFixture { root, location, bootstrap, _ in
            try readyReplayRefuses(bootstrap)
            try startPrepared(root, bootstrap)
            try readyReplayRefuses(bootstrap)
            try bootstrap.bootstrapCandidate()
            try readyReplayRefuses(bootstrap)
            try H.check(bootstrap.candidateReadinessObservation() == .notAttempted,
                        "bootstrap ready invalid order consumed its later claim")
            try bootstrap.kickstartCandidate()
            try H.check(!bootstrap.observation().failedClosed, "ready order poisoned original journal")
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    static func readyClaimFailure() throws {
        try exclusiveFixture { root, location, bootstrap, registry in
            var reached = false
            try bootstrap.testingConfigureCandidateReady(checkpoint: { [weak bootstrap] point in
                guard let bootstrap else { throw H.Failure(message: "bootstrap ready owner lost") }
                try H.check(bootstrap.testingReadinessJournalLockAvailable(), "ready callback holds metadata lock")
                guard point == .claimed else { throw H.Failure(message: "ready claim cut progressed") }
                reached = true
                try readyReplayRefuses(bootstrap)
                throw CustodyRecordError.injectedFailure
            })
            try startPrepared(root, bootstrap); try bootstrap.bootstrapCandidate(); try bootstrap.kickstartCandidate()
            let before = try stored(location)
            do { try bootstrap.confirmCandidateReady(); throw H.Failure(message: "ready claim cut succeeded") }
            catch CustodyRecordError.injectedFailure {}
            try H.check(reached && bootstrap.candidateReadinessObservation() == .failed
                && bootstrap.observation().failedClosed && bootstrap.testingStagedJournalStartsRefused()
                && bootstrap.testingCandidateReadyRetention() == Array(repeating: false, count: 6)
                && bootstrap.stagedReadinessClosureObservation() == .joined
                && registry.testingCount == 0 && registry.testingOriginalHelpersReaped,
                "ready claim failure lost owner or fabricated diagnostic")
            try H.check(try stored(location) == before, "ready claim failure changed durable evidence")
            try readyReplayRefuses(bootstrap); try InstallationOwnershipFixtures.excluded(location)
        }
    }
    static func readyConcurrent() throws {
        try exclusiveFixture { root, location, bootstrap, _ in
            let barrier = CustodyLeaseTestingBarrier()
            defer { barrier.release() }
            try bootstrap.testingConfigureCandidateReady(checkpoint: { point in
                guard point == .claimed else { throw H.Failure(message: "ready concurrent passed claim cut") }
                try H.check(barrier.pause(), "ready concurrent barrier expired")
                throw CustodyRecordError.injectedFailure
            })
            try startPrepared(root, bootstrap); try bootstrap.bootstrapCandidate(); try bootstrap.kickstartCandidate()
            let before = try stored(location), call = ExclusiveCall(bootstrap)
            let work = try RuntimeFixtureSession.installationRoot(root).startWork {
                do { try call.bootstrap.confirmCandidateReady(); throw H.Failure(message: "ready concurrent cut succeeded") }
                catch CustodyRecordError.injectedFailure {}
            }
            try H.check(barrier.waitUntilEntered(), "ready concurrent did not claim")
            try H.check(bootstrap.candidateReadinessObservation() == .running
                && bootstrap.testingReadinessJournalLockAvailable(), "ready callback spans owner lock")
            try readyReplayRefuses(bootstrap); try InstallationOwnershipFixtures.excluded(location)
            barrier.release(); try work.value(deadline: .init(seconds: 3))
            try H.check(try stored(location) == before && bootstrap.candidateReadinessObservation() == .failed,
                        "ready concurrent loser changed durable state")
        }
    }
    static func readyRequiresAuthenticatedPeer() throws {
        try exclusiveFixture { root, location, bootstrap, registry in
            try startPrepared(root, bootstrap); try bootstrap.bootstrapCandidate(); try bootstrap.kickstartCandidate()
            let before = try stored(location)
            guard let session = bootstrap.testingReadinessSession(), let deadline = session.testingAnchoredDeadline else {
                throw H.Failure(message: "ready refusal missing original session")
            }
            // No peer, message, PID or ready flag is supplied. The real bounded
            // session must expire rather than minting diagnostic authority.
            try H.refuses { try bootstrap.confirmCandidateReady() }
            try H.check(deadline.hasExpired && bootstrap.candidateReadinessObservation() == .failed
                && bootstrap.observation().failedClosed && bootstrap.testingStagedJournalStartsRefused()
                && bootstrap.testingCandidateReadyRetention() == Array(repeating: false, count: 6)
                && registry.testingCount == 0 && registry.testingOriginalHelpersReaped,
                "ready missing peer fabricated convergence or renewed deadline")
            try H.check(try stored(location) == before && before.phase == .active && before.readinessCommit == nil,
                        "unready continuation committed or changed evidence")
            try readyReplayRefuses(bootstrap); try InstallationOwnershipFixtures.excluded(location)
        }
    }
    static func readyRetirementDeadline() throws {
        try exclusiveFixture { root, location, bootstrap, _ in
            var anchored: UInt64?
            try bootstrap.testingConfigureCandidateReady(checkpoint: { [weak bootstrap] point in
                guard point == .claimed, let bootstrap,
                      let deadline = bootstrap.testingReadinessSession()?.testingAnchoredDeadline else {
                    throw H.Failure(message: "ready deadline lost original anchor")
                }
                anchored = deadline.absoluteUptimeNanoseconds
                while !deadline.hasExpired { Thread.sleep(forTimeInterval: 0.001) }
            })
            try startPrepared(root, bootstrap); try bootstrap.bootstrapCandidate(); try bootstrap.kickstartCandidate()
            let deadline = try bootstrap.testingStartReadinessDeadline(), before = try stored(location)
            try H.refuses { try bootstrap.confirmCandidateReady() }
            try H.check(anchored == deadline && bootstrap.candidateReadinessObservation() == .failed
                && bootstrap.testingCandidateReadyRetention() == Array(repeating: false, count: 6)
                && bootstrap.stagedReadinessClosureObservation() == .pending,
                "ready claim reset retirement clock or invented joined cleanup")
            try H.check(try stored(location) == before, "expired readiness changed control")
            try readyReplayRefuses(bootstrap); try InstallationOwnershipFixtures.excluded(location)
        }
    }

    static func readyInvocationCeiling() throws {
        try exclusiveFixture { root, location, bootstrap, _ in
            let invocation = MonotonicDeadline(seconds: 3)
            try startPrepared(root, bootstrap, deadline: invocation)
            try bootstrap.bootstrapCandidate(); try bootstrap.kickstartCandidate()
            let retirement = try bootstrap.testingStartReadinessDeadline()
            guard let session = bootstrap.testingReadinessSession(), let anchored = session.testingAnchoredDeadline else {
                throw H.Failure(message: "ready ceiling missing actual session")
            }
            try H.check(anchored.absoluteUptimeNanoseconds == min(invocation.absoluteUptimeNanoseconds, retirement)
                && anchored.absoluteUptimeNanoseconds == invocation.absoluteUptimeNanoseconds,
                "ready session discarded original invocation ceiling")
            let before = try stored(location)
            try H.refuses { try bootstrap.confirmCandidateReady() }
            try H.check(invocation.hasExpired && !MonotonicDeadline(uptimeNanoseconds: retirement).hasExpired
                && bootstrap.candidateReadinessObservation() == .failed
                && bootstrap.testingCandidateReadyRetention() == Array(repeating: false, count: 6),
                "ready wait renewed the caller budget at kickstart retirement")
            try H.check(try stored(location) == before, "expired invocation published readiness")
            try readyReplayRefuses(bootstrap); try InstallationOwnershipFixtures.excluded(location)
        }
    }
    static func cleanupBeforeStartup() throws {
        try exclusiveFixture { root, location, bootstrap, _ in
            for phase in 0..<3 {
                if phase == 1 { try startPrepared(root, bootstrap) }
                if phase == 2 { try bootstrap.bootstrapCandidate(); try bootstrap.kickstartCandidate() }
                let repairBefore = try stored(location)
                try H.refuses { try bootstrap.repairStoppedFreshInstallation() }
                try H.refuses { try bootstrap.restoreStoppedFreshInstallation() }
                try H.check(try stored(location) == repairBefore && bootstrap.completionObservation() == .notAttempted,
                    "unretained stopped repair changed control or consumed completion")
                try H.refuses { try bootstrap.cleanupReadinessCoordination() }
                try H.refuses { try bootstrap.stopReadinessOnlyHost() }
                try H.check(bootstrap.stoppedRecoveryObservation() == .notAttempted,
                    "incomplete readiness granted stop or mutated original continuation")
                try H.check(bootstrap.coordinationCleanupObservation() == .notAttempted
                    && !bootstrap.observation().failedClosed,
                    "cleanup preclaim fabricated authenticated startup or consumed valid continuation")
            }
            try H.check(try stored(location).readinessCommit == nil, "cleanup preclaim manufactured commit")
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    static func startupBeforeCommit() throws {
        try InstallationFreshRetirementManifestFixtures.bounds()
        try exclusiveFixture { root, location, bootstrap, _ in
            try H.refuses { try bootstrap.observeNormalStartup() }
            try H.refuses { try bootstrap.stopNormallyStartedHost() }
            try H.refuses { try authenticatedCommittedStoppedContinuation(bootstrap, root: root, location: location) }
            try H.refuses { try authenticatedFreshStoppedRestoration(bootstrap, root: root, location: location) }
            try H.refuses { try authenticatedFreshRestorationTerminalCut(bootstrap, root: root, location: location, resource: .metadata) }
            try H.refuses { try authenticatedFreshRestorationContention(bootstrap, root: root, location: location) }
            for replaceChild in [false,true] {
                try H.refuses { try authenticatedFreshPartialTreeRefusal(bootstrap, root: root, location: location, replaceChild: replaceChild) }
            }
            for mutation in FreshRestorationMutation.allCases {
                try H.refuses { try authenticatedFreshInCallMutationRefusal(bootstrap, root: root, location: location, mutation: mutation) }
            }
            for fault in InstallationFreshRestorationResourceFault.allCases {
                try H.refuses { try authenticatedFreshResourceRefusal(bootstrap, root: root, location: location, fault: fault) }
            }
            for adversary in FreshRestorationAdversary.allCases {
                try H.refuses { try authenticatedFreshRestorationRefusal(bootstrap, root: root, location: location, adversary: adversary) }
            }
            for cut in StoppedFreshRepairCut.allCases {
                try H.refuses { try authenticatedStoppedFreshRepair(bootstrap, root: root, location: location, cut: cut) }
            }
            try H.refuses { try bootstrap.stopReadinessOnlyHost() }
            try H.refuses { try authenticatedReadinessStoppedContinuation(bootstrap, root: root, location: location) }
            try H.refuses { try authenticatedReadinessStoppedContinuation(bootstrap, root: root, location: location,
                cut: .streamClosedBeforeStop) }
            try H.check(bootstrap.stoppedRecoveryObservation() == .notAttempted,
                        "unauthenticated bootstrap minted stopped recovery")
            try H.check(bootstrap.normalStartupObservation() == .notAttempted
                && !bootstrap.observation().attempted, "invalid startup preclaim consumed bootstrap")
        }
    }
    /// Existing signed driver supplies the original invocation after actual
    /// authenticated NormalStarted, plus its enrolled fixed-command helper.
    /// Prerequisite refusal is registered; a refusal is not a positive run.
    @inline(never)
    static func authenticatedCommittedStoppedContinuation(_ bootstrap: InstallationBootstrap,
        root: String, location: StateLocation) throws {
        _ = try RuntimeFixtureSession.installationRoot(TestIsolation.validateRoot(root))
        guard bootstrap.normalStartupObservation() == .observed,
              bootstrap.coordinationCleanupObservation() == .notAttempted,
              bootstrap.completionObservation() == .notAttempted else { throw CustodyRecordError.fenced }
        let before = try stored(location)
        guard before.phase == .committed, before.readinessCommit != nil,
              before.step?.action == .readinessCommit else { throw CustodyRecordError.fenced }
        let quiet = try PolicyAuthorityFile.read(path: root + "/home/.staged-completion-quiet",
            owner: geteuid(), maximumBytes: 32)
        try H.check(quiet.bytes == Data("staged-completion-quiet/v1\n".utf8),
                    "signed stopped Bootstrap omitted actual command fixture contract")
        try InstallationOwnershipFixtures.excluded(location)
        try bootstrap.stopNormallyStartedHost()
        let after = try stored(location)
        try H.check(bootstrap.stoppedRecoveryObservation() == .exclusive
            && bootstrap.stoppedDeliveryObservation() == .complete
            && after.phase == .recovery && after.readinessCommit == before.readinessCommit
            && after.state == before.state && after.step == before.step,
                    "actual Bootstrap stopped continuation lost commit or exclusive custody")
        try InstallationOwnershipFixtures.excluded(location)
        try InstallationOwnershipFixtures.excluded(location, name: "lifecycle.lock")
        try H.refuses { try bootstrap.stopNormallyStartedHost() }
        try H.refuses { try bootstrap.finishFreshInstallation() }
    }
    enum StoppedFreshRepairCut: CaseIterable { case none, endpointAfterUnlink, endpointParentSync, endpointAncestorClose, receiptAfterWrite, controlBeforeWrite }
    /// The signed driver must supply the same original authenticated invocation.
    /// Ordinary enrollment tests only the prerequisite refusal, never a positive.
    @inline(never)
    static func authenticatedStoppedFreshRepair(_ bootstrap: InstallationBootstrap,
        root: String, location: StateLocation, cut: StoppedFreshRepairCut = .none) throws {
        _ = try RuntimeFixtureSession.installationRoot(TestIsolation.validateRoot(root))
        guard bootstrap.normalStartupObservation() == .observed,
              bootstrap.stoppedRecoveryObservation() == .notAttempted,
              bootstrap.coordinationCleanupObservation() == .notAttempted else { throw CustodyRecordError.fenced }
        let before = try stored(location)
        guard before.transaction?.intent == .install, before.transaction?.priorCommitDigest == nil else {
            throw CustodyRecordError.fenced
        }
        try authenticatedCommittedStoppedContinuation(bootstrap, root: root, location: location)
        let endpointCut: InstallationReadinessEndpoint.CleanupCut?
        switch cut {
        case .none, .receiptAfterWrite, .controlBeforeWrite: endpointCut = nil
        case .endpointAfterUnlink: endpointCut = .afterUnlink
        case .endpointParentSync: endpointCut = .parentSyncFailure
        case .endpointAncestorClose: endpointCut = .beforeAncestorClose
        }
        if let endpointCut { try bootstrap.testingStoppedRepairCut(endpointCut) }
        if cut == .receiptAfterWrite || cut == .controlBeforeWrite {
            try bootstrap.testingStoppedRepairPublicationCut(beforeControl: cut == .controlBeforeWrite)
        }
        if cut != .none {
            try H.refuses { try bootstrap.repairStoppedFreshInstallation() }
            let interrupted = try stored(location)
            try H.check(interrupted.phase == .recovery && interrupted.readinessCommit == before.readinessCommit
                && bootstrap.completionObservation() == .pending,
                "stopped cleanup cut lost commit or reported completion")
            try InstallationOwnershipFixtures.excluded(location)
            try InstallationOwnershipFixtures.excluded(location, name: "lifecycle.lock")
        }
        try bootstrap.repairStoppedFreshInstallation()
        let after = try stored(location)
        try H.check(after.phase == .committed && after.readinessCommit == before.readinessCommit
            && after.transaction?.id == before.transaction?.id && after.state == before.state
            && after.step?.action == .finish && after.step?.status == .complete
            && bootstrap.completionObservation() == .complete,
            "stopped fresh suffix did not preserve commit through durable checked finish")
        for slot in [InstallationSlot.installationSocket, .hostOwner, .hostSocket, .applicationIncoming,
                     .applicationPrevious, .plistIncoming, .plistPrevious] {
            try H.check(after.transaction?.slots.images[slot]?.node == nil, "stopped repair retained forbidden residue")
        }
        try InstallationOwnershipFixtures.excluded(location, expected: false)
        try InstallationOwnershipFixtures.excluded(location, name: "lifecycle.lock", expected: false)
        try H.refuses { try bootstrap.repairStoppedFreshInstallation() }
        try H.refuses { try bootstrap.finishFreshInstallation() }
        try H.refuses { try bootstrap.stopNormallyStartedHost() }
    }
    /// Requires the real signed readiness and bootout chain. The ordinary
    /// registered before-commit case proves refusal, never a positive token.
    @inline(never)
    static func authenticatedFreshStoppedRestoration(_ bootstrap: InstallationBootstrap,
        root: String, location: StateLocation, cut: InstallationFreshRestorationCut? = nil,
        endpointCut: InstallationReadinessEndpoint.CleanupCut? = nil,
        publicationBeforeControl: Bool? = nil) throws {
        _ = try RuntimeFixtureSession.installationRoot(TestIsolation.validateRoot(root))
        guard bootstrap.candidateReadinessObservation() == .complete,
              bootstrap.readinessCommitObservation() == .notAttempted,
              bootstrap.normalStartupObservation() == .notAttempted else { throw CustodyRecordError.fenced }
        try authenticatedReadinessStoppedContinuation(bootstrap, root: root, location: location)
        let before = try stored(location, bootstrap: bootstrap)
        if let cut { try bootstrap.testingFreshRestorationCut(cut) }
        if let endpointCut { try bootstrap.testingReadinessRestorationEndpointCut(endpointCut) }
        if let publicationBeforeControl { try bootstrap.testingStoppedRepairPublicationCut(beforeControl: publicationBeforeControl) }
        if cut != nil || endpointCut != nil || publicationBeforeControl != nil {
            try H.refuses { try bootstrap.restoreStoppedFreshInstallation() }
            if let cut { try H.check(bootstrap.testingFreshRestorationReachedCut == cut, "fresh restoration fault was not reached") }
            let interrupted = try stored(location, bootstrap: bootstrap)
            try H.check(interrupted.phase == .recovery && interrupted.readinessCommit == nil
                && interrupted.state == before.state && interrupted.transaction?.id == before.transaction?.id
                && bootstrap.completionObservation() == .pending,
                "fresh stopped restoration cut fabricated completion or lost fence")
            try InstallationOwnershipFixtures.excluded(location)
            try InstallationOwnershipFixtures.excluded(location, name: "lifecycle.lock")
            if case .some(.closeUnknown(_)) = cut {
                try H.refuses { try bootstrap.restoreStoppedFreshInstallation() }; return
            }
            if cut == .plistCloseUnknown {
                try H.refuses { try bootstrap.restoreStoppedFreshInstallation() }; return
            }
        }
        try bootstrap.restoreStoppedFreshInstallation()
        let after = try stored(location, bootstrap: bootstrap)
        try H.check(after.phase == .recovery && after.recoveryReason == .restoredStopped && after.readinessCommit == nil
            && after.state == before.state && after.transaction?.id == before.transaction?.id
            && after.step?.action == .finish && after.step?.status == .complete
            && bootstrap.completionObservation() == .complete,
            "fresh rollback did not retain stopped recovery through checked operation-last finish")
        for slot in InstallationSlot.allCases where slot != .stateDestination {
            try H.check(after.transaction?.slots.images[slot]?.node == nil, "fresh restoration retained nonpreimage slot")
        }
        try InstallationOwnershipFixtures.excluded(location, expected: false)
        try InstallationOwnershipFixtures.excluded(location, name: "lifecycle.lock", expected: false)
        try H.refuses { try bootstrap.restoreStoppedFreshInstallation() }
        try H.refuses { try bootstrap.repairStoppedFreshInstallation() }
        try H.refuses { try bootstrap.finishFreshInstallation() }
        try H.refuses { try bootstrap.commitCandidateReadiness() }
    }
    @inline(never)
    static func authenticatedFreshPartialTreeRefusal(_ bootstrap: InstallationBootstrap,
        root: String, location: StateLocation, replaceChild: Bool) throws {
        _ = try RuntimeFixtureSession.installationRoot(TestIsolation.validateRoot(root))
        guard bootstrap.candidateReadinessObservation() == .complete,
              bootstrap.readinessCommitObservation() == .notAttempted,
              bootstrap.normalStartupObservation() == .notAttempted else { throw CustodyRecordError.fenced }
        try authenticatedReadinessStoppedContinuation(bootstrap, root: root, location: location)
        try bootstrap.testingFreshRestorationCut(.afterUnlink(0))
        try H.refuses { try bootstrap.restoreStoppedFreshInstallation() }
        try H.check(bootstrap.testingFreshRestorationReachedCut == .afterUnlink(0), "partial-tree unlink fault not reached")
        let control = try stored(location, bootstrap: bootstrap), application = root + "/home/Applications/ShadowSync.app"
        try H.check(control.step?.action == .restoreApplication && control.step?.status == .intent
            && control.phase == .recovery && control.readinessCommit == nil, "partial deletion published a complete bundle image")
        if replaceChild {
            guard let enumerator = FileManager.default.enumerator(atPath: application) else { throw CustodyRecordError.fenced }
            var target: String?
            while let relative = enumerator.nextObject() as? String {
                let path = application + "/" + relative
                var info = stat()
                if lstat(path,&info) == 0 && info.st_mode & S_IFMT == S_IFREG { target = path; break }
            }
            guard let target else { throw CustodyRecordError.fenced }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: target))
            var info = stat(); try H.check(lstat(target,&info) == 0, "partial-tree replacement identity")
            try H.check(unlink(target) == 0, "partial-tree unexplained child unlink")
            try bytes.write(to: URL(fileURLWithPath: target),options: .withoutOverwriting)
            try H.check(chmod(target,info.st_mode & 0o7777) == 0, "partial-tree replacement mode")
        } else {
            let raw = open(application + "/fixture-unlisted",O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
            try H.check(raw >= 0, "partial-tree extra child")
            try H.check(OwnedFileDescriptor(raw).retireChecked() == .succeeded, "partial-tree extra child close")
        }
        let changed = try H.snapshot(application)
        try H.refuses { try bootstrap.restoreStoppedFreshInstallation() }
        try H.check(try stored(location, bootstrap: bootstrap) == control && H.snapshot(application) == changed,
            "partial-tree drift caused more deletion or completed receipt")
        try InstallationOwnershipFixtures.excluded(location)
        try InstallationOwnershipFixtures.excluded(location,name: "lifecycle.lock")
    }
    @inline(never)
    static func authenticatedFreshRestorationTerminalCut(_ bootstrap: InstallationBootstrap,
        root: String, location: StateLocation,
        resource: CustodyCatalogStore.InstallationStagedJournal.FinishPermit.Resource,
        expireAfterSuccessfulOperationClose: Bool = false) throws {
        guard bootstrap.candidateReadinessObservation() == .complete,
              bootstrap.readinessCommitObservation() == .notAttempted,
              bootstrap.normalStartupObservation() == .notAttempted,
              resource != .stagedSlots && resource != .temporaryStore,
              !expireAfterSuccessfulOperationClose || resource == .operation else { throw CustodyRecordError.fenced }
        try authenticatedReadinessStoppedContinuation(bootstrap, root: root, location: location)
        guard let journal = bootstrap.testingTerminalJournal() else { throw CustodyRecordError.fenced }
        if expireAfterSuccessfulOperationClose { journal.testingTerminalDeadlineAfterSuccessfulClose = .operation }
        else { journal.testingTerminalUncertainClose = resource }
        try H.refuses { try bootstrap.restoreStoppedFreshInstallation() }
        guard let finish = journal.testingTerminalPermit else { throw H.Failure(message: "fresh terminal cut not reached") }
        let state = try stored(location, bootstrap: bootstrap), ownership = journal.testingOwner.testingTerminalOwnership()
        try H.check(journal.testingTerminalUncertainClose == nil
            && journal.testingTerminalDeadlineAfterSuccessfulClose == nil
            && journal.terminalObservation() == .pending && bootstrap.completionObservation() == .pending
            && journal.testingTerminalCustodyRetained && !ownership.complete
            && state == finish.control && state.phase == .recovery && state.recoveryReason == .restoredStopped
            && state.readinessCommit == nil && state.step?.action == .finish && state.step?.status == .complete,
            "fresh terminal uncertainty escaped stopped recovery or dropped custody")
        if resource == .operation {
            if expireAfterSuccessfulOperationClose {
                try H.check(ownership.operation == .succeeded && finish.deadline.hasExpired,
                    "fresh successful operation close deadline did not reach actual close")
            } else {
                if case .uncertain = ownership.operation {} else { throw H.Failure(message: "fresh operation close cut not reached") }
            }
            // A failed close can already have released EX in the kernel. Do not
            // infer exclusion; durable recovery and retained uncertainty remain.
        } else {
            try H.check(ownership.operation == .notAttempted, "fresh early close failure attempted operation release")
            try InstallationOwnershipFixtures.excluded(location)
        }
        try H.refuses { try bootstrap.restoreStoppedFreshInstallation() }
        try H.refuses { try bootstrap.finishFreshInstallation() }
        try H.check(try stored(location, bootstrap: bootstrap) == state, "fresh terminal replay changed recovery fence")
    }
    /// Each value is a separate fixture/root/invocation in the signed driver.
    /// These cells enter the actual stopped route, then mutate at the second
    /// child boundary WITHOUT unwinding or reentering Bootstrap.
    enum FreshRestorationMutation: CaseIterable {
        case operationLock, lifecycleLock, namespaceLock, catalogGuard, catalog, control, receipt, source, registry, launchPlist
        case extraChild, missingChild, replacedChild, changedContent, changedMode, changedACL, changedXattr
        case changedHardLink, changedFlags, changedGID, changedSealedLink, replacedRoot, replacedParent
    }
    private static func freshReplaceFile(_ path: String, retained: String) throws {
        var before = stat()
        try H.check(lstat(path, &before) == 0 && before.st_mode & S_IFMT == S_IFREG,
            "fresh mutation original regular node")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        try H.check(rename(path, retained) == 0, "fresh mutation retains original inode")
        try bytes.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        try H.check(chmod(path, before.st_mode & 0o7777) == 0, "fresh mutation replacement mode")
        var after = stat()
        try H.check(lstat(path, &after) == 0 && after.st_ino != before.st_ino,
            "fresh mutation did not substitute named inode")
    }
    private static func freshGrantACL(_ path: String) throws {
        let raw = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try H.check(raw >= 0, "fresh mutation ACL open")
        let descriptor = OwnedFileDescriptor(raw)
        do {
            let before = try H.rawACL(path)
            var acl = acl_init(1)
            defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
            var entry: acl_entry_t?
            try H.check(acl_create_entry(&acl, &entry) == 0 && entry != nil, "fresh mutation ACL entry")
            var uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!.uuid
            try H.check(acl_set_tag_type(entry!, ACL_EXTENDED_ALLOW) == 0
                && acl_set_qualifier(entry!, &uuid) == 0, "fresh mutation ACL qualifier")
            var permissions: acl_permset_t?
            try H.check(acl_get_permset(entry!, &permissions) == 0 && permissions != nil
                && acl_add_perm(permissions!, ACL_READ_DATA) == 0
                && acl_set_fd_np(raw, acl, ACL_TYPE_EXTENDED) == 0, "fresh mutation ACL grant")
            try H.check(try H.rawACL(path) != before, "fresh mutation ACL not changed")
            try H.check(descriptor.retireChecked() == .succeeded, "fresh mutation ACL checked close")
        } catch {
            guard descriptor.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }
            throw error
        }
    }
    @inline(never)
    static func authenticatedFreshInCallMutationRefusal(_ bootstrap: InstallationBootstrap,
        root: String, location: StateLocation, mutation: FreshRestorationMutation) throws {
        let custody = try RuntimeFixtureSession.installationRoot(TestIsolation.validateRoot(root))
        guard bootstrap.candidateReadinessObservation() == .complete,
              bootstrap.readinessCommitObservation() == .notAttempted,
              bootstrap.normalStartupObservation() == .notAttempted,
              let session = bootstrap.testingReadinessSession(), let deadline = session.testingAnchoredDeadline else {
            throw CustodyRecordError.fenced
        }
        try authenticatedReadinessStoppedContinuation(bootstrap, root: root, location: location)
        guard let journal = bootstrap.testingTerminalJournal(),
              let registry = journal.testingFreshRestorationRegistry else { throw CustodyRecordError.fenced }
        let source = mutation == .source ? try journal.testingOwner.testingFreshRestorationSourceBundle(root: root) : nil
        let application = root + "/home/Applications/ShadowSync.app"
        let replacementRegistry = RetainedCleanupRegistry.testingInstance()
        custody.retain(replacementRegistry) // retain even if a later assertion throws
        var reached = false
        var pinnedControl: InstallationControlRecord?
        var changed: [String: H.Snapshot]?
        var retainedLock: String?
        try bootstrap.testingFreshRestorationMutationBarrier { [weak bootstrap, weak journal] count, nextPath in
            guard let bootstrap, let journal else { throw H.Failure(message: "fresh original fixture owners lost") }
            try H.check(!reached && count == 1 && bootstrap.testingFreshRestorationUnlinks == 1
                && !deadline.hasExpired, "fresh in-call mutation missed first successful unlink")
            reached = true
            let control = try stored(location, bootstrap: bootstrap)
            try H.check(control.phase == .recovery && control.readinessCommit == nil
                && control.transaction?.intent == .install && control.transaction?.priorCommitDigest == nil
                && control.step?.action == .restoreApplication && control.step?.status == .intent,
                "fresh in-call mutation has no exact restore intent")
            pinnedControl = control
            // Prefer the next held child, otherwise a remaining regular leaf.
            // The candidate is partial; do not inspect it as a signed bundle.
            var target = application + "/" + nextPath, info = stat()
            if lstat(target, &info) != 0 || info.st_mode & S_IFMT != S_IFREG {
                guard let enumerator = FileManager.default.enumerator(atPath: application) else { throw H.Failure(message: "fresh remaining manifest") }
                var found: String?
                while let relative = enumerator.nextObject() as? String {
                    let path = application + "/" + relative
                    if lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG { found = path; break }
                }
                guard let found else { throw H.Failure(message: "fresh fixture requires a second regular child") }
                target = found
            }
            switch mutation {
            case .operationLock, .lifecycleLock, .namespaceLock:
                let name = mutation == .operationLock ? "operation.lock" : mutation == .lifecycleLock ? "lifecycle.lock" : "latest.log"
                retainedLock = name + ".fixture-held"
                try freshReplaceFile(location.path + "/" + name, retained: location.path + "/" + retainedLock!)
                // Verify the old description really still excludes its retained
                // inode; the replacement name MUST NOT be reported protected.
                try InstallationOwnershipFixtures.excluded(location, name: retainedLock!)
                try InstallationOwnershipFixtures.excluded(location, name: name, expected: false)
            case .catalogGuard:
                try freshReplaceFile(location.path + "/custody/catalog.lock", retained: root + "/fixture-held-catalog-lock")
            case .catalog:
                try freshReplaceFile(location.path + "/custody/catalog.json", retained: root + "/fixture-held-catalog")
            case .control:
                try freshReplaceFile(location.path + "/custody/" + InstallationControlRecord.filename,
                    retained: root + "/fixture-held-control")
            case .receipt:
                let names = try FileManager.default.contentsOfDirectory(atPath: location.path + "/custody/receipts")
                guard let name = names.sorted().first(where: { $0.hasPrefix(InstallationStepReceipt.prefix) }) else {
                    throw H.Failure(message: "fresh in-call original receipt missing")
                }
                try freshReplaceFile(location.path + "/custody/receipts/" + name, retained: root + "/fixture-held-receipt")
            case .source:
                guard let source, source.hasPrefix(root + "/"), source != application else { throw H.Failure(message: "fresh owned source prerequisite") }
                // Change the independently bound original source, not the
                // partially retired installed tree. Its original root is kept.
                try H.check(rename(source, root + "/fixture-held-source") == 0
                    && mkdir(source, 0o755) == 0, "fresh in-call source substitution")
            case .registry:
                try journal.testingOwner.testingSubstituteRetirementRegistry(replacementRegistry, root: root)
            case .launchPlist:
                try freshReplaceFile(root + "/home/Library/LaunchAgents/com.kleinperkins.shadow-sync.plist",
                    retained: root + "/fixture-held-plist")
            case .extraChild:
                try Data("unlisted".utf8).write(to: URL(fileURLWithPath: application + "/fixture-unlisted"), options: .withoutOverwriting)
            case .missingChild:
                try H.check(unlink(target) == 0, "fresh in-call missing child")
            case .replacedChild:
                try freshReplaceFile(target, retained: root + "/fixture-held-child")
            case .changedContent:
                let raw = open(target, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                try H.check(raw >= 0, "fresh in-call content open")
                let descriptor = OwnedFileDescriptor(raw)
                var byte: UInt8 = 0
                let read = pread(raw, &byte, 1, 0)
                byte ^= 1
                let changed = read >= 0 && pwrite(raw, &byte, 1, 0) == 1 && fsync(raw) == 0
                let closed = descriptor.retireChecked() == .succeeded
                try H.check(changed && closed, "fresh in-call content mutation/close")
            case .changedMode:
                try H.check(chmod(target, (info.st_mode & 0o7777) ^ 0o100) == 0, "fresh in-call mode mutation")
            case .changedACL:
                try freshGrantACL(target)
            case .changedXattr:
                var byte: UInt8 = 1
                try H.check(setxattr(target, "com.example.fixture-retirement", &byte, 1, 0, XATTR_NOFOLLOW) == 0,
                    "fresh in-call xattr mutation")
            case .changedHardLink:
                try H.check(link(target, root + "/fixture-hard-link") == 0, "fresh in-call hard link")
                var changed = stat()
                try H.check(lstat(target, &changed) == 0 && changed.st_nlink == info.st_nlink + 1,
                    "fresh in-call hard link not applied")
            case .changedFlags:
                try H.check(chflags(target, UInt32(UF_HIDDEN)) == 0, "fresh in-call flags mutation")
            case .changedGID:
                let count = getgroups(0, nil)
                try H.check(count > 0 && count <= 1024, "fresh gid fixture requires a bounded group list")
                var groups = [gid_t](repeating: 0, count: Int(count))
                try H.check(getgroups(count, &groups) == count, "fresh gid fixture groups")
                guard let group = groups.first(where: { $0 != info.st_gid }) else {
                    throw H.Failure(message: "fresh gid cell requires a permitted alternate fixture group")
                }
                try H.check(chown(target, uid_t.max, group) == 0, "fresh in-call gid mutation")
                var changed = stat()
                try H.check(lstat(target, &changed) == 0 && changed.st_gid == group && changed.st_uid == info.st_uid,
                    "fresh in-call gid not applied")
            case .changedSealedLink:
                guard let enumerator = FileManager.default.enumerator(atPath: application) else { throw H.Failure(message: "fresh sealed link roster") }
                var linkPath: String?
                while let relative = enumerator.nextObject() as? String {
                    let path = application + "/" + relative
                    var node = stat()
                    if lstat(path, &node) == 0 && node.st_mode & S_IFMT == S_IFLNK { linkPath = path; break }
                }
                guard let linkPath else { throw H.Failure(message: "fresh cell requires a remaining sealed link") }
                try H.check(unlink(linkPath) == 0 && symlink("../../fixture-escape", linkPath) == 0,
                    "fresh in-call sealed link substitution")
            case .replacedRoot:
                try H.check(rename(application, root + "/fixture-held-app") == 0 && mkdir(application, 0o755) == 0,
                    "fresh in-call app substitution")
            case .replacedParent:
                let parent = root + "/home/Applications"
                try H.check(rename(parent, root + "/fixture-held-applications") == 0 && mkdir(parent, 0o755) == 0,
                    "fresh in-call parent substitution")
            }
            changed = try H.snapshot(root)
            try H.check(!deadline.hasExpired, "fresh mutation setup exhausted original deadline")
        }
        // Exactly one uninterrupted call: a second Bootstrap call would exercise
        // outer preflight and conceal a missing per-child live gate.
        try H.refuses { try bootstrap.restoreStoppedFreshInstallation() }
        try H.check(reached && !deadline.hasExpired && bootstrap.testingFreshRestorationUnlinks == 1,
            "fresh in-call mutation did not stop the next unlink within the original deadline")
        guard let pinnedControl, let changed else { throw H.Failure(message: "fresh in-call barrier not observed") }
        try H.check(try stored(location, bootstrap: bootstrap) == pinnedControl && H.snapshot(root) == changed
            && bootstrap.completionObservation() == .pending,
            "fresh in-call substitution changed pins, unrelated bytes or continued deletion")
        if let retainedLock {
            try InstallationOwnershipFixtures.excluded(location, name: retainedLock)
            let replaced = mutation == .operationLock ? "operation.lock" : mutation == .lifecycleLock ? "lifecycle.lock" : "latest.log"
            try InstallationOwnershipFixtures.excluded(location, name: replaced, expected: false)
            for name in ["operation.lock", "lifecycle.lock", "latest.log"] where name != replaced {
                try InstallationOwnershipFixtures.excluded(location, name: name)
            }
        } else {
            try InstallationOwnershipFixtures.excluded(location)
            try InstallationOwnershipFixtures.excluded(location, name: "lifecycle.lock")
        }
        try H.check(!registry.hasRetainedWork && registry.testingCount == 0 && registry.testingOriginalHelpersReaped,
            "fresh mutation fixture lost original command children")
        try H.check(!replacementRegistry.hasRetainedWork && replacementRegistry.testingOriginalHelpersReaped,
            "fresh mutation replacement registry acquired work")
    }
    @inline(never)
    static func authenticatedFreshResourceRefusal(_ bootstrap: InstallationBootstrap,
        root: String, location: StateLocation, fault: InstallationFreshRestorationResourceFault) throws {
        _ = try RuntimeFixtureSession.installationRoot(TestIsolation.validateRoot(root))
        guard bootstrap.candidateReadinessObservation() == .complete,
              bootstrap.readinessCommitObservation() == .notAttempted,
              bootstrap.normalStartupObservation() == .notAttempted,
              let session = bootstrap.testingReadinessSession(), let deadline = session.testingAnchoredDeadline else {
            throw CustodyRecordError.fenced
        }
        try authenticatedReadinessStoppedContinuation(bootstrap, root: root, location: location)
        guard let journal = bootstrap.testingTerminalJournal(), let registry = journal.testingFreshRestorationRegistry else {
            throw CustodyRecordError.fenced
        }
        try bootstrap.testingFreshRestorationResourceFault(fault)
        // These are owned syscall-site failures, never host descriptor pressure
        // or rlimit changes. Acquisition that succeeded is enrolled before fault.
        try H.refuses { try bootstrap.restoreStoppedFreshInstallation() }
        guard let observed = bootstrap.testingFreshRestorationResources else { throw H.Failure(message: "fresh resource owner absent") }
        try H.check(observed.fault == fault && !deadline.hasExpired
            && observed.unlinks == (fault.isPartial ? 1 : 0)
            && observed.acquired == observed.closed + observed.retained,
            "fresh resource fault unreached, masked by expiry, or descriptor enrollment lost")
        let control = try stored(location, bootstrap: bootstrap), snapshot = try H.snapshot(root)
        try H.check(control.phase == .recovery && control.readinessCommit == nil
            && control.step?.action == .restoreApplication && control.step?.status == .intent
            && bootstrap.completionObservation() == .pending, "fresh resource failure lost exact durable intent")
        try InstallationOwnershipFixtures.excluded(location)
        try InstallationOwnershipFixtures.excluded(location, name: "lifecycle.lock")
        if !fault.isPartial {
            try H.refuses { try bootstrap.restoreStoppedFreshInstallation() }
            try H.check(try stored(location, bootstrap: bootstrap) == control && H.snapshot(root) == snapshot,
                "fresh failed enrollment was adopted by retry")
        }
        try H.check(!registry.hasRetainedWork && registry.testingCount == 0 && registry.testingOriginalHelpersReaped,
            "fresh resource failure lost original children")
        // Actual retained descriptions are handed to the root's already-enrolled
        // retirement object; guardian cleanup checks every close before removal.
    }
    enum FreshRestorationAdversary: CaseIterable {
        case extraChild, missingChild, replacedChild, changedContent, changedMode, changedXattr
        case changedSealedLink, replacedRoot, replacedParent, originalDeadline
    }
    /// These checks deliberately change real disposable filesystem nodes after
    /// the genuine drain. They cannot manufacture the drain or bypass the source
    /// verifier. Root cleanup remains owned by its existing fixture guardian.
    @inline(never)
    static func authenticatedFreshRestorationRefusal(_ bootstrap: InstallationBootstrap,
        root: String, location: StateLocation, adversary: FreshRestorationAdversary) throws {
        _ = try RuntimeFixtureSession.installationRoot(TestIsolation.validateRoot(root))
        guard bootstrap.candidateReadinessObservation() == .complete,
              bootstrap.readinessCommitObservation() == .notAttempted,
              bootstrap.normalStartupObservation() == .notAttempted else { throw CustodyRecordError.fenced }
        let application = root + "/home/Applications/ShadowSync.app"
        guard let journal = bootstrap.testingTerminalJournal() else { throw CustodyRecordError.fenced }
        let artifact = try journal.testingValidationProfile.inspectBundle(application)
        let records = artifact.inventory.map { $0.components(separatedBy: "\0") }
        guard let regular = records.first(where: { $0.count == 5 && $0[0] == "f" && $0[3] != "0" }),
              let session = bootstrap.testingReadinessSession(), let deadline = session.testingAnchoredDeadline else {
            throw CustodyRecordError.fenced
        }
        try authenticatedReadinessStoppedContinuation(bootstrap, root: root, location: location)
        let before = try stored(location, bootstrap: bootstrap)
        let target = application + "/" + regular[1]
        switch adversary {
        case .extraChild:
            let fd = open(application + "/fixture-unlisted", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            try H.check(fd >= 0, "fresh rollback extra-child creation")
            try H.check(OwnedFileDescriptor(fd).retireChecked() == .succeeded, "fresh rollback extra-child close")
        case .missingChild:
            try H.check(unlink(target) == 0, "fresh rollback missing-child cut")
        case .replacedChild:
            var before = stat(); try H.check(lstat(target,&before) == 0, "fresh rollback child identity")
            let bytes = try Data(contentsOf: URL(fileURLWithPath: target))
            try H.check(unlink(target) == 0, "fresh rollback child replacement cut")
            try bytes.write(to: URL(fileURLWithPath: target), options: .withoutOverwriting)
            try H.check(chmod(target,before.st_mode & 0o7777) == 0, "fresh rollback child replacement mode")
        case .changedContent:
            let raw = open(target,O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            try H.check(raw >= 0, "fresh rollback content cut open")
            let descriptor = OwnedFileDescriptor(raw)
            var byte: UInt8 = 0
            try H.check(pread(raw,&byte,1,0) == 1, "fresh rollback content preimage")
            byte ^= 1
            try H.check(pwrite(raw,&byte,1,0) == 1 && fsync(raw) == 0, "fresh rollback content cut")
            try H.check(descriptor.retireChecked() == .succeeded, "fresh rollback content close")
        case .changedMode:
            var info = stat(); try H.check(lstat(target,&info) == 0, "fresh rollback mode preimage")
            try H.check(chmod(target,(info.st_mode & 0o7777) ^ 0o100) == 0, "fresh rollback mode cut")
        case .changedXattr:
            var byte: UInt8 = 1
            try H.check(setxattr(target,"com.example.fixture-retirement",&byte,1,0,XATTR_NOFOLLOW) == 0,
                "fresh rollback xattr cut")
        case .changedSealedLink:
            guard let link = records.first(where: { $0.count == 5 && $0[0] == "l" }) else { throw CustodyRecordError.fenced }
            let path = application + "/" + link[1]
            try H.check(unlink(path) == 0 && symlink("../../fixture-escape",path) == 0, "fresh rollback sealed-leaf cut")
        case .replacedRoot:
            let held = root + "/home/Applications/fixture-held-app"
            try H.check(rename(application,held) == 0 && mkdir(application,0o755) == 0, "fresh rollback app substitution")
        case .replacedParent:
            let path = root + "/home/Applications", held = root + "/home/fixture-held-applications"
            try H.check(rename(path,held) == 0 && mkdir(path,0o755) == 0, "fresh rollback parent substitution")
        case .originalDeadline:
            while !deadline.hasExpired { Thread.sleep(forTimeInterval: min(0.001,Double(deadline.remainingMilliseconds) / 1_000)) }
        }
        try H.refuses { try bootstrap.restoreStoppedFreshInstallation() }
        let after = try stored(location, bootstrap: bootstrap)
        try H.check(after.phase == .recovery && after.readinessCommit == nil && after.state == before.state
            && after.transaction?.id == before.transaction?.id && after.recoveryReason != .restoredStopped
            && bootstrap.completionObservation() != .complete, "fresh restoration accepted substituted/expired authority")
        try InstallationOwnershipFixtures.excluded(location)
        try InstallationOwnershipFixtures.excluded(location, name: "lifecycle.lock")
        try H.refuses { try bootstrap.restoreStoppedFreshInstallation() }
        try H.refuses { try bootstrap.finishFreshInstallation() }
    }
    @inline(never)
    static func authenticatedFreshRestorationContention(_ bootstrap: InstallationBootstrap,
        root: String, location: StateLocation) throws {
        _ = try RuntimeFixtureSession.installationRoot(TestIsolation.validateRoot(root))
        guard bootstrap.candidateReadinessObservation() == .complete,
              bootstrap.readinessCommitObservation() == .notAttempted,
              bootstrap.normalStartupObservation() == .notAttempted else { throw CustodyRecordError.fenced }
        let raw = open(location.path + "/lifecycle.lock",O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try H.check(raw >= 0, "fresh restoration lifecycle contender")
        let contender = OwnedFileDescriptor(raw)
        do {
            try H.check(flock(raw,LOCK_SH | LOCK_NB) == 0, "fresh restoration lifecycle contention setup")
            try H.refuses { try bootstrap.stopReadinessOnlyHost() }
            try H.check(bootstrap.stoppedRecoveryObservation() == .pending,
                "fresh restoration reentry accepted contended lifecycle inode")
            try InstallationOwnershipFixtures.excluded(location)
            try H.refuses { try bootstrap.restoreStoppedFreshInstallation() }
            try H.check(contender.retireChecked() == .succeeded, "fresh restoration contender checked close")
        } catch {
            guard contender.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }; throw error
        }
    }
    /// Original signed driver prerequisites only. Ordinary enrolled invocation
    /// reaches refusal; actual authenticated positive remains separately qualified.
    enum ReadinessStopCut { case none, streamClosedBeforeStop }
    @inline(never)
    static func authenticatedReadinessStoppedContinuation(_ bootstrap: InstallationBootstrap,
        root: String, location: StateLocation, cut: ReadinessStopCut = .none) throws {
        _ = try RuntimeFixtureSession.installationRoot(TestIsolation.validateRoot(root))
        guard bootstrap.candidateReadinessObservation() == .complete,
              bootstrap.readinessCommitObservation() == .notAttempted,
              bootstrap.normalStartupObservation() == .notAttempted,
              bootstrap.stoppedRecoveryObservation() == .notAttempted else { throw CustodyRecordError.fenced }
        let before = try stored(location, bootstrap: bootstrap)
        guard before.phase == .active, before.readinessCommit == nil,
              before.step?.action == .candidateReady, before.step?.status == .complete else { throw CustodyRecordError.fenced }
        let quiet = try PolicyAuthorityFile.read(path: root + "/home/.staged-completion-quiet", owner: geteuid(), maximumBytes: 32)
        try H.check(quiet.bytes == Data("staged-completion-quiet/v1\n".utf8),
                    "signed readiness stop omitted actual command fixture contract")
        try InstallationOwnershipFixtures.excluded(location)
        if cut == .streamClosedBeforeStop {
            guard let session = bootstrap.testingReadinessSession(), let deadline = session.testingAnchoredDeadline else {
                throw CustodyRecordError.fenced
            }
            // Cut the actual original stream after signed readiness. Its joined
            // service and any resulting host exit still cannot supply an ack.
            try session.cancelAndJoin(deadline: deadline)
            try H.refuses { try bootstrap.stopReadinessOnlyHost() }
            try H.check(try bootstrap.stoppedRecoveryObservation() == .pending
                && bootstrap.stoppedDeliveryObservation() != .complete && stored(location, bootstrap: bootstrap) == before,
                "transport loss invented readiness drain or candidate-stop evidence")
            try InstallationOwnershipFixtures.excluded(location)
            try H.refuses { try bootstrap.stopReadinessOnlyHost() }
            return
        }
        try bootstrap.stopReadinessOnlyHost()
        let after = try stored(location, bootstrap: bootstrap)
        try H.check(bootstrap.stoppedRecoveryObservation() == .exclusive
            && bootstrap.stoppedDeliveryObservation() == .complete && after.phase == .recovery
            && after.readinessCommit == nil && after.state == before.state
            && after.transaction == before.transaction && after.step?.action == .candidateStop
            && after.step?.status == .complete && after.step?.ordinal == 16,
                    "readiness-only stop did not retain exact stopped recovery custody")
        try InstallationOwnershipFixtures.excluded(location)
        try InstallationOwnershipFixtures.excluded(location, name: "lifecycle.lock")
        try H.refuses { try bootstrap.stopReadinessOnlyHost() }
        try H.refuses { try bootstrap.commitCandidateReadiness() }
        try H.refuses { try bootstrap.stopNormallyStartedHost() }
        try H.refuses { try bootstrap.finishFreshInstallation() }
    }
    /// Missing original stages must not be counted as a reached signed fault.
    /// These are prerequisite refusals only; no authenticated positive is minted.
    @inline(never)
    static func bootstrapNativeHarnessPrerequisites() throws {
        for variant in 0..<3 {
            try exclusiveFixture { root, location, bootstrap, registry in
                let before = try H.snapshot(root)
                if variant == 0 {
                    try H.refuses {
                        try InstallationBootstrapCommitTransitionHarness.persistenceCut(.commitIntent,
                            failure: .receiptBeforeSwap, bootstrap: bootstrap, root: root,
                            location: location, prepare: {})
                    }
                } else {
                    do {
                        try InstallationBootstrapCommitTransitionHarness.returnedCommitFailure(
                            delivered: variant == 2, bootstrap: bootstrap, root: root,
                            location: location, prepare: {})
                        throw H.Failure(message: "native commit harness accepted an unreached transition")
                    } catch InstallationCandidateReadyTransitionHarness.Prerequisite.authenticatedTransitionNotReached {}
                }
                try H.check(!bootstrap.observation().attempted && !bootstrap.observation().failedClosed
                    && bootstrap.readinessCommitObservation() == .notAttempted
                    && bootstrap.testingCommitRetention() == [false, false, false, false],
                    "native commit prerequisite refusal consumed or fabricated authority")
                try H.check(try H.snapshot(root) == before && registry.testingCount == 0
                    && registry.testingOriginalHelpersReaped
                    && bootstrap.testingRetained() == Array(repeating: false, count: 6),
                    "native commit prerequisite refusal changed original disk or retained work")
                for path in [location.path + "/operation.lock", location.path + "/custody/installation.json"] {
                    var node = stat()
                    try H.check(lstat(path, &node) == -1 && errno == ENOENT,
                                "native commit prerequisite refusal created installation authority")
                }
            }
        }
    }
    static func commitBeforeReady() throws {
        try exclusiveFixture { root, location, bootstrap, _ in
            for phase in 0..<3 {
                if phase == 1 { try startPrepared(root, bootstrap) }
                if phase == 2 { try bootstrap.bootstrapCandidate(); try bootstrap.kickstartCandidate() }
                try H.refuses { try bootstrap.commitCandidateReadiness() }
                try H.refuses { try bootstrap.testingFenceCommitFailure() }
                try H.check(bootstrap.readinessCommitObservation() == .notAttempted
                    && bootstrap.commitFailureObservation() == .noCommitObserved
                    && bootstrap.testingCommitRetention() == [false, false, false, false]
                    && !bootstrap.observation().failedClosed,
                    "commit or recovery preclaim fabricated durable authority")
            }
            let before = try stored(location)
            try H.check(before.phase == .active && before.readinessCommit == nil,
                        "commit order fixture unexpectedly committed")
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    static func commitRecoveryMetadata() throws {
        // Value contract only. These synthetic records never enter Bootstrap,
        // mint an authenticated observation, or grant a journal writer.
        typealias C = InstallationControlFixtures
        var h = try C.Harness(); try h.throughReady(); try h.commitReady()
        let committed = h.record, receiptBytes = try h.receipts.map { try $0.encode(uid: h.state.directory.uid) }
        try h.recover(.startupUncertain)
        try H.check(h.record.phase == .recovery && h.record.readinessCommit == committed.readinessCommit
            && h.record.step == committed.step && h.record.latestReceiptDigest == committed.latestReceiptDigest
            && h.record.transaction == committed.transaction
            && (try h.receipts.map { try $0.encode(uid: h.state.directory.uid) }) == receiptBytes,
            "postcommit recovery changed durable convergence or receipt chain")
        let erased = InstallationControlRecord(revision: h.record.revision + 1, phase: .recovery,
            state: h.record.state, transaction: h.record.transaction, step: h.record.step,
            latestReceiptDigest: h.record.latestReceiptDigest, readinessCommit: nil, recoveryReason: .startupUncertain)
        try C.refuses { try h.record.validateReplacement(erased, receipts: h.receipts) }
        try C.refuses { try h.record.validateReplacement(committed, receipts: h.receipts) }
    }

}

/// Native-driver harness only. A caller must supply the actual authenticated
/// session and original fixture custody through prepare; an unreached real
/// publication is a missing prerequisite, never a passing negative case.
/// This harness creates no ReadyObservation, PID, command result or retirement.
enum InstallationBootstrapCommitTransitionHarness {
    typealias B = InstallationBootstrap
    typealias H = InstallationParentPreparationFixtures
    typealias J = CustodyCatalogStore.InstallationStagedJournal
    typealias Edge = InstallationCandidateReadyTransitionHarness.Transition
    private static func control(_ location: StateLocation) throws -> InstallationControlRecord {
        try InstallationControlRecord.decode(Data(contentsOf: URL(fileURLWithPath:
            location.path + "/custody/installation.json")))
    }
    private static func checkRoot(_ root: String, _ location: StateLocation) throws {
        try H.check(try StateLocation.isolated(root: TestIsolation.validateRoot(root)).path == location.path,
                    "bootstrap native harness root does not own state")
    }
    /// Existing nine exact persistence cuts at all four real ready/commit edges.
    /// prepare must finish the original bootstrap/kickstart and authenticated
    /// handshake; for commit edges it must also finish confirmCandidateReady.
    @inline(never)
    static func persistenceCut(_ edge: Edge, failure: J.TestingPublicationFailure,
        bootstrap: B, root: String, location: StateLocation, prepare: () throws -> Void) throws {
        try checkRoot(root, location)
        let probe = J.TestingPublicationProbe(action: edge.action, status: edge.status, failure: failure)
        if edge.action == .candidateReady { try bootstrap.testingConfigureCandidateReady(publicationProbe: probe) }
        else { try bootstrap.testingConfigureReadinessCommit(publicationProbe: probe) }
        try prepare()
        var refused = false
        do {
            if edge.action == .candidateReady { try bootstrap.confirmCandidateReady() }
            else { try bootstrap.commitCandidateReadiness() }
        } catch CustodyRecordError.injectedFailure { refused = true }
        catch CustodyRecordError.committedCleanupFailure { refused = true }
        // This is checked BEFORE interpreting any refusal as the selected cut.
        let trace = try InstallationCandidateReadyTransitionHarness.requireReached(probe)
        try H.check(refused && bootstrap.observation().failedClosed, "bootstrap actual cut did not fail closed")
        let swapped: Bool
        switch failure {
        case .controlAfterSwap, .controlAfterDirectorySync, .controlAfterPreimageUnlink: swapped = true
        default: swapped = false
        }
        let observed = try control(location)
        try H.check(observed == (swapped ? trace.after : trace.before), "bootstrap cut replaced actual durable outcome")
        let receiptPath = location.path + "/custody/receipts/" + (try trace.receipt.filename(uid: location.uid))
        if failure == .receiptBeforeSwap {
            var node = stat()
            try H.check(lstat(receiptPath, &node) == -1 && errno == ENOENT, "bootstrap pre-swap receipt exists")
        } else {
            try H.check(try Data(contentsOf: URL(fileURLWithPath: receiptPath)) == trace.receipt.encode(uid: location.uid),
                        "bootstrap cut lost exact pending receipt")
        }
        if edge == .commitComplete {
            try H.check(bootstrap.testingCommitRetention()[0]
                && bootstrap.commitFailureObservation() == .pending,
                "bootstrap uncertain commit cut lost proposal or invented repair")
            if swapped { try H.check(observed.readinessCommit == trace.after.readinessCommit,
                                     "bootstrap postcommit failure erased convergence") }
        }
        let frozen = try Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json"))
        try H.refuses { try bootstrap.confirmCandidateReady() }
        try H.refuses { try bootstrap.commitCandidateReadiness() }
        try H.check(try Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json")) == frozen,
                    "bootstrap failed publication replayed a capability")
        try InstallationOwnershipFixtures.excluded(location)
    }
    /// Deliberately fail AFTER the actual returned publication/delivery; the
    /// original deadline, operation owner, committed record and transport result
    /// remain observable. This does not assert normal host startup.
    @inline(never)
    static func returnedCommitFailure(delivered: Bool, bootstrap: B, root: String,
        location: StateLocation, prepare: () throws -> Void) throws {
        try checkRoot(root, location)
        var reached = false
        try bootstrap.testingConfigureReadinessCommit(checkpoint: { [weak bootstrap] point in
            guard point == (delivered ? .delivered : .published) else { return }
            guard let bootstrap else { throw H.Failure(message: "bootstrap returned outcome owner lost") }
            reached = true
            let held = bootstrap.testingCommitRetention()
            try H.check(held[0] && held[1] && held[3] == delivered,
                        "bootstrap returned outcome was not held before postflight")
            throw CustodyRecordError.injectedFailure
        })
        try prepare()
        try H.refuses { try bootstrap.commitCandidateReadiness() }
        guard reached else {
            throw InstallationCandidateReadyTransitionHarness.Prerequisite.authenticatedTransitionNotReached
        }
        let observed = try control(location), held = bootstrap.testingCommitRetention()
        try H.check(held[0] && held[1] && held[3] == delivered && observed.readinessCommit != nil
            && bootstrap.readinessCommitObservation() == .failed,
            "bootstrap failure lost actual commit/transport outcome")
        if bootstrap.commitFailureObservation() == .fenced {
            try H.check(observed.phase == .recovery && held[2], "bootstrap claimed recovery without durable fence")
        } else {
            try H.check(bootstrap.commitFailureObservation() == .pending,
                        "bootstrap postcommit failure permitted precommit rollback")
        }
        try H.refuses { try bootstrap.commitCandidateReadiness() }
        try InstallationOwnershipFixtures.excluded(location)
    }
}

// Actual driver coverage uses the same retained Bootstrap and fixture owners.
// Existing fixture cleanup remains distinct from production settlement.
extension InstallationBootstrapFixtures {
    static func driverGrammar() throws {
        for (arguments, expected): ([String], Int32) in [
            (["coordinator", "--install-fresh"], 78),
            (["coordinator", "--install-fresh", "--force"], 64),
            (["coordinator", "--install-fresh=/fixture.invalid"], 64),
            (["coordinator", "--install-fresh", "30"], 64)] {
            guard case let .exit(permit) = LifecycleCoordinatorMain.start(arguments: arguments) else {
                throw H.Failure(message: "testing production route retained an installer")
            }
            try H.check(permit.status == expected, "closed fresh grammar or testing refusal changed")
        }
        try H.refuses { _ = try CoordinatorInstallationAdmission.current() }
    }
    static func driverBeforeReserve() throws {
        for cancel in [false, true] {
            try fixture { root, _, bootstrap in
                let before = try H.snapshot(root)
                let attempt = FreshInstallationAttempt.testing(bootstrap: bootstrap,
                    deadline: .init(seconds: cancel ? 3 : 0))
                if cancel { attempt.requestCancellation() }
                guard case let .failedBeforeReserve(permit, cause) = attempt.runOnce() else {
                    throw H.Failure(message: "no-effect driver refusal retained or installed")
                }
                try H.check(permit.status == 1 && cause == (cancel ? .cancelled : .deadline)
                    && !bootstrap.observation().attempted && bootstrap.testingRetained().allSatisfy { !$0 }
                    && attempt.testingTrace.isEmpty && (try H.snapshot(root)) == before,
                    "pre-reserve refusal created an installation effect")
            }
        }
    }
    static func driverReserveCuts() throws {
        for (index, cut) in B.Stage.allCases.enumerated() {
            try fixture { root, location, bootstrap in
                try bootstrap.testingConfigure(cut: cut)
                let attempt = FreshInstallationAttempt.testing(bootstrap: bootstrap, deadline: .init(seconds: 3))
                let lifetime = CoordinatorInvocationLifetime(attempt: attempt)
                guard case let .retained(cause, phase) = attempt.runOnce() else {
                    throw H.Failure(message: "partial reserve minted an exit receipt")
                }
                try H.check(cause == .custody && phase == .reserve && attempt.firstFailure == cause,
                    "driver reserve cut lost original failure")
                let expected = [index >= 1, index >= 3, index >= 5, index >= 6, index >= 7, index >= 8]
                try H.check(lifetime.attempt.bootstrap === bootstrap && bootstrap.testingRetained() == expected,
                    "driver lifetime discarded partial original owners")
                if index >= 4 { try InstallationOwnershipFixtures.excluded(location) }
                let before = try H.snapshot(root), trace = attempt.testingTrace
                guard case .retained = attempt.runOnce() else { throw CustodyRecordError.fenced }
                attempt.observeRetirement()
                try H.check(try H.snapshot(root) == before && attempt.testingTrace == trace && attempt.firstFailure == cause,
                    "driver replay or notice changed failed reserve")
                withExtendedLifetime(lifetime) {}
            }
        }
    }
    static func driverPhaseCuts() throws {
        for cut: FreshInstallationAttempt.Phase in [.exclusive, .transfer, .journal, .readiness, .bootstrap, .kickstart, .ready] {
            try exclusiveFixture { root, location, bootstrap, _ in
                let attempt = FreshInstallationAttempt.testing(bootstrap: bootstrap, deadline: .init(seconds: 30))
                var reachedCut = false
                attempt.testingBeforePhase = { phase in
                    if phase == cut { reachedCut = true; throw InstallationFailure.policy }
                }
                guard case let .retained(cause, phase) = attempt.runOnce() else {
                    throw H.Failure(message: "driver phase cut invented settlement")
                }
                try H.check(reachedCut, "driver phase cut prerequisite failed before selected cut")
                try H.check(cause == .policy && phase == cut && attempt.firstFailure == .policy,
                    "driver phase cut lost primary classification")
                try InstallationOwnershipFixtures.excluded(location)
                // A cut after readiness owns a named UNIX socket, not an
                // openable file. Join the original service before observing its
                // retained named generation; no new cleanup budget or owner.
                let session = bootstrap.testingReadinessSession()
                let endpoint = bootstrap.testingReadinessEndpoint()
                let endpointImage = try endpoint?.image
                if cut == .bootstrap {
                    try H.check(bootstrap.stagedReadinessObservation() == .complete
                        && session != nil && endpointImage?.node?.type == .socket,
                        "driver phase cut missed original readiness publication")
                }
                try bootstrap.testingCloseReadiness(deadline: attempt.deadline)
                try H.check(bootstrap.testingReadinessSession() == nil,
                    "driver phase snapshot kept original service work")
                if let session { try H.check(!session.start(), "driver phase snapshot restarted joined service") }
                if let endpoint {
                    try endpoint.requireServiceClosed()
                    // The existing named-socket reader validates the actual ACL
                    // and original parents; readinessDisk retains ordinary ACLs.
                    try endpoint.revalidate(deadline: attempt.deadline)
                    try H.check(try endpoint.image == endpointImage,
                        "driver phase snapshot changed original socket generation")
                }
                let before = try readinessDisk(root), trace = attempt.testingTrace
                let socketPaths = before.filter { mode_t($0.value.identity.mode) & S_IFMT == S_IFSOCK }.map(\.key).sorted()
                try H.check(socketPaths == (endpoint == nil ? [] : [location.path + "/installation.sock"]),
                    "driver phase snapshot contains an unowned socket")
                if let node = endpointImage?.node, let socket = before[location.path + "/installation.sock"]?.identity {
                    try H.check(socket.device == node.device && socket.inode == node.inode
                        && socket.owner == node.uid && UInt32(socket.mode) == node.mode
                        && UInt64(socket.linkCount) == node.links,
                        "driver phase snapshot differs from original named socket")
                }
                guard case .retained = attempt.runOnce() else { throw CustodyRecordError.fenced }
                try H.check(try readinessDisk(root) == before && attempt.testingTrace == trace,
                    "driver phase cut replayed a completed lower-level effect")
                if let endpoint {
                    try endpoint.requireServiceClosed()
                    try endpoint.revalidate(deadline: attempt.deadline)
                    try H.check(try endpoint.image == endpointImage,
                        "driver phase replay changed original socket ACL or generation")
                }
            }
        }
    }
    static func driverCancellationAfterValidation() throws {
        try fixture { root, _, bootstrap in
            try bootstrap.testingConfigure(mutation: { [weak bootstrap] stage in
                if stage == .parentsRetained { bootstrap?.cancellationGate.request() }
            })
            let attempt = FreshInstallationAttempt.testing(bootstrap: bootstrap, deadline: .init(seconds: 3))
            guard case let .retained(cause, phase) = attempt.runOnce() else { throw CustodyRecordError.fenced }
            try H.check(cause == .cancelled && phase == .reserve && bootstrap.observation().stage == .parentsRetained
                && bootstrap.testingRetained() == [true, false, false, false, false, false]
                && !FileManager.default.fileExists(atPath: root + "/home/.local"),
                "cancellation during validation admitted parent preparation")
            attempt.requestCancellation(); attempt.requestCancellation()
            guard case .retained = attempt.runOnce() else { throw CustodyRecordError.fenced }
        }
    }
    static func driverPrimaryBeforeCleanupFailure() throws {
        try exclusiveFixture { _, location, bootstrap, _ in
            let original = MonotonicDeadline(seconds: 30)
            try bootstrap.testingConfigureStagedReadiness(afterReturn: {
                // Real forward failure, followed by real expired join validation.
                while !original.hasExpired { Thread.sleep(forTimeInterval: 0.001) }
                throw InstallationFailure.policy
            })
            let attempt = FreshInstallationAttempt.testing(bootstrap: bootstrap, deadline: original)
            guard case let .retained(cause, phase) = attempt.runOnce() else { throw CustodyRecordError.fenced }
            let failures = bootstrap.failureObservation()
            try H.check(cause == .policy && phase == .readiness && failures.primary == .policy
                && failures.settlement != nil && bootstrap.stagedReadinessClosureObservation() == .pending,
                "cleanup error replaced the original forward error")
            try InstallationOwnershipFixtures.excluded(location)
            attempt.observeRetirement()
            try H.check(attempt.firstFailure == .policy && attempt.phase == .failed,
                "late work became successful installation")
        }
    }
    private final class DriverNotices: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let received = DispatchSemaphore(value: 0)
        func record() { lock.lock(); count += 1; lock.unlock(); received.signal() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    static func driverActualRetirementNotices() throws {
        try exclusiveFixture { _, location, bootstrap, registry in
            let original = MonotonicDeadline(seconds: 1)
            let notices = DriverNotices(), queue = DispatchQueue(label: "shadow-sync.fixture.driver-notice")
            var subscriptions: [InstallationObservationSubscription] = []
            try bootstrap.testingConfigureStarts(checkpoint: { [weak bootstrap] operation, point in
                if operation == .bootstrap && point == .commandRetained { registry.testingDeferNextRead(.outputUntilReleased) }
                if operation == .bootstrap && point == .submitted {
                    guard let handle = bootstrap?.testingStartHandle(kickstart: false) else { throw CustodyRecordError.fenced }
                    subscriptions.append(handle.observeActualRetirement(on: queue) { notices.record() })
                }
            })
            let attempt = FreshInstallationAttempt.testing(bootstrap: bootstrap, deadline: original)
            guard case .retained = attempt.runOnce(), let handle = bootstrap.testingStartHandle(kickstart: false) else {
                throw H.Failure(message: "driver did not retain actual pending start")
            }
            defer { registry.testingReleaseDeferredRead(handle); subscriptions.forEach { $0.cancel() } }
            try H.check(original.hasExpired && notices.value == 0 && registry.hasRetainedWork,
                "pending result published actual retirement")
            try InstallationOwnershipFixtures.excluded(location)
            let before = try stored(location), failure = attempt.firstFailure
            registry.testingReleaseDeferredRead(handle)
            try H.check(notices.received.wait(timeout: .now() + 8) == .success && notices.value == 1,
                "actual registry publication did not notify once")
            subscriptions.append(handle.observeActualRetirement(on: queue) { notices.record() })
            try H.check(notices.received.wait(timeout: .now() + 1) == .success && notices.value == 2,
                "subscribe-after-publication lost retirement")
            attempt.observeRetirement()
            try H.check(try stored(location) == before && attempt.firstFailure == failure && attempt.phase == .failed
                && !registry.hasRetainedWork && registry.testingOriginalHelpersReaped,
                "late notice renewed budget or became successful installation")
        }
    }
    static func driverSessionWorkNotice() throws {
        try exclusiveFixture { _, location, bootstrap, _ in
            let notice = DriverNotices(), queue = DispatchQueue(label: "shadow-sync.fixture.session-notice")
            var subscription: InstallationObservationSubscription?
            try bootstrap.testingConfigureStagedReadiness(afterReturn: { [weak bootstrap] in
                guard let session = bootstrap?.testingReadinessSession() else { throw CustodyRecordError.fenced }
                subscription = session.observeWorkFinished(on: queue) { notice.record() }
                throw InstallationFailure.policy
            })
            defer { subscription?.cancel() }
            let attempt = FreshInstallationAttempt.testing(bootstrap: bootstrap, deadline: .init(seconds: 30))
            guard case .retained = attempt.runOnce() else { throw CustodyRecordError.fenced }
            try H.check(notice.received.wait(timeout: .now() + 1) == .success && notice.value == 1
                && bootstrap.testingReadinessEndpoint() != nil && bootstrap.completionObservation() == .notAttempted,
                "session work notice invented endpoint/transaction retirement")
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
}


extension InstallationBootstrapFixtures {
    static func driverEarlyEffectCuts() throws {
        for cut in 0..<6 {
            try fixture { root, location, bootstrap in
                switch cut {
                case 0: try bootstrap.testingConfigure(parentCut: .afterCreate(.local))
                case 1: try bootstrap.testingConfigure(initializationFault: .afterManifest)
                case 2: try bootstrap.testingConfigure(initializationFault: .afterReady)
                case 3: try bootstrap.testingConfigure(initializationFault: .afterPublication)
                case 4: try bootstrap.testingConfigure(journalCut: .afterReceipt)
                default: try bootstrap.testingConfigure(journalCut: .afterReceipt, cutCompletion: true)
                }
                let attempt = FreshInstallationAttempt.testing(bootstrap: bootstrap, deadline: .init(seconds: 3))
                guard case let .retained(_, phase) = attempt.runOnce() else { throw CustodyRecordError.fenced }
                try H.check(phase == .reserve && bootstrap.observation().attempted && attempt.firstFailure != nil,
                    "partial parent/publication/journal effect escaped retention")
                if cut >= 3 { try InstallationOwnershipFixtures.excluded(location) }
                let before = try H.snapshot(root), retained = bootstrap.testingRetained()
                guard case .retained = attempt.runOnce() else { throw CustodyRecordError.fenced }
                try H.check(try H.snapshot(root) == before && bootstrap.testingRetained() == retained,
                    "partial reserve replay changed original owners or durable preimages")
            }
        }
    }
    static func driverTransferCuts() throws {
        for cut: B.TransferCheckpoint in [.claimed, .intentRetained, .aliasesReleased, .borrowingClosed, .retired] {
            try exclusiveFixture { root, location, bootstrap, _ in
                var reached = false
                try bootstrap.testingConfigureStagedTransfer(checkpoint: { point in
                    if point == cut { reached = true; throw InstallationFailure.policy }
                })
                let attempt = FreshInstallationAttempt.testing(bootstrap: bootstrap, deadline: .init(seconds: 30))
                guard case let .retained(cause, phase) = attempt.runOnce() else { throw CustodyRecordError.fenced }
                try H.check(reached && cause == .policy && phase == .transfer && bootstrap.stagedObservation() == .failed,
                    "driver failed transfer cut was bypassed")
                try InstallationOwnershipFixtures.excluded(location)
                let before = try H.snapshot(root), retained = bootstrap.testingStagedRetention()
                attempt.observeRetirement()
                guard case .retained = attempt.runOnce() else { throw CustodyRecordError.fenced }
                try H.check(try H.snapshot(root) == before && bootstrap.testingStagedRetention() == retained,
                    "driver reconstructed transfer or released original operation")
            }
        }
    }
    static func driverStartCuts() throws {
        for operation: LifecycleLaunchCommand.Operation in [.bootstrap, .kickstart] {
            for cut: B.StartCheckpoint in [.claimed, .intentRetained, .contextRetained, .commandRetained,
                                          .submitted, .retirementReceived, .aliasesReleased, .retired, .completed] {
                try exclusiveFixture { root, location, bootstrap, _ in
                    // The driver owns phase progression; prepare only the
                    // existing helper telemetry contract before its reserve.
                    try prepareStartCommandFixture(root)
                    var reached = false
                    try bootstrap.testingConfigureStarts(checkpoint: { actual, point in
                        if actual == operation && point == cut { reached = true; throw InstallationFailure.policy }
                    })
                    let attempt = FreshInstallationAttempt.testing(bootstrap: bootstrap, deadline: .init(seconds: 30))
                    guard case let .retained(cause, phase) = attempt.runOnce() else { throw CustodyRecordError.fenced }
                    try H.check(reached && cause == .policy && phase == (operation == .bootstrap ? .bootstrap : .kickstart)
                        && bootstrap.observation().failedClosed && attempt.firstFailure == .policy,
                        "driver uncertain start cut lost original failure or minted settlement")
                    try InstallationOwnershipFixtures.excluded(location)
                    let before = try stored(location), trace = attempt.testingTrace
                    attempt.observeRetirement()
                    guard case .retained = attempt.runOnce() else { throw CustodyRecordError.fenced }
                    try H.check(try stored(location) == before && attempt.testingTrace == trace,
                        "driver retirement replayed interrupted start")
                }
            }
        }
    }
}

// Observe cancellation during the real fallible diagnostic preparation. This
// helper retains only the original latch, never a command or owner capability.
extension InstallationBootstrapFixtures {
    private final class DiagnosticCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var gate: InstallationCancellationGate?
        private var events: [String] = []
        func bind(_ gate: InstallationCancellationGate) { lock.lock(); self.gate = gate; lock.unlock() }
        func visit(_ event: String) {
            lock.lock(); events.append(event); let gate = self.gate; lock.unlock()
            if event == "exclusive-diagnostic-prepared" { gate?.request() }
        }
        var observed: [String] { lock.lock(); defer { lock.unlock() }; return events }
    }
    static func driverExclusiveDiagnosticCancellation() throws {
        let cut = DiagnosticCancellation()
        try exclusiveFixture(fault: { cut.visit($0) }) { root, location, bootstrap, registry in
            cut.bind(bootstrap.cancellationGate)
            let original = MonotonicDeadline(seconds: 30)
            let attempt = FreshInstallationAttempt.testing(bootstrap: bootstrap, deadline: original)
            guard case let .retained(cause, phase) = attempt.runOnce() else { throw CustodyRecordError.fenced }
            let control = try stored(location)
            try H.check(cut.observed.contains("exclusive-diagnostic-prepared") && cause == .cancelled
                && phase == .exclusive && attempt.firstFailure == .cancelled && !original.hasExpired
                && registry.testingPreparedStartCount == 0 && registry.testingCount == 0 && !registry.hasRetainedWork
                && registry.testingOriginalHelpersReaped, "cancelled preparation submitted a diagnostic")
            try H.check(!cut.observed.contains(where: { $0.hasPrefix("exclusive-after-action-") })
                && control.step?.action == .drainPrior && control.step?.status == .intent
                && control.transaction?.slots.images[.applicationIncoming]?.node == nil
                && control.transaction?.slots.images[.plistIncoming]?.node == nil
                && bootstrap.exclusiveObservation() == .failed && bootstrap.stagedObservation() == .notAttempted
                && attempt.testingTrace == [.reserve, .exclusive], "cancelled diagnostic admitted later preparation")
            try InstallationOwnershipFixtures.excluded(location)
            try InstallationOwnershipFixtures.excluded(location, name: "lifecycle.lock")
            let retained = bootstrap.testingRetained(), disk = try H.snapshot(root)
            attempt.observeRetirement()
            guard case let .retained(late, latePhase) = attempt.runOnce() else { throw CustodyRecordError.fenced }
            try H.check(late == cause && latePhase == phase && bootstrap.testingRetained() == retained
                && registry.testingPreparedStartCount == 0 && (try H.snapshot(root)) == disk,
                "cancelled diagnostic replayed or discarded original owners")
        }
    }
}

#endif
