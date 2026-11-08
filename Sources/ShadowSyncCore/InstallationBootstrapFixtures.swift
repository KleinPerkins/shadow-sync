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

}
#endif
