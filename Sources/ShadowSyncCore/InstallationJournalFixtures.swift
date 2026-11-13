#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

enum InstallationJournalFixtures {
    typealias H = InstallationStorageFixtures
    typealias J = CustodyCatalogStore.InstallationJournalSession
    private static func bytes(_ path: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
    private static func write(_ path: String, _ data: Data) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try H.check(fd >= 0, "fixture exclusive receipt"); defer { close(fd) }
        try data.withUnsafeBytes { p in
            var offset = 0
            while offset < p.count {
                let n = Darwin.write(fd, p.baseAddress!.advanced(by: offset), p.count - offset)
                try H.check(n > 0, "fixture receipt write"); offset += n
            }
        }
        try H.check(fsync(fd) == 0, "fixture receipt fsync")
    }
    private static func fixture(_ body: (String, StateLocation, InstallationTransactionOwner, InstallationLifecycle, J) throws -> Void) throws {
        try InstallationSlotCaptureFixtures.fixture { root, location, owner, _, lifecycle in
            let session = try owner.installationJournal(intent: .install, lifecycle: lifecycle)
            try body(root, location, owner, lifecycle, session)
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    private static func validateStored(_ owner: InstallationTransactionOwner) throws {
        let store = try CustodyCatalogStore(leases: owner.retainExclusiveLeases())
        _ = try store.testingInstallationRecord()
    }
    private static func image(_ location: StateLocation) throws -> [String: Data] {
        let root = location.path + "/custody"
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: root) where name != "receipts" {
            result[name] = try bytes(root + "/" + name)
        }
        for name in try FileManager.default.contentsOfDirectory(atPath: root + "/receipts") {
            result["receipts/" + name] = try bytes(root + "/receipts/" + name)
        }
        return result
    }
    private static func injected(_ body: () throws -> Void) throws {
        do { try body() } catch CustodyRecordError.injectedFailure { return }
        throw H.Failure(message: "expected exact injected cut was not reached")
    }
    static func reservationAndFailure() throws {
        for complete in [false, true] {
            try fixture { _, location, owner, lifecycle, session in
                let started = DispatchTime.now().uptimeNanoseconds
                let before = try image(location)
                try H.refuses { _ = try session.recordFailure(.interrupted, deadline: MonotonicDeadline(seconds: 0.750)) }
                try H.refuses { _ = try session.begin(deadline: MonotonicDeadline(seconds: 0)) }
                try H.check(try image(location) == before, "expired caller deadline wrote state")
                let begun = try session.begin(deadline: MonotonicDeadline(seconds: 0.750))
                try H.check(begun.revision == 2 && begun.phase == .active && begun.step?.status == .intent,
                            "reserve intent missing")
                try H.check(begun.transaction?.candidate != nil && begun.readinessCommit == nil, "false readiness authority")
                try validateStored(owner)
                let store = try CustodyCatalogStore(leases: owner.retainExclusiveLeases())
                try H.refuses { try store.checkFence(ownRequests: [], scope: RunIdentity.make(), mode: .lifecycleMutation) }
                try H.refuses { _ = try owner.installationJournal(intent: .install, lifecycle: lifecycle) }
                try H.refuses { _ = try session.begin(deadline: MonotonicDeadline(seconds: 0.750)) }
                let previous = complete ? try session.completeReservation(deadline: MonotonicDeadline(seconds: 0.750)) : begun
                try H.check(previous.transaction?.slots == begun.transaction?.slots, "reserve changed slots")
                let disk = try image(location), failure = try session.recordFailure(.interrupted, deadline: MonotonicDeadline(seconds: 0.750))
                try H.check(failure.phase == .recovery && failure.revision == previous.revision + 1
                    && failure.step == previous.step && failure.transaction == previous.transaction
                    && failure.latestReceiptDigest == previous.latestReceiptDigest && failure.readinessCommit == nil,
                    "failure changed action or made readiness")
                try H.check(try image(location).filter { $0.key != "installation.json" } == disk.filter { $0.key != "installation.json" },
                            "failure rewrote receipts")
                try validateStored(owner)
                try H.refuses { _ = try session.completeReservation(deadline: MonotonicDeadline(seconds: 0.750)) }
                try H.refuses { _ = try session.recordFailure(.restoredStopped, deadline: MonotonicDeadline(seconds: 0.750)) }
                try H.check(DispatchTime.now().uptimeNanoseconds - started < 750_000_000, "small journal caller budget exceeded")
            }
        }
    }
    static func receiptCuts() throws {
        for completion in [false, true] {
            for cut in [J.Cut.afterReceipt, .beforeControl] {
                try fixture { _, location, owner, _, session in
                    if completion { _ = try session.begin(deadline: MonotonicDeadline(seconds: 0.750)); try validateStored(owner) }
                    let old = try bytes(location.path + "/custody/installation.json")
                    session.testingCut(cut)
                    try injected { if completion { _ = try session.completeReservation(deadline: MonotonicDeadline(seconds: 0.750)) } else { _ = try session.begin(deadline: MonotonicDeadline(seconds: 0.750)) } }
                    try H.check(try bytes(location.path + "/custody/installation.json") == old, "cut replaced control early")
                    // The strict ordinary storage reader passed immediately above
                    // for completion; only the extra receipt now causes refusal.
                    if completion {
                        try H.refuses { try validateStored(owner) }
                        try H.refuses { _ = try session.recordFailure(.persistence, deadline: MonotonicDeadline(seconds: 0.750)) }
                    } else {
                        try H.refuses { _ = try session.begin(deadline: MonotonicDeadline(seconds: 0.750)) }
                    }
                    let receiptImage = try image(location).filter { $0.key != "installation.json" }
                    let recovered = try session.reconcileNextReceipt(deadline: MonotonicDeadline(seconds: 0.750))
                    try H.check(recovered.phase == .active && recovered.step?.status == (completion ? .complete : .intent),
                                "exact saved successor not reconciled")
                    try H.check(try image(location).filter { $0.key != "installation.json" } == receiptImage, "reconcile duplicated receipts")
                    try validateStored(owner)
                    try H.refuses { _ = try session.reconcileNextReceipt(deadline: MonotonicDeadline(seconds: 0.750)) }
                    if !completion { _ = try session.completeReservation(deadline: MonotonicDeadline(seconds: 0.750)) }
                    try validateStored(owner)
                }
            }
        }
    }
    static func tamperedSuccessors() throws {
        for attack in ["unknown-receipt-temp", "unknown-control-temp", "branch", "two-extras", "wrong-filename", "missing-prefix", "unknown-document"] {
            try fixture { root, location, owner, _, session in
                _ = try session.begin(deadline: MonotonicDeadline(seconds: 0.750)); try validateStored(owner)
                session.testingCut(.afterReceipt)
                try injected { _ = try session.completeReservation(deadline: MonotonicDeadline(seconds: 0.750)) }
                let receipts = location.path + "/custody/receipts"
                let names = try FileManager.default.contentsOfDirectory(atPath: receipts)
                let completion = names.first { $0.contains("-complete-") }!
                let pending = try InstallationStepReceipt.decode(bytes(receipts + "/" + completion), uid: location.uid)
                var added: String?, displaced: (String, String)?
                if attack == "unknown-receipt-temp" || attack == "unknown-control-temp" {
                    added = (attack == "unknown-receipt-temp" ? receipts : location.path + "/custody") + "/.custody-pending-" + RunIdentity.make()
                    try write(added!, Data("uncertain".utf8))
                } else if attack == "branch" || attack == "two-extras" {
                    let extra = InstallationStepReceipt(transactionID: pending.transactionID,
                        ordinal: attack == "branch" ? 1 : 2,
                        previousReceiptDigest: attack == "branch" ? pending.previousReceiptDigest : try pending.digest(uid: location.uid),
                        action: attack == "branch" ? .reserve : .drainPrior,
                        status: attack == "branch" ? .complete : .intent,
                        preimage: pending.preimage, postimage: attack == "branch" ? pending.postimage : nil,
                        bindingDigest: attack == "branch" ? String(repeating: "a", count: 64) : pending.bindingDigest)
                    added = try receipts + "/" + extra.filename(uid: location.uid)
                    try write(added!, extra.encode(uid: location.uid))
                } else if attack == "wrong-filename" {
                    added = receipts + "/" + InstallationStepReceipt.prefix + RunIdentity.make() + ".json"
                    try write(added!, pending.encode(uid: location.uid))
                } else if attack == "missing-prefix" {
                    let name = names.first { $0.hasPrefix(InstallationStepReceipt.prefix) && $0.contains("-intent-") }!
                    displaced = (receipts + "/" + name, root + "/retained-prefix")
                    try H.check(rename(displaced!.0, displaced!.1) == 0, "move prefix")
                } else {
                    let name = names.first { $0.hasPrefix(InstallationDocumentPreimage.prefix) }!
                    let old = try InstallationDocumentPreimage.decode(bytes(receipts + "/" + name), uid: location.uid)
                    let extra = InstallationDocumentPreimage(transactionID: RunIdentity.make(), slot: old.slot, document: old.document,
                        namespace: old.namespace, node: old.node, bytes: old.bytes)
                    added = try receipts + "/" + extra.filename(uid: location.uid)
                    try write(added!, extra.encode(uid: location.uid))
                }
                let preserved = try image(location)
                try H.refuses { _ = try session.reconcileNextReceipt(deadline: MonotonicDeadline(seconds: 0.750)) }
                try H.check(try image(location) == preserved, "refusal discarded evidence")
                if let added { try H.check(unlink(added) == 0, "remove owned attack fixture") }
                if let displaced { try H.check(rename(displaced.1, displaced.0) == 0, "restore exact prefix") }
                // Removing only the owned attack must restore the exact same
                // session's success. An unrelated earlier fence cannot pass.
                _ = try session.reconcileNextReceipt(deadline: MonotonicDeadline(seconds: 0.750)); try validateStored(owner)
            }
        }
    }
    static func sourceAndOwnerDrift() throws {
        try fixture { _, location, owner, _, session in
            _ = try session.begin(deadline: MonotonicDeadline(seconds: 0.750)); try validateStored(owner)
            session.testingCut(.afterReceipt); try injected { _ = try session.completeReservation(deadline: MonotonicDeadline(seconds: 0.750)) }
            let path = location.path + "/selection-preferences.json"
            try write(path, Data("changed-source".utf8))
            let saved = try image(location)
            try H.refuses { _ = try session.reconcileNextReceipt(deadline: MonotonicDeadline(seconds: 0.750)) }
            try H.check(try image(location) == saved, "source drift rewrote journal")
            try H.check(unlink(path) == 0, "remove owned source fixture")
            _ = try session.reconcileNextReceipt(deadline: MonotonicDeadline(seconds: 0.750)); try validateStored(owner)
        }
        // The original operation description remains owned even if the caller
        // releases its old alias; the live journal owns the consumed family.
        try InstallationOwnershipFixtures.fixture { root, location, original in
            for suffix in ["/home", "/home/Applications", "/home/Library", "/home/Library/LaunchAgents"] {
                try H.check(mkdir(root + suffix, 0o700) == 0, "journal fixture parent")
            }
            let owner = try InstallationTransactionOwner.testingConsume(original, root: root)
            let source = try InstallationOwnershipFixtures.bindingSource(root, original)
            try owner.testingSetBindingSource(source)
            let lifecycle = try InstallationLifecycle(paths: .isolated(root: root),
                launchAgent: InstallationSlotCaptureFixtures.NoCommands(), host: InstallationSlotCaptureFixtures.NoCommands())
            let session = try owner.installationJournal(intent: .install, lifecycle: lifecycle)
            _ = try session.begin(deadline: MonotonicDeadline(seconds: 0.750)); try validateStored(owner)
            session.testingCut(.afterReceipt); try injected { _ = try session.completeReservation(deadline: MonotonicDeadline(seconds: 0.750)) }
            let boot = source.boot; source.boot = RunIdentity.make()
            let saved = try image(location)
            try H.refuses { _ = try session.reconcileNextReceipt(deadline: MonotonicDeadline(seconds: 0.750)) }
            try H.check(try image(location) == saved, "stale binding wrote control")
            source.boot = boot; original.release()
            try InstallationOwnershipFixtures.excluded(location)
            _ = try session.reconcileNextReceipt(deadline: MonotonicDeadline(seconds: 0.750)); try validateStored(owner)
        }
    }
    static func uncertainWriteCuts() throws {
        for receipt in [true, false] {
            for cut in [CustodyCatalogStore.Fault.beforeSwap, .afterSwap, .afterDirectorySync, .afterPreimageUnlink] {
                if receipt && cut == .afterPreimageUnlink { continue }
                try fixture { _, location, owner, _, session in
                    _ = try session.begin(deadline: MonotonicDeadline(seconds: 0.750)); try validateStored(owner)
                    print("JOURNAL_WRITE_CUT testingWriteFault receipt=\(receipt) cut=\(cut)")
                    session.testingWriteFault(receipt: receipt ? cut : nil, control: receipt ? nil : cut)
                    do { _ = try session.completeReservation(deadline: MonotonicDeadline(seconds: 0.750)); throw H.Failure(message: "write cut missed") }
                    catch CustodyRecordError.injectedFailure {} catch CustodyRecordError.committedCleanupFailure {}
                    let saved = try image(location)
                    try H.refuses { _ = try session.reconcileNextReceipt(deadline: MonotonicDeadline(seconds: 0.750)) }
                    try H.check(try image(location) == saved, "uncertain cut cleanup or replay")
                    // No new control is inferred from a failed write. Reopened
                    // storage reader accepts only an independently valid full chain.
                    let fresh = try CustodyCatalogStore(leases: owner.retainExclusiveLeases())
                    if !receipt && cut == .afterPreimageUnlink {
                        let record = try fresh.testingInstallationRecord()
                        try H.check(record.step?.status == .complete && record.readinessCommit == nil, "committed cleanup distinction lost")
                    } else if receipt && cut == .beforeSwap {
                        try H.check(try fresh.testingInstallationRecord().step?.status == .intent, "testingInstallationRecord receipt preswap changed control")
                    } else { try H.refuses { try validateStored(owner) } }
                }
            }
        }
    }
    static func controlAndReceiptIdentity() throws {
        for target in ["control", "pending", "document", "acl", "mode"] {
            try fixture { root, location, owner, _, session in
                _ = try session.begin(deadline: MonotonicDeadline(seconds: 0.750)); try validateStored(owner)
                session.testingCut(.afterReceipt); try injected { _ = try session.completeReservation(deadline: MonotonicDeadline(seconds: 0.750)) }
                let receiptRoot = location.path + "/custody/receipts"
                let names = try FileManager.default.contentsOfDirectory(atPath: receiptRoot)
                let path = target == "control" ? location.path + "/custody/installation.json" : receiptRoot + "/" + names.first {
                    target == "document" ? $0.hasPrefix(InstallationDocumentPreimage.prefix) : $0.contains("-complete-")
                }!
                if target == "mode" { try H.check(chmod(path, 0o640) == 0, "mode fixture") }
                else if target == "acl" {
                    try InstallationOwnershipFixtures.withACLGrant(path) {
                        let saved = try image(location)
                        try H.refuses { _ = try session.reconcileNextReceipt(deadline: MonotonicDeadline(seconds: 0.750)) }
                        try H.check(try image(location) == saved, "ACL refusal changed bytes")
                    }
                    _ = try session.reconcileNextReceipt(deadline: MonotonicDeadline(seconds: 0.750)); try validateStored(owner)
                    return
                } else {
                    let data = try bytes(path)
                    try H.check(rename(path, root + "/held-original") == 0, "identity fixture preserve")
                    try write(path, data)
                }
                let saved = try image(location)
                try H.refuses { _ = try session.reconcileNextReceipt(deadline: MonotonicDeadline(seconds: 0.750)) }
                try H.check(try image(location) == saved, "identity refusal changed bytes")
                if target == "mode" { try H.check(chmod(path, 0o600) == 0, "restore mode") }
                else {
                    try H.check(unlink(path) == 0 && rename(root + "/held-original", path) == 0, "restore pinned identity")
                }
                _ = try session.reconcileNextReceipt(deadline: MonotonicDeadline(seconds: 0.750)); try validateStored(owner)
            }
        }
    }
    static func maximumDocuments() throws {
        try InstallationSlotCaptureFixtures.fixture { _, location, owner, _, lifecycle in
            for document in InstallationDocument.allCases {
                let data = Data(repeating: 7, count: InstallationDocumentPreimage.maximumContentBytes(for: document))
                let path = location.path + "/" + document.rawValue
                if document == .latestLog {
                    let fd = open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
                    try H.check(fd >= 0, "maximum journal log"); defer { close(fd) }
                    try data.withUnsafeBytes { p in
                        var offset = 0
                        while offset < p.count {
                            let n = pwrite(fd, p.baseAddress!.advanced(by: offset), p.count - offset, off_t(offset))
                            try H.check(n > 0, "maximum journal log write"); offset += n
                        }
                    }
                    try H.check(ftruncate(fd, off_t(data.count)) == 0 && fsync(fd) == 0, "maximum journal log durability")
                } else { try write(path, data) }
            }
            let session = try owner.installationJournal(intent: .install, lifecycle: lifecycle)
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try session.begin(deadline: MonotonicDeadline(seconds: 0.750))
            let begun = DispatchTime.now().uptimeNanoseconds
            session.testingCut(.afterReceipt)
            try injected { _ = try session.completeReservation(deadline: MonotonicDeadline(seconds: 0.750)) }
            let cut = DispatchTime.now().uptimeNanoseconds
            _ = try session.reconcileNextReceipt(deadline: MonotonicDeadline(seconds: 0.750))
            let reconciled = DispatchTime.now().uptimeNanoseconds
            try validateStored(owner)
            print("JOURNAL_MAX_NS begin=\(begun - start) cut=\(cut - begun) reconcile=\(reconciled - cut)")
            let files = try image(location).filter { $0.key.hasPrefix("receipts/" + InstallationDocumentPreimage.prefix) }
            try H.check(files.count == InstallationDocument.allCases.count, "maximum document coverage lost")
            for data in files.values {
                let receipt = try InstallationDocumentPreimage.decode(data, uid: location.uid)
                try H.check(receipt.bytes.count == InstallationDocumentPreimage.maximumContentBytes(for: receipt.document),
                            "maximum document truncated")
            }
        }
    }
    static func committedRollover() throws {
        try InstallationSlotCaptureFixtures.fixture { root, location, owner, _, lifecycle in
            try CustodyCatalogStore.testingSeedCommittedInstallation(leases: owner.retainExclusiveLeases(), root: root)
            try validateStored(owner)
            let saved = try image(location)
            try H.refuses { _ = try owner.installationJournal(intent: .repair, lifecycle: lifecycle) }
            try H.check(try image(location) == saved, "rollover ignored or rewrote historical chain")
            try validateStored(owner)
        }
    }
}
#endif
