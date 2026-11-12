#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

enum InstallationStagedJournalFixtures {
    typealias H = InstallationStorageFixtures
    typealias J = CustodyCatalogStore.InstallationStagedJournal
    // Only orderAndOwners opts in. Closed values, at most 96 lines per case,
    // no fixture paths or error text, and no operation/deadline changes.
    private enum OrderPart: String { case bootstrap, kickstart, stale, owner, otherOwner }
    private enum OrderPhase: String {
        case fixtureEntry, preparedIntent, retired, transferred, continued
        case bodyComplete, exclusionComplete, cleanupComplete
        case readBefore, readAfter, bootstrapBefore, bootstrapRefused
        case completeBefore, completeAfter, kickstartBefore, kickstartRefused
        case continueBefore, continueRefused, leasesBefore, leasesRefused
        case wrongOwnerBefore, wrongOwnerRefused, closeBefore, closeAfter
        case stopBefore, stopAfter, wrongStopBefore, wrongStopRefused
        case revalidateBefore, revalidateAfter, otherRevalidateAfter, otherExcluded
    }
    private final class OrderDiagnostic {
        private let enabled = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_M6_DIAGNOSTICS"] == "1"
        private var records = 0
        func record(_ part: OrderPart, _ phase: OrderPhase) {
            guard enabled, records < 96 else { return }
            records += 1
            fputs("M6 STAGED ORDER DIAGNOSTIC part=\(part.rawValue) phase=\(phase.rawValue)\n", stderr)
            fflush(stderr)
        }
    }
    static func fixture(bindingSource: ((InstallationBindingTestingSource) -> Void)? = nil,
        _ body: (String, StateLocation, InstallationTransactionOwner,
        CustodyCatalogStore.InstallationStagedAdmissionIntent, InstallationStagedAdmission,
        J, RetainedCleanupRegistry) throws -> Void) throws {
        try diagnosticFixture(bindingSource: bindingSource, body)
    }
    private static func diagnosticFixture(diagnostic: ((OrderPhase) -> Void)? = nil, bindingSource: ((InstallationBindingTestingSource) -> Void)? = nil,
        _ body: (String, StateLocation, InstallationTransactionOwner,
        CustodyCatalogStore.InstallationStagedAdmissionIntent, InstallationStagedAdmission,
        J, RetainedCleanupRegistry) throws -> Void) throws {
        diagnostic?(.fixtureEntry)
        try InstallationExclusivePreparationFixtures.withPreparedIntent(bindingSource: bindingSource) { root, location, owner, intent, registry in
            diagnostic?(.preparedIntent)
            let retired = try registry.installationRetirement(after: owner.closeBorrowing())
            diagnostic?(.retired)
            let admission = try owner.transferToStagedAdmission(intent: intent, after: retired, deadline: .init(seconds: 3))
            diagnostic?(.transferred)
            let journal = try admission.continueJournal(deadline: .init(seconds: 3))
            diagnostic?(.continued)
            try RuntimeFixtureSession.installationRoot(root).retain(journal)
            do { try body(root, location, owner, intent, admission, journal, registry) }
            catch {
                try journal.closeReadiness(deadline: .init(seconds: 3))
                throw error
            }
            try journal.closeReadiness(deadline: .init(seconds: 3))
            diagnostic?(.bodyComplete)
            try InstallationOwnershipFixtures.excluded(location)
            diagnostic?(.exclusionComplete)
        }
        diagnostic?(.cleanupComplete)
    }
    private static func record(_ location: StateLocation) throws -> InstallationControlRecord {
        try InstallationControlRecord.decode(Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json")))
    }
    static func continuation() throws {
        try fixture { _, location, owner, intent, admission, journal, registry in
            try H.refuses { _ = try admission.continueJournal(deadline: .init(seconds: 3)) }
            let before = try record(location)
            let completed = try journal.completeAdmission(deadline: .init(seconds: 3))
            try H.check(completed.revision == before.revision + 1 && completed.step?.ordinal == 12
                && completed.step?.action == .openStagedAdmission && completed.step?.status == .complete,
                "staged continuation did not complete exact transferred intent")
            try H.check(completed.transaction?.sameBinding(as: before.transaction!) == true && completed.state == before.state
                && completed.transaction?.slots.images[.installationSocket]?.node?.type == .socket
                && before.transaction?.slots.images[.installationSocket]?.node == nil
                && completed.readinessCommit == nil && completed.phase == .active, "staged continuation socket binding")
            try H.check(completed.transaction?.slots.images[.stateDestination]
                == before.transaction?.slots.images[.stateDestination],
                "owned socket creation changed stable namespace/preimage binding")
            try H.check(try record(location) == completed, "staged completion not durable")
            try H.refuses { try intent.revalidate(for: owner, deadline: .init(seconds: 3)) }
            try H.refuses { _ = try owner.retainExclusiveLeases() }
            try H.refuses { _ = try owner.installationCommandHelper() }
            let observation = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
            let binding = try InstallationCommandBinding.decode(observation.sealedInput(deadline: .init(seconds: 3)))
            try H.check(binding.control.step?.action == .bootstrapCandidate && binding.control.step?.status == .intent
                && binding.control.step?.ordinal == 13 && binding.receiptNodes.count > 11, "staged intent did not bind full receipt set")
            try binding.validateStagedOperation(mode: .installationStagedStart, operation: .bootstrap)
            try H.refuses { try binding.validateStagedOperation(mode: .installationStagedStart, operation: .kickstart) }
            try H.refuses { try binding.validateStagedOperation(mode: .installationStagedStop, operation: .bootout) }
            // The journal retains no admission duplicate between calls.
            let retired = try registry.installationStagedStartRetirement(after: admission.closeStarts())
            let stop = try admission.stopOnly(after: retired)
            try stop.revalidate()
            try H.refuses { try observation.revalidate(deadline: .init(seconds: 3)) }
            try H.check(try record(location) == binding.control, "observation closure completed command")
        }
    }
    static func orderAndOwners() throws {
        let diagnostic = OrderDiagnostic()
        func read(_ location: StateLocation, _ part: OrderPart) throws -> InstallationControlRecord {
            diagnostic.record(part, .readBefore)
            let value = try record(location)
            diagnostic.record(part, .readAfter)
            return value
        }
        try diagnosticFixture(diagnostic: { diagnostic.record(.bootstrap, $0) }) { _, location, _, _, admission, journal, _ in
            let before = try read(location, .bootstrap)
            diagnostic.record(.bootstrap, .bootstrapBefore)
            try H.refuses { _ = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3)) }
            diagnostic.record(.bootstrap, .bootstrapRefused)
            try H.check(try read(location, .bootstrap) == before, "bootstrap before open completion wrote control")
            diagnostic.record(.bootstrap, .leasesBefore)
            try H.refuses { _ = try admission.retainStartLeases() }
            diagnostic.record(.bootstrap, .leasesRefused)
        }
        try diagnosticFixture(diagnostic: { diagnostic.record(.kickstart, $0) }) { _, location, _, _, admission, journal, _ in
            diagnostic.record(.kickstart, .completeBefore)
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            diagnostic.record(.kickstart, .completeAfter)
            let before = try read(location, .kickstart)
            diagnostic.record(.kickstart, .kickstartBefore)
            try H.refuses { _ = try journal.kickstartCandidateIntent(deadline: .init(seconds: 3)) }
            diagnostic.record(.kickstart, .kickstartRefused)
            try H.check(try read(location, .kickstart) == before, "kickstart skipped typed bootstrap completion")
            diagnostic.record(.kickstart, .leasesBefore)
            try H.refuses { _ = try admission.retainStartLeases() }
            diagnostic.record(.kickstart, .leasesRefused)
        }
        try diagnosticFixture(diagnostic: { diagnostic.record(.stale, $0) }) { _, location, _, _, admission, journal, _ in
            diagnostic.record(.stale, .completeBefore)
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            diagnostic.record(.stale, .completeAfter)
            let before = try read(location, .stale)
            diagnostic.record(.stale, .continueBefore)
            try H.refuses { _ = try admission.continueJournal(deadline: .init(seconds: 3)) }
            diagnostic.record(.stale, .continueRefused)
            try H.check(try read(location, .stale) == before, "stale intent changed durable control")
            diagnostic.record(.stale, .leasesBefore)
            try H.refuses { _ = try admission.retainStartLeases() }
            diagnostic.record(.stale, .leasesRefused)
        }
        try diagnosticFixture(diagnostic: { diagnostic.record(.owner, $0) }) { _, location, owner, intent, _, journal, _ in
            try diagnosticFixture(diagnostic: { diagnostic.record(.otherOwner, $0) }) { _, otherLocation, other, _, otherAdmission, _, otherRegistry in
                diagnostic.record(.otherOwner, .wrongOwnerBefore)
                try H.refuses { _ = try intent.continueJournal(admission: otherAdmission, deadline: .init(seconds: 3)) }
                diagnostic.record(.otherOwner, .wrongOwnerRefused)
                diagnostic.record(.otherOwner, .closeBefore)
                let otherRetirement = try otherRegistry.installationStagedStartRetirement(after: otherAdmission.closeStarts())
                diagnostic.record(.otherOwner, .closeAfter)
                diagnostic.record(.otherOwner, .stopBefore)
                let otherStop = try otherAdmission.stopOnly(after: otherRetirement)
                diagnostic.record(.otherOwner, .stopAfter)
                diagnostic.record(.owner, .completeBefore)
                _ = try journal.completeAdmission(deadline: .init(seconds: 3))
                diagnostic.record(.owner, .completeAfter)
                let before = try read(location, .owner)
                diagnostic.record(.owner, .wrongStopBefore)
                try H.refuses { _ = try journal.candidateStopIntent(admission: otherStop, deadline: .init(seconds: 3)) }
                diagnostic.record(.owner, .wrongStopRefused)
                try H.check(try read(location, .owner) == before, "wrong stop owner changed control")
                diagnostic.record(.owner, .revalidateBefore)
                try owner.revalidate()
                diagnostic.record(.owner, .revalidateAfter)
                try other.revalidate()
                diagnostic.record(.otherOwner, .otherRevalidateAfter)
                try InstallationOwnershipFixtures.excluded(otherLocation)
                diagnostic.record(.otherOwner, .otherExcluded)
            }
        }
    }
    static func stopIntent() throws {
        try fixture { _, location, owner, _, admission, journal, registry in
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            let retirement = try registry.installationStagedStartRetirement(after: admission.closeStarts())
            let stop = try admission.stopOnly(after: retirement)
            let observation = try journal.candidateStopIntent(admission: stop, deadline: .init(seconds: 3))
            let binding = try InstallationCommandBinding.decode(observation.sealedInput(deadline: .init(seconds: 3)))
            try H.check(binding.control.phase == .recovery && binding.control.step?.action == .candidateStop
                && binding.control.step?.status == .intent && binding.control.readinessCommit == nil,
                "stop intent invented candidate exit or readiness")
            try H.check(try record(location) == binding.control, "stop intent not durable")
            try binding.validateStagedOperation(mode: .installationStagedStop, operation: .bootout)
            try H.refuses { try binding.validateStagedOperation(mode: .installationStagedStart, operation: .bootstrap) }
            try H.refuses { _ = try journal.candidateStopIntent(admission: stop, deadline: .init(seconds: 3)) }
            try H.refuses { _ = try owner.retainExclusiveLeases() }
            try H.refuses { _ = try CustodyMetadataScope(leases: stop.retainStopLeases(),
                releaseSHA256: String(repeating: "a", count: 64), generation: RunIdentity.make()) }
        }
    }
    static func bindingRefusals() throws {
        try fixture { _, _, _, _, _, journal, _ in
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            let observation = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
            let binding = observation.binding
            for name in binding.receiptNodes.keys {
                var nodes = binding.receiptNodes; nodes.removeValue(forKey: name)
                try H.refuses { try InstallationCommandBinding(control: binding.control,
                    controlNode: binding.controlNode, receiptNodes: nodes).validate() }
            }
            var nodes = binding.receiptNodes
            let original = nodes.first { $0.key.hasPrefix(InstallationStepReceipt.prefix) }!
            nodes.removeValue(forKey: original.key)
            nodes[InstallationStepReceipt.prefix + RunIdentity.make() + "-1-intent-" + String(repeating: "f", count: 64) + ".json"] = original.value
            try H.refuses { try InstallationCommandBinding(control: binding.control,
                controlNode: binding.controlNode, receiptNodes: nodes).validate() }
            let wrong = ProcessIdentity(processID: getpid(), processGroupID: getpgrp(), userID: geteuid(),
                startSeconds: 1, startMicroseconds: 1, executablePath: "/fixture", generation: RunIdentity.make())
            try H.refuses { try binding.validateParent(wrong, helper: CustodyHelperExecutable.testingCustodian()) }
            try H.refuses { _ = try journal.kickstartCandidateIntent(deadline: .init(seconds: 3)) }
            try H.refuses { try observation.revalidate(deadline: .init(seconds: 3)) }
        }
    }
    private static func substitute(_ path: String, retained: String, append: Data = Data()) throws {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path)) + append
        try H.check(rename(path, retained) == 0, "staged fixture retain replaced evidence")
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try H.check(fd >= 0, "staged fixture replacement create"); defer { close(fd) }
        try bytes.withUnsafeBytes { p in
            try H.check(Darwin.write(fd, p.baseAddress, p.count) == p.count, "staged fixture replacement write")
        }
        try H.check(fsync(fd) == 0, "staged fixture replacement sync")
    }
    private static func labeled(_ label: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch { throw H.Failure(message: label + ": " + String(describing: error)) }
    }
    private static func refusal(_ label: String, _ body: () throws -> Void) throws {
        try labeled(label) { try H.refuses(body) }
    }
    private static func node(_ path: String) throws -> FileIdentity {
        var value = stat()
        try H.check(lstat(path, &value) == 0, "staged substitution node capture")
        return FileIdentity(value)
    }
    static func substitutionRefusals() throws {
        // Bundle slots pin the root node and canonical content inventory, not
        // every descendant inode. Prove that an identical inner replacement
        // retains that contract before testing actual root/content drift.
        try fixture { root, location, _, _, admission, journal, _ in
            let label = "candidate-identical-inner"
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            let observation = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
            let bundle = root + "/home/Applications/ShadowSync.app"
            let info = bundle + "/Contents/Info.plist"
            let oldRoot = try node(bundle), oldInfo = try node(info)
            let oldArtifact = try BundleArtifactIdentity.inspect(bundlePath: bundle, requireProduction: true)
            let evidence = try persistenceSnapshot(location)
            try substitute(info, retained: root + "/retained-staged-evidence")
            try H.check(try node(bundle) == oldRoot && node(info) != oldInfo,
                label + ": replacement did not preserve root and replace inner node")
            try H.check(try BundleArtifactIdentity.inspect(bundlePath: bundle, requireProduction: true) == oldArtifact,
                label + ": canonical bundle identity changed")
            try labeled(label + "/observation.revalidate") { try observation.revalidate(deadline: .init(seconds: 3)) }
            try labeled(label + "/retainStartLeases") { _ = try admission.retainStartLeases() }
            try H.check(try persistenceSnapshot(location) == evidence, label + ": observation changed metadata")
            try H.check(try record(location).step?.status == .intent, label + ": observation fabricated completion")
            try InstallationOwnershipFixtures.excluded(location)
        }
        for target in ["control", "receipt", "candidate-root", "candidate-content", "source-binding-content"] {
            var source: InstallationBindingTestingSource?
            try fixture(bindingSource: { source = $0 }) { root, location, _, _, admission, journal, _ in
                try labeled(target) {
                    _ = try journal.completeAdmission(deadline: .init(seconds: 3))
                    let observation = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
                    let originalSourceIdentity = source?.identity
                    let retained = root + "/retained-staged-evidence"
                    if target == "control" {
                        try substitute(location.path + "/custody/installation.json", retained: retained)
                    } else if target == "receipt" {
                        try substitute(location.path + "/custody/receipts/" + observation.binding.receiptNodes.keys.sorted().first!,
                            retained: retained)
                    } else if target == "candidate-root" {
                        let bundle = root + "/home/Applications/ShadowSync.app"
                        let before = try node(bundle)
                        let artifact = try BundleArtifactIdentity.inspect(bundlePath: bundle, requireProduction: true)
                        try H.check(rename(bundle, retained) == 0, "retain original candidate root")
                        try FileManager.default.copyItem(atPath: retained, toPath: bundle)
                        try H.check(try node(bundle) != before, "candidate root identity did not change")
                        try H.check(try BundleArtifactIdentity.inspect(bundlePath: bundle, requireProduction: true) == artifact,
                            "candidate root replacement changed canonical content")
                    } else {
                        let bundle = target == "candidate-content" ? root + "/home/Applications/ShadowSync.app"
                            : root + "/candidate/ShadowSync.app"
                        let before = try node(bundle)
                        let artifact = try BundleArtifactIdentity.inspect(bundlePath: bundle, requireProduction: true)
                        try substitute(bundle + "/Contents/Info.plist", retained: retained, append: Data("\n".utf8))
                        let changed = try BundleArtifactIdentity.inspect(bundlePath: bundle, requireProduction: true)
                        try H.check(try node(bundle) == before && changed.release == artifact.release
                            && changed.canonicalSHA256 != artifact.canonicalSHA256, "bundle content drift not isolated")
                        if target == "source-binding-content" {
                            // Fixture owners deliberately use a synthetic source,
                            // not LifecyclePublisher's signed resource reader.
                            // Feed actual changed content through that existing
                            // seam; this is no production publisher qualification.
                            guard let source else { throw H.Failure(message: "missing synthetic source") }
                            let prior = source.identity.candidate
                            source.identity = try LifecyclePublisher.InstallationIdentity.testing(root: root,
                                candidate: InstallationCandidate(release: changed.release, bundleDigest: changed.canonicalSHA256,
                                    appCDHash: prior.appCDHash, coordinatorCDHash: prior.coordinatorCDHash))
                        }
                    }
                    let evidence = try persistenceSnapshot(location)
                    try refusal(target + "/observation.revalidate") { try observation.revalidate(deadline: .init(seconds: 3)) }
                    try refusal(target + "/retainStartLeases") { _ = try admission.retainStartLeases() }
                    if target == "source-binding-content" {
                        guard let source, let originalSourceIdentity else { throw H.Failure(message: "missing original synthetic source") }
                        // Remove the synthetic fault after the refusal to prove
                        // the same journal/owner remains permanently closed.
                        source.identity = originalSourceIdentity
                        try refusal(target + "/restored-binding/observation.revalidate") {
                            try observation.revalidate(deadline: .init(seconds: 3))
                        }
                        try refusal(target + "/restored-binding/retainStartLeases") { _ = try admission.retainStartLeases() }
                    }
                    try H.check(try persistenceSnapshot(location) == evidence, "refusal changed metadata evidence")
                    try H.check(try record(location).step?.status == .intent, "substitution fabricated completion")
                    try InstallationOwnershipFixtures.excluded(location)
                }
            }
        }
    }
    // Snapshot the complete transaction-owned metadata namespace, including
    // preserved atomic-swap preimages. Atime is excluded because reads may change
    // it; mtime/ctime, bytes and identity catch rewrites or identical replacement.
    private struct PersistenceFile: Equatable {
        let identity: FileIdentity
        let bytes: Data
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }
    private struct PersistenceSnapshot: Equatable {
        let directories: [String: FileIdentity]
        let files: [String: PersistenceFile]
    }
    private static func persistenceSnapshot(_ location: StateLocation) throws -> PersistenceSnapshot {
        let root = location.path + "/custody"
        var directories: [String: FileIdentity] = [:], files: [String: PersistenceFile] = [:]
        for relative in ["", "receipts"] {
            let directory = root + (relative.isEmpty ? "" : "/" + relative)
            var state = stat()
            try H.check(lstat(directory, &state) == 0 && state.st_mode == (S_IFDIR | 0o700)
                && state.st_uid == location.uid, "persistence fixture directory changed")
            directories[relative] = FileIdentity(state)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory)
            for name in names {
                if relative.isEmpty && name == "receipts" { continue }
                let key = relative.isEmpty ? name : relative + "/" + name, path = directory + "/" + name
                var before = stat(), after = stat()
                try H.check(lstat(path, &before) == 0 && before.st_mode == (S_IFREG | 0o600)
                    && before.st_uid == location.uid && before.st_nlink == 1,
                    "persistence fixture contains unsafe file")
                let bytes: Data
                if before.st_size == 0 { bytes = Data() } // the retained catalog lock is empty
                else {
                    bytes = try PolicyAuthorityFile.read(path: path, owner: location.uid,
                        maximumBytes: 1_048_576).bytes
                }
                try H.check(lstat(path, &after) == 0 && FileIdentity(before) == FileIdentity(after)
                    && before.st_size == after.st_size && bytes.count == before.st_size
                    && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
                    && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
                    && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
                    && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                    "persistence fixture changed while observed")
                files[key] = PersistenceFile(identity: FileIdentity(after), bytes: bytes,
                    modifiedSeconds: after.st_mtimespec.tv_sec, modifiedNanoseconds: after.st_mtimespec.tv_nsec,
                    changedSeconds: after.st_ctimespec.tv_sec, changedNanoseconds: after.st_ctimespec.tv_nsec)
            }
        }
        return PersistenceSnapshot(directories: directories, files: files)
    }
    private static func expectedAdmissionCompletion(_ before: InstallationControlRecord)
        throws -> (InstallationStepReceipt.CanonicalObservation, InstallationControlRecord) {
        guard let transaction = before.transaction, before.step?.action == .openStagedAdmission,
              before.step?.status == .intent, before.step?.ordinal == 12 else {
            throw H.Failure(message: "persistence fixture has wrong admission intent")
        }
        let receipt = InstallationStepReceipt(transactionID: transaction.id, ordinal: 12,
            previousReceiptDigest: before.latestReceiptDigest, action: .openStagedAdmission, status: .complete,
            preimage: transaction.slots, postimage: transaction.slots,
            bindingDigest: try transaction.bindingDigest(state: before.state))
        let canonical = try InstallationStepReceipt.CanonicalObservation(validating: receipt, uid: before.state.directory.uid)
        let control = InstallationControlRecord(revision: before.revision + 1, phase: .active,
            state: before.state, transaction: transaction, step: try receipt.step(), latestReceiptDigest: canonical.digest,
            readinessCommit: nil, recoveryReason: nil)
        return (canonical, control)
    }
    private static func assertPersistenceState(_ location: StateLocation, before: PersistenceSnapshot,
        expectedControl: InstallationControlRecord, controlPublished: Bool,
        receipt: InstallationStepReceipt.CanonicalObservation?, retainedPreimage: Bool) throws -> PersistenceSnapshot {
        let after = try persistenceSnapshot(location)
        let controlName = InstallationControlRecord.filename
        guard let old = before.files[controlName], let current = after.files[controlName] else {
            throw H.Failure(message: "persistence cut lost control")
        }
        try H.check(Set(after.directories.keys) == Set(before.directories.keys),
                    "persistence cut changed metadata directory set")
        for (name, prior) in before.directories {
            guard let current = after.directories[name] else {
                throw H.Failure(message: "persistence cut lost metadata directory")
            }
            // Publishing a receipt or retained control preimage changes the
            // directory link count on supported filesystems. Preserve the same
            // stable node and protection fields; exact children are checked below.
            try H.check(current.matchesStableNode(prior) && current.linkCount > 0,
                        "persistence cut changed stable metadata directory identity")
        }
        try H.check(current.bytes == expectedControl.encode(), "persistence cut has unexpected control bytes")
        try H.check(try record(location) == expectedControl, "persistence cut has unexpected typed control")
        if controlPublished {
            try H.check(!current.identity.matchesStableNode(old.identity), "control swap retained old control inode")
        } else { try H.check(current == old, "pre-swap cut changed old control") }
        for (name, file) in before.files where name != controlName {
            try H.check(after.files[name] == file, "persistence cut changed an existing evidence file")
        }
        var expectedNames = Set(before.files.keys)
        if let receipt {
            let key = "receipts/" + receipt.filename
            expectedNames.insert(key)
            guard let file = after.files[key] else { throw H.Failure(message: "persistence cut lost canonical receipt") }
            try H.check(file.bytes == receipt.receipt.encode(uid: receipt.uid), "persistence cut altered canonical receipt")
            try H.check(try InstallationStepReceipt.decode(file.bytes, uid: receipt.uid) == receipt.receipt,
                        "persistence cut receipt prior digest or binding changed")
        }
        let residual = Set(after.files.keys).subtracting(expectedNames)
        try H.check(residual.count == (retainedPreimage ? 1 : 0), "persistence cut has unexpected residual files")
        if retainedPreimage {
            guard let name = residual.first, let file = after.files[name] else { throw H.Failure(message: "lost control preimage") }
            try H.check(name.hasPrefix(".custody-pending-") && !name.contains("/")
                && RunIdentity.isValid(String(name.dropFirst(".custody-pending-".count))),
                "persistence cut has unknown residual name")
            // Renaming changes ctime. The retained OLD inode and exact bytes,
            // rather than the pre-rename timestamp, identify the control preimage.
            try H.check(file.identity == old.identity && file.bytes == old.bytes,
                        "persistence cut did not preserve exact old control preimage")
            expectedNames.insert(name)
        }
        try H.check(Set(after.files.keys) == expectedNames, "persistence cut lost expected evidence")
        return after
    }
    private static func assertStickyPersistence(_ location: StateLocation, admission: InstallationStagedAdmission,
        journal: J, expected: PersistenceSnapshot, pending: Bool,
        stop: InstallationStagedStopAdmission? = nil) throws {
        try H.check(journal.testingHasPending == pending, "persistence cut has wrong pending state")
        try InstallationOwnershipFixtures.excluded(location)
        func refusesWithoutChange(_ action: () throws -> Void) throws {
            try H.refuses(action)
            try H.check(journal.testingHasPending == pending, "replay changed retained pending state")
            try H.check(try persistenceSnapshot(location) == expected, "replay rewrote or deleted preserved evidence")
            try InstallationOwnershipFixtures.excluded(location)
        }
        try refusesWithoutChange { _ = try admission.retainStartLeases() }
        try refusesWithoutChange { _ = try admission.continueJournal(deadline: .init(seconds: 3)) }
        try refusesWithoutChange { _ = try journal.completeAdmission(deadline: .init(seconds: 3)) }
        try refusesWithoutChange { _ = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3)) }
        try refusesWithoutChange { _ = try journal.kickstartCandidateIntent(deadline: .init(seconds: 3)) }
        if let stop {
            try refusesWithoutChange { _ = try journal.candidateStopIntent(admission: stop, deadline: .init(seconds: 3)) }
        }
        // Repeated calls still fail after every one-shot injected fault has
        // been consumed. Neither a visible completed control nor nil pending
        // in the preliminary recovery write reopens the failed continuation.
        try refusesWithoutChange { _ = try journal.completeAdmission(deadline: .init(seconds: 3)) }
        try refusesWithoutChange { _ = try admission.retainStartLeases() }
    }
    static func persistenceCuts() throws {
        for cut: J.Cut in [.afterReceipt, .beforeControl] {
            try fixture { _, location, _, _, admission, journal, _ in
                let before = try persistenceSnapshot(location), control = try record(location)
                let expected = try expectedAdmissionCompletion(control)
                try InstallationOwnershipFixtures.excluded(location)
                journal.testingCut(cut)
                try H.refuses { _ = try journal.completeAdmission(deadline: .init(seconds: 3)) }
                let after = try assertPersistenceState(location, before: before,
                    expectedControl: control, controlPublished: false, receipt: expected.0, retainedPreimage: false)
                try assertStickyPersistence(location, admission: admission, journal: journal, expected: after, pending: true)
            }
        }
        let receiptCuts: [CustodyCatalogStore.Fault] = [.beforeSwap, .afterSwap, .afterDirectorySync]
        let controlCuts: [CustodyCatalogStore.Fault] = [.beforeSwap, .afterSwap, .afterDirectorySync, .afterPreimageUnlink]
        for receiptWrite in [true, false] {
            for cut in receiptWrite ? receiptCuts : controlCuts {
                try fixture { _, location, _, _, admission, journal, _ in
                    let before = try persistenceSnapshot(location), control = try record(location)
                    let expected = try expectedAdmissionCompletion(control)
                    try InstallationOwnershipFixtures.excluded(location)
                    if receiptWrite { journal.testingWriteFault(receipt: cut) }
                    else { journal.testingWriteFault(control: cut) }
                    try H.refuses { _ = try journal.completeAdmission(deadline: .init(seconds: 3)) }
                    let controlPublished = !receiptWrite && cut != .beforeSwap
                    let receiptPublished = !receiptWrite || cut != .beforeSwap
                    let retained = !receiptWrite && (cut == .afterSwap || cut == .afterDirectorySync)
                    // afterSwap asserts exact visible bytes/identity, not crash
                    // durability before directory fsync. A thrown write never
                    // becomes an in-memory successful completion.
                    let after = try assertPersistenceState(location, before: before,
                        expectedControl: controlPublished ? expected.1 : control, controlPublished: controlPublished,
                        receipt: receiptPublished ? expected.0 : nil, retainedPreimage: retained)
                    try assertStickyPersistence(location, admission: admission, journal: journal,
                        expected: after, pending: true)
                }
            }
        }
        for cut in controlCuts {
            try fixture { _, location, owner, _, admission, journal, registry in
                _ = try journal.completeAdmission(deadline: .init(seconds: 3))
                // A stop-only transition still uses actual zero-alias closure and
                // the existing registry retirement proof; pending flags, control
                // bytes and a public snapshot cannot mint it.
                var alias: CustodyAuthorityLeaseSet? = try admission.retainStartLeases()
                weak var releasedAlias = alias
                try H.refuses { _ = try admission.closeStarts() }
                try alias!.validate(); try InstallationOwnershipFixtures.excluded(location)
                alias = nil
                try H.check(releasedAlias == nil, "stop recovery retained staged alias")
                let closed = try admission.closeStarts()
                let retirement = try registry.installationStagedStartRetirement(after: closed)
                try retirement.revalidate(for: owner)
                let stop = try admission.stopOnly(after: retirement)
                try stop.revalidate()
                let before = try persistenceSnapshot(location), control = try record(location)
                let recovery = InstallationControlRecord(revision: control.revision + 1, phase: .recovery,
                    state: control.state, transaction: control.transaction, step: control.step,
                    latestReceiptDigest: control.latestReceiptDigest, readinessCommit: nil, recoveryReason: .readinessFailed)
                journal.testingWriteFault(control: cut)
                try H.refuses { _ = try journal.candidateStopIntent(admission: stop, deadline: .init(seconds: 3)) }
                let published = cut != .beforeSwap
                let retained = cut == .afterSwap || cut == .afterDirectorySync
                let after = try assertPersistenceState(location, before: before,
                    expectedControl: published ? recovery : control, controlPublished: published,
                    receipt: nil, retainedPreimage: retained)
                // The preliminary recovery write has NO pending action receipt;
                // nil pending must not be mistaken for a retryable continuation.
                try assertStickyPersistence(location, admission: admission, journal: journal,
                    expected: after, pending: false, stop: stop)
                try H.check(try record(location).step?.action == .openStagedAdmission,
                    "recovery control failure published a candidate-stop action")
            }
        }
        try fixture { _, location, _, _, admission, journal, _ in
            let before = try persistenceSnapshot(location), control = try record(location)
            try InstallationOwnershipFixtures.excluded(location)
            try H.refuses { _ = try journal.completeAdmission(deadline: .init(seconds: 0)) }
            let after = try assertPersistenceState(location, before: before,
                expectedControl: control, controlPublished: false, receipt: nil, retainedPreimage: false)
            try assertStickyPersistence(location, admission: admission, journal: journal, expected: after, pending: false)
        }
    }
}
#endif
