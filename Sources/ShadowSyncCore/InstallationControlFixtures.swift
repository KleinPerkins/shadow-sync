#if SHADOW_SYNC_TESTING
import Foundation

// These are metadata tests only: no installed state, filesystem, process, native
// peer, registration, current boot, network or real deployment policy is read.
enum InstallationControlFixtures {
    struct Failure: Error { let message: String }
    static func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    static func refuses(_ body: () throws -> Void) throws {
        do { try body() }
        catch is InstallationRecordError { return }
        throw Failure(message: "invalid installation metadata accepted")
    }
    static let uuid = "00000000-0000-4000-8000-000000000001"
    static let boot = "00000000-0000-4000-8000-000000000002"
    static let generation = "00000000-0000-4000-8000-000000000003"
    static let sha = String(repeating: "a", count: 64)
    static let otherSHA = String(repeating: "b", count: 64)
    static let cd = String(repeating: "c", count: 40)
    static func node(_ inode: UInt64, type: InstallationNodeType = .regular) -> InstallationNodeIdentity {
        InstallationNodeIdentity(device: 1, inode: inode, type: type, uid: 501,
            mode: type == .directory ? 0o040700 : type == .regular ? 0o100600 : 0o140600,
            links: 1, aclDigest: sha)
    }
    static func state() -> InstallationStateBinding {
        InstallationStateBinding(directory: node(1, type: .directory), namespace: node(2), lifecycle: node(3),
            operation: node(4), run: node(5), launcher: node(6), catalogGuard: node(7))
    }
    static func slots() -> InstallationSlotSnapshot {
        var images: [InstallationSlot: InstallationSlotImage] = [:]
        for (index, slot) in InstallationSlot.allCases.enumerated() {
            images[slot] = InstallationSlotImage(parentDevice: 1, parentInode: UInt64(index + 100),
                node: nil, size: nil, contentDigest: nil, documentReceipts: nil)
        }
        return InstallationSlotSnapshot(images: images)
    }
    static func process(_ pid: UInt32, uid: UInt32 = 501) -> InstallationProcessObservation {
        InstallationProcessObservation(pid: pid, uid: uid, startSeconds: 1, startMicroseconds: 2, generation: generation)
    }
    static func transaction(intent: InstallationTransactionIntent = .install, uid: UInt32 = 501) throws -> InstallationTransaction {
        let release = try ReleaseIdentity(sourceRevision: String(repeating: "d", count: 40), sourceInputSHA256: sha,
            releaseContractSHA256: otherSHA, architecture: "arm64", buildMode: "production")
        return InstallationTransaction(id: uuid, boot: boot, intent: intent,
            coordinator: InstallationCoordinatorObservation(process: process(400, uid: uid), team: ReleaseIdentity.publisherTeamIdentifier,
                identifier: LifecyclePublisher.identifier, cdHash: cd), sourceReleaseDigest: otherSHA,
            candidate: intent == .remove ? nil : InstallationCandidate(release: release, bundleDigest: sha, appCDHash: cd, coordinatorCDHash: cd),
            priorCommitDigest: nil, slots: slots())
    }
    static func replacing(_ wire: PolicyWireValue, key: String, with value: PolicyWireValue) throws -> PolicyWireValue {
        guard case var .object(v) = wire else { throw Failure(message: "bad fixture") }
        v[key] = value; return .object(v)
    }
    static func decode(_ wire: PolicyWireValue) throws -> InstallationControlRecord {
        try InstallationControlRecord.decode(CustodyWire.encode(wire, maximum: InstallationControlRecord.maximumBytes))
    }
    static func bytes(_ wire: PolicyWireValue) throws -> Data { try CustodyWire.encode(wire, maximum: 32_768) }

    // This harness writes no files and performs no action. It builds candidate
    // metadata using the same exact chain constraints expected from store writes.
    struct Harness {
        let state: InstallationStateBinding
        let transaction: InstallationTransaction
        var receipts: [InstallationStepReceipt] = []
        var record: InstallationControlRecord
        init(intent: InstallationTransactionIntent = .install, state binding: InstallationStateBinding? = nil) throws {
            state = binding ?? InstallationControlFixtures.state()
            transaction = try InstallationControlFixtures.transaction(intent: intent, uid: state.directory.uid)
            record = try .initial(state: state)
        }
        mutating func add(_ action: InstallationAction, status: InstallationStepStatus,
                          phase: InstallationPhase? = nil, reason: InstallationRecoveryReason? = nil,
                          commit: InstallationReadinessCommit? = nil, validate: Bool = true) throws {
            let ordinal = status == .complete ? receipts.last!.ordinal : (receipts.last?.ordinal ?? 0) + 1
            let receipt = InstallationStepReceipt(transactionID: transaction.id, ordinal: ordinal,
                previousReceiptDigest: try receipts.last?.digest(uid: state.directory.uid), action: action, status: status,
                preimage: transaction.slots, postimage: status == .complete ? transaction.slots : nil,
                bindingDigest: try bindingDigest())
            let next = InstallationControlRecord(revision: record.revision + 1, phase: phase ?? (record.phase == .initial ? .active : record.phase),
                state: state, transaction: transaction, step: try receipt.step(), latestReceiptDigest: try receipt.digest(uid: state.directory.uid),
                readinessCommit: commit ?? record.readinessCommit, recoveryReason: reason ?? record.recoveryReason)
            let proposed = receipts + [receipt]
            if validate { try record.validateReplacement(next, receipts: proposed) }
            receipts = proposed; record = next
        }
        func bindingDigest() throws -> String {
            let temporary = InstallationControlRecord(revision: 2, phase: .active, state: state, transaction: transaction,
                step: nil, latestReceiptDigest: nil, readinessCommit: nil, recoveryReason: nil)
            return try temporary.bindingDigest()
        }
        mutating func pair(_ action: InstallationAction) throws { try add(action, status: .intent); try add(action, status: .complete) }
        mutating func recover(_ reason: InstallationRecoveryReason = .interrupted) throws {
            let next = InstallationControlRecord(revision: record.revision + 1, phase: .recovery, state: state,
                transaction: transaction, step: record.step, latestReceiptDigest: record.latestReceiptDigest,
                readinessCommit: record.readinessCommit, recoveryReason: reason)
            try record.validateReplacement(next, receipts: receipts); record = next
        }
        mutating func throughReady() throws {
            for action in [InstallationAction.reserve, .drainPrior, .stageApplication, .stagePlist, .retireApplication,
                .retirePlist, .retireCoordination, .translateState, .moveStateForward, .promoteApplication, .promotePlist,
                .openStagedAdmission, .bootstrapCandidate, .kickstartCandidate, .candidateReady] { try pair(action) }
        }
        mutating func commitReady() throws {
            let readyDigest = try receipts.last!.digest(uid: state.directory.uid)
            try add(.readinessCommit, status: .intent)
            let c = InstallationReadinessCommit(transactionID: uuid, commitRevision: record.revision + 1,
                candidateReleaseDigest: transaction.candidate!.release.releaseContractSHA256,
                candidateBundleDigest: sha, candidateAppCDHash: cd, candidateCoordinatorCDHash: cd,
                stateBindingDigest: try state.digest(), completedStepReceiptDigest: readyDigest,
                host: InstallationControlFixtures.process(401, uid: state.directory.uid), precommitTranscriptDigest: otherSHA)
            try add(.readinessCommit, status: .complete, phase: .committed, commit: c)
        }
    }
    static func initial() throws {
        let initial = try InstallationControlRecord.initial(state: state())
        try initial.validateReceiptChain([])
        try check(initial.phase == .initial && initial.transaction == nil && initial.readinessCommit == nil,
                  "initial fabricated an installation or commit")
        try check(try InstallationControlRecord.decode(initial.encode()) == initial, "initial roundtrip")
    }
    static func firstIntent() throws {
        var h = try Harness(); try h.add(.reserve, status: .intent)
        try h.record.validateReceiptChain(h.receipts)
        try check(h.record.phase == .active && h.record.step?.status == .intent && h.receipts[0].postimage == nil
            && h.record.latestReceiptDigest != nil, "first intent needed a fabricated genesis success")
        try check(try InstallationControlRecord.decode(h.record.encode()) == h.record, "17-slot intent roundtrip")
        try check(try InstallationStepReceipt.decode(h.receipts[0].encode(uid: 501), uid: 501) == h.receipts[0], "intent receipt roundtrip")
    }
    static func malformed() throws {
        let initial = try InstallationControlRecord.initial(state: state())
        let data = try initial.encode(), text = String(decoding: data, as: UTF8.self)
        let bad = [data + Data(" ".utf8), Data(text.replacingOccurrences(of: "\"revision\":1", with: "\"revision\":1,\"revision\":1").utf8),
            Data(text.replacingOccurrences(of: "\"revision\":1", with: "\"revision\":01").utf8),
            Data(text.replacingOccurrences(of: "\"revision\":1", with: "\"revision\":-1").utf8),
            Data(text.replacingOccurrences(of: "\"revision\":1", with: "\"revision\":18446744073709551616").utf8),
            Data(text.replacingOccurrences(of: "\"phase\":\"initial\"", with: "\"phase\":\"idle\"").utf8),
            Data(repeating: 32, count: 32_769)]
        for value in bad { try refuses { _ = try InstallationControlRecord.decode(value) } }
        try refuses { _ = try decode(replacing(initial.wire, key: "path", with: .string("/fixture/other"))) }
        try refuses { _ = try decode(replacing(initial.wire, key: "args", with: .array([]))) }
        // Canonical equality rejects an otherwise-equivalent escaped scalar.
        let escaped = Data(text.replacingOccurrences(of: "initial", with: "\\u0069nitial").utf8)
        try refuses { _ = try InstallationControlRecord.decode(escaped) }
    }
    static func fixedSlots() throws {
        var h = try Harness(); try h.add(.reserve, status: .intent)
        guard case let .object(control) = h.record.wire,
              case let .object(tx) = control["transaction"], case var .object(images) = tx["slots"] else { throw Failure(message: "fixture shape") }
        images.removeValue(forKey: InstallationSlot.installationSocket.rawValue)
        let noSocket = try replacing(.object(tx), key: "slots", with: .object(images))
        try refuses { _ = try decode(replacing(h.record.wire, key: "transaction", with: noSocket)) }
        images["arbitrary/path"] = slots().images[.application]!.wire
        let arbitrary = try replacing(.object(tx), key: "slots", with: .object(images))
        try refuses { _ = try decode(replacing(h.record.wire, key: "transaction", with: arbitrary)) }
        let socket = InstallationSlotImage(parentDevice: 1, parentInode: 1, node: node(99, type: .socket),
            size: nil, contentDigest: sha, documentReceipts: nil)
        try refuses { try socket.validate(slot: .installationSocket, uid: 501) }
        let incompleteDocuments = InstallationSlotImage(parentDevice: 1, parentInode: 1, node: node(99, type: .directory),
            size: nil, contentDigest: nil, documentReceipts: [.latestLog: sha])
        try refuses { try incompleteDocuments.validate(slot: .stateSource, uid: 501) }
        var documents: [InstallationDocument: String?] = [:]
        for name in InstallationDocument.allCases { documents.updateValue(nil, forKey: name) }
        documents.updateValue(sha, forKey: .latestLog)
        let namespace = InstallationSlotImage(parentDevice: 1, parentInode: 1, node: node(99, type: .directory),
            size: nil, contentDigest: nil, documentReceipts: documents)
        try namespace.validate(slot: .stateDestination, uid: 501)
        let reread = try InstallationSlotImage(wire: namespace.wire)
        try reread.validate(slot: .stateDestination, uid: 501)
        try check(reread == namespace && reread.documentReceipts?.count == 4, "null document keys were dropped")
    }
    static func phases() throws {
        var h = try Harness(); try h.add(.reserve, status: .intent)
        try refuses { _ = try decode(replacing(h.record.wire, key: "phase", with: .string("initial"))) }
        try refuses { _ = try decode(replacing(h.record.wire, key: "phase", with: .string("committed"))) }
        try refuses { _ = try decode(replacing(h.record.wire, key: "phase", with: .string("recovery"))) }
        try refuses { _ = try decode(replacing(h.record.wire, key: "recoveryReason", with: .string("interrupted"))) }
        try refuses { _ = try decode(replacing(h.record.wire, key: "latestReceiptDigest", with: .null)) }
        try refuses { _ = try decode(replacing(h.record.wire, key: "transaction", with: .null)) }
    }
    static func transitions() throws {
        var h = try Harness(); try h.pair(.reserve)
        var wrong = h
        try refuses { try wrong.add(.promoteApplication, status: .intent) }
        try h.pair(.drainPrior)
        try check(h.record.step?.action == .drainPrior, "finite transition rejected valid next action")
        var remove = try Harness(intent: .remove); try remove.pair(.reserve); try remove.pair(.drainPrior)
        try refuses { try remove.add(.stageApplication, status: .intent) }
    }
    static func intentIsNotCompletion() throws {
        var h = try Harness(); try h.add(.reserve, status: .intent)
        try refuses { try h.add(.drainPrior, status: .intent) }
        let receipt = h.receipts[0]
        let bad = InstallationStepReceipt(transactionID: uuid, ordinal: 1, previousReceiptDigest: try receipt.digest(uid: 501),
            action: .reserve, status: .complete, preimage: slots(), postimage: nil, bindingDigest: try h.bindingDigest())
        try refuses { try bad.validate(uid: 501) }
    }
    static func chain() throws {
        var h = try Harness(); try h.pair(.reserve); try h.pair(.drainPrior)
        let last = h.receipts.removeLast()
        let badLink = InstallationStepReceipt(transactionID: last.transactionID, ordinal: last.ordinal, previousReceiptDigest: otherSHA,
            action: last.action, status: last.status, preimage: last.preimage, postimage: last.postimage, bindingDigest: last.bindingDigest)
        try refuses { try h.record.validateReceiptChain(h.receipts + [badLink]) }
        try refuses { try h.record.validateReceiptChain([last]) }
        let foreign = InstallationStepReceipt(transactionID: uuid, ordinal: last.ordinal, previousReceiptDigest: last.previousReceiptDigest,
            action: last.action, status: last.status, preimage: last.preimage, postimage: last.postimage, bindingDigest: otherSHA)
        try refuses { try h.record.validateReceiptChain(h.receipts + [foreign]) }
    }
    static func commitReference() throws {
        var h = try Harness(); try h.throughReady(); try h.commitReady()
        try h.record.validateReceiptChain(h.receipts)
        let good = h.record.readinessCommit!
        let earlyCommit = try replacing(good.wire, key: "commitRevision", with: .unsigned(2))
        let impossibleCommit = try decode(replacing(h.record.wire, key: "readinessCommit", with: earlyCommit))
        try refuses { try impossibleCommit.validateReceiptChain(h.receipts) }
        let impossibleControl = try decode(replacing(impossibleCommit.wire, key: "revision", with: .unsigned(2)))
        try refuses { try impossibleControl.validateReceiptChain(h.receipts) }
        // Subsequent receipts each require another revision after the commit.
        try h.pair(.cleanupCoordination)
        let lateCommit = try replacing(good.wire, key: "commitRevision", with: .unsigned(h.record.revision))
        let impossibleTail = try decode(replacing(h.record.wire, key: "readinessCommit", with: lateCommit))
        try refuses { try impossibleTail.validateReceiptChain(h.receipts) }
        // Keep the original non-circular receipt assertions on the commit cut.
        h = try Harness(); try h.throughReady(); try h.commitReady()
        let circular = try replacing(good.wire, key: "completedStepReceiptDigest", with: .string(try h.receipts.last!.digest(uid: 501)))
        let bad = try decode(replacing(h.record.wire, key: "readinessCommit", with: circular))
        try refuses { try bad.validateReceiptChain(h.receipts) }
        try check(good.completedStepReceiptDigest == (try h.receipts[h.receipts.count - 3].digest(uid: 501)),
                  "commit did not reference the preexisting candidate-ready completion")
        let intentDigest = try h.receipts[h.receipts.count - 4].digest(uid: 501)
        let intent = try replacing(good.wire, key: "completedStepReceiptDigest", with: .string(intentDigest))
        let badIntent = try decode(replacing(h.record.wire, key: "readinessCommit", with: intent))
        try refuses { try badIntent.validateReceiptChain(h.receipts) }
    }
    static func forwardOnly() throws {
        var h = try Harness(); try h.throughReady(); try h.commitReady(); try h.recover(.cleanupFailed)
        var forbidden = h
        try refuses { try forbidden.add(.candidateStop, status: .intent) }
        let erased = try replacing(h.record.wire, key: "readinessCommit", with: .null)
        try refuses { _ = try decode(erased).validateReceiptChain(h.receipts) }
        func resumed(_ record: InstallationControlRecord) -> InstallationControlRecord {
            InstallationControlRecord(revision: record.revision + 1, phase: .committed, state: record.state,
                transaction: record.transaction, step: record.step, latestReceiptDigest: record.latestReceiptDigest,
                readinessCommit: record.readinessCommit, recoveryReason: nil)
        }
        try refuses { try h.record.validateReplacement(resumed(h.record), receipts: h.receipts) }
        try h.pair(.cleanupCoordination); try h.pair(.cleanupBackups); try h.pair(.cleanupIncoming)
        try h.add(.finish, status: .intent)
        try refuses { try h.record.validateReplacement(resumed(h.record), receipts: h.receipts) }
        try h.add(.finish, status: .complete)
        try h.record.validateReceiptChain(h.receipts)
        try check(h.record.readinessCommit != nil && h.record.phase == .recovery, "postcommit failure erased commit/fence")
        let repaired = resumed(h.record)
        try h.record.validateReplacement(repaired, receipts: h.receipts)
        try check(repaired.readinessCommit == h.record.readinessCommit && repaired.transaction == h.record.transaction,
                  "repair completion changed committed evidence")
        // A precommit restoration cannot use this edge to manufacture readiness.
        var precommit = try Harness(); try precommit.pair(.reserve); try precommit.recover()
        try refuses { try precommit.record.validateReplacement(resumed(precommit.record), receipts: precommit.receipts) }
    }
    static func rollback() throws {
        var h = try Harness(); try h.pair(.reserve); try h.pair(.drainPrior); try h.recover()
        for action in [InstallationAction.candidateStop, .cleanupCoordination, .moveStateBack, .restoreApplication,
            .restorePlist, .restoreCoordination, .cleanupIncoming, .finish] { try h.pair(action) }
        try h.recover(.restoredStopped)
        try h.record.validateReceiptChain(h.receipts)
        try check(h.record.phase == .recovery && h.record.readinessCommit == nil, "stopped restoration admitted ordinary app")
        var forbidden = h
        try refuses { try forbidden.add(.bootstrapCandidate, status: .intent) }
    }
    static func history() throws {
        var h = try Harness(); try h.throughReady(); try h.commitReady()
        // Fixture PID=400/start=1/boot=...2 are historical metadata. Validation
        // must not call kill, capture a process, compare current boot, or read host.
        let reopened = try InstallationControlRecord.decode(h.record.encode())
        try reopened.validateReceiptChain(h.receipts)
        try check(reopened.transaction?.boot == boot && reopened.transaction?.coordinator.process.pid == 400,
                  "historical committed observation was discarded")
    }
    static func removal() throws {
        var h = try Harness(intent: .remove)
        for action in [InstallationAction.reserve, .drainPrior, .retireApplication, .retirePlist, .retireCoordination,
            .removeInstallation, .cleanupCoordination, .cleanupBackups, .cleanupIncoming] { try h.pair(action) }
        try h.recover(.interrupted); try h.pair(.finish)
        try h.record.validateReceiptChain(h.receipts)
        try check(h.record.phase == .recovery && h.record.readinessCommit == nil && h.record.transaction?.candidate == nil,
                  "removal became installed committed state")
        try refuses { _ = try decode(replacing(h.record.wire, key: "phase", with: .string("committed"))) }
    }
    static func bounds() throws {
        var h = try Harness(); try h.add(.reserve, status: .intent)
        let tooMany = try replacing(h.record.step!.wire, key: "ordinal", with: .unsigned(129))
        try refuses { _ = try decode(replacing(h.record.wire, key: "step", with: tooMany)) }
        let zero = try replacing(h.record.step!.wire, key: "ordinal", with: .unsigned(0))
        try refuses { _ = try decode(replacing(h.record.wire, key: "step", with: zero)) }
        let full = try decode(replacing(h.record.wire, key: "revision", with: .unsigned(UInt64.max)))
        try refuses { try full.validateReplacement(h.record, receipts: h.receipts) }
        try refuses { try h.record.validateReceiptChain(Array(repeating: h.receipts[0], count: 257)) }
    }
}
#endif
