#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

enum InstallationSlotCaptureFixtures {
    typealias H = InstallationStorageFixtures
    private struct NoCommands: LaunchAgentControlling, InstalledHostControlling {
        func state(label: String) -> LaunchAgentState { .queryFailure }
        func processDisposition(processID: pid_t, expectedProgram: String) -> LaunchAgentProcessDisposition { .mismatch }
        func bootstrap(label: String, plist: String, expectedProgram: String) throws { throw H.Failure(message: "capture launched command") }
        func kickstart(label: String, expectedProgram: String) throws { throw H.Failure(message: "capture launched command") }
        func bootout(label: String, expectedProgram: String) throws { throw H.Failure(message: "capture launched command") }
        func requestExit(location: StateLocation, executable: String, release: ReleaseIdentity) throws { throw H.Failure(message: "capture contacted host") }
        func isReady(location: StateLocation, executable: String, release: ReleaseIdentity, timeout: TimeInterval) -> Bool { false }
    }
    private static func fixture(_ body: (String, StateLocation, InstallationTransactionOwner, InstallationLiveBinding, InstallationLifecycle) throws -> Void) throws {
        try InstallationOwnershipFixtures.fixture { root, location, original in
            for suffix in ["/home", "/home/Applications", "/home/Library", "/home/Library/LaunchAgents"] {
                try H.check(mkdir(root + suffix, 0o700) == 0, "capture fixture parent")
            }
            let owner = try checked("consumed-owner") { try InstallationTransactionOwner.testingConsume(original, root: root) }
            try owner.testingSetBindingSource(InstallationOwnershipFixtures.bindingSource(root, original))
            let binding = try checked("live-binding") { try owner.installationBinding() }
            let lifecycle = try InstallationLifecycle(paths: .isolated(root: root), launchAgent: NoCommands(), host: NoCommands())
            try checked("capture-body") { try body(root, location, owner, binding, lifecycle) }
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    private static func refuses(_ body: () throws -> Void) throws {
        do { try H.refuses(body) } catch is InstallationLifecycleError { return }
    }
    private static func checked<T>(_ label: String, _ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw H.Failure(message: label + ": " + String(describing: error)) }
    }
    private static func capture(_ lifecycle: InstallationLifecycle, _ owner: InstallationTransactionOwner,
                                _ binding: InstallationLiveBinding) throws -> InstallationCapturedSlots {
        do { return try lifecycle.captureInstallationSlots(owner: owner, binding: binding, transactionID: InstallationControlFixtures.uuid) }
        catch { print("CAPTURE_STAGE " + lifecycle.testingSlotCaptureStage); throw error }
    }
    private static func write(_ path: String, _ bytes: Data) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try H.check(fd >= 0, "create capture document"); defer { close(fd) }
        try bytes.withUnsafeBytes { p in
            var offset = 0
            while offset < p.count {
                let n = Darwin.write(fd, p.baseAddress!.advanced(by: offset), p.count - offset)
                try H.check(n > 0, "write capture document"); offset += n
            }
        }
        try H.check(fsync(fd) == 0, "sync capture document")
    }
    static func completeDurableCapture() throws {
        try fixture { root, location, owner, binding, lifecycle in
            let content = Data([0, 1, 2, 255]) + Data("fixture-only retained document".utf8)
            try write(location.path + "/selection-preferences.json", content)
            let proof = try capture(lifecycle, owner, binding), slots = try proof.snapshot
            try H.check(slots.images.count == 17, "fixed slot coverage")
            let refs = slots.images[.stateDestination]!.documentReceipts!
            try H.check(Set(refs.keys) == Set(InstallationDocument.allCases), "fixed document key coverage")
            try H.check(refs[.authorities] == .some(nil) && refs[.selectionRecovery] == .some(nil), "absence keys dropped")
            try H.check(proof.preimages.count == 2, "durable present documents")
            for receipt in proof.preimages {
                let path = try location.path + "/custody/receipts/" + receipt.filename(uid: location.uid)
                let stored = try InstallationDocumentPreimage.decode(Data(contentsOf: URL(fileURLWithPath: path)), uid: location.uid)
                try H.check(stored == receipt, "recoverable preimage differs")
                if receipt.document == .selection { try H.check(stored.bytes == content, "binary content was truncated") }
            }
            try proof.revalidate(for: owner)
            _ = try capture(lifecycle, owner, binding) // exact idempotent retry
            let store = try CustodyCatalogStore(leases: owner.retainExclusiveLeases())
            try refuses { try store.checkFence(ownRequests: [], scope: RunIdentity.make(), mode: .observation) }
            try H.check(try FileManager.default.contentsOfDirectory(atPath: location.path + "/custody/receipts").count == 2,
                        "capture retry duplicated receipt")
            _ = root
        }
    }
    static func maximumDocuments() throws {
        try fixture { _, location, owner, binding, lifecycle in
            for document in InstallationDocument.allCases {
                let bytes = Data(repeating: UInt8(InstallationDocument.allCases.firstIndex(of: document)! + 1),
                                 count: InstallationDocumentPreimage.maximumContentBytes(for: document))
                let path = location.path + "/" + document.rawValue
                if document == .latestLog {
                    let fd = open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
                    try H.check(fd >= 0, "max log fixture descriptor")
                    defer { close(fd) }
                    try bytes.withUnsafeBytes { p in
                        var offset = 0
                        while offset < p.count {
                            let n = pwrite(fd, p.baseAddress!.advanced(by: offset), p.count - offset, off_t(offset))
                            try H.check(n > 0, "max log fixture bytes"); offset += n
                        }
                    }
                    try H.check(ftruncate(fd, off_t(bytes.count)) == 0 && fsync(fd) == 0, "max log fixture durability")
                } else { try write(path, bytes) }
            }
            let started = DispatchTime.now().uptimeNanoseconds
            let proof = try capture(lifecycle, owner, binding)
            let captured = DispatchTime.now().uptimeNanoseconds
            for observation in proof.canonicalPreimages {
                let path = location.path + "/custody/receipts/" + observation.filename
                let reopened = try InstallationDocumentPreimage.CanonicalObservation(decoding: Data(contentsOf: URL(fileURLWithPath: path)), uid: location.uid)
                try H.check(reopened.receipt == observation.receipt, "maximum preimage changed bytes")
            }
            let roundtripped = DispatchTime.now().uptimeNanoseconds
            try proof.revalidate(for: owner)
            let validated = DispatchTime.now().uptimeNanoseconds
            _ = try capture(lifecycle, owner, binding)
            print("CAPTURE_MAX_NS \(captured - started) ROUNDTRIP_MAX_NS \(roundtripped - captured) VALIDATE_MAX_NS \(validated - roundtripped)")
            let target = proof.canonicalPreimages[0]
            let path = location.path + "/custody/receipts/" + target.filename
            let fd = open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            try H.check(fd >= 0, "corrupt retained max preimage")
            var changed: UInt8 = 88
            try H.check(pwrite(fd, &changed, 1, 12) == 1 && fsync(fd) == 0, "write retained corruption"); close(fd)
            try refuses { try proof.revalidate(for: owner) }
        }
    }
    static func unsafeDocuments() throws {
        for attack in ["symlink", "hardlink", "mode", "acl", "oversize"] {
            try fixture { root, location, owner, binding, lifecycle in
                let path = location.path + "/selection-preferences.json"
                if attack == "symlink" {
                    try write(root + "/target", Data("fixture".utf8)); try H.check(symlink(root + "/target", path) == 0, "fixture link")
                } else {
                    try write(path, Data(repeating: 1, count: attack == "oversize" ? InstallationDocumentPreimage.maximumContentBytes(for: .selection) + 1 : 8))
                    if attack == "hardlink" { try H.check(link(path, root + "/alias") == 0, "fixture hardlink") }
                    if attack == "mode" { try H.check(chmod(path, 0o640) == 0, "fixture mode") }
                }
                if attack == "acl" {
                    try InstallationOwnershipFixtures.withACLGrant(path) { try refuses { _ = try capture(lifecycle, owner, binding) } }
                } else { try refuses { _ = try capture(lifecycle, owner, binding) } }
                try H.check(try FileManager.default.contentsOfDirectory(atPath: location.path + "/custody/receipts").isEmpty,
                            "unsafe document published receipt")
            }
        }
    }
    static func sourceAndParentDrift() throws {
        try fixture { _, location, owner, binding, lifecycle in
            let proof = try capture(lifecycle, owner, binding)
            try proof.revalidate(for: owner)
            try write(location.path + "/selection-preferences.json", Data("new fixture bytes".utf8))
            try refuses { try proof.revalidate(for: owner) }
        }
        try fixture { root, _, owner, binding, lifecycle in
            let proof = try capture(lifecycle, owner, binding)
            try proof.revalidate(for: owner)
            let parent = root + "/home/Applications", saved = parent + ".saved"
            try H.check(rename(parent, saved) == 0 && mkdir(parent, 0o700) == 0, "substitute absent-slot parent")
            try refuses { try proof.revalidate(for: owner) }
            try H.check(rmdir(parent) == 0 && rename(saved, parent) == 0, "restore capture parent")
            try proof.revalidate(for: owner)
        }
    }
    static func orphanPreimageAdmission() throws {
        try H.fixture { root, location in
            try TestIsolation.initializeState(at: location)
            var recovery: CustodyAuthorityLeaseSet? = try .retainRecoveryLeases(at: location)
            try CustodyCatalogStore.testingInitialize(leases: recovery!, root: root)
            recovery = nil
            let read = try CustodyAuthorityLeaseSet.retainReadLeases(at: location)
            let store = try CustodyCatalogStore(leases: read)
            func admitted() throws { try store.checkFence(ownRequests: [], scope: RunIdentity.make(), mode: .read) }
            try admitted()
            let control = try InstallationControlRecord.decode(Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json")))
            let log = open(location.path + "/latest.log", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            try H.check(log >= 0, "orphan fixture log"); defer { close(log) }
            var source = stat(); try H.check(fstat(log, &source) == 0, "orphan fixture source identity")
            let node = InstallationNodeIdentity(device: UInt64(source.st_dev), inode: UInt64(source.st_ino), type: .regular,
                uid: source.st_uid, mode: UInt32(source.st_mode), links: UInt64(source.st_nlink),
                aclDigest: CustodyRecordBinding.digest(Data(try PolicyAuthorityFile.privateStateACL(log).utf8)))
            let receipt = InstallationDocumentPreimage(transactionID: control.transaction!.id, slot: .stateDestination,
                document: .latestLog, namespace: control.state.directory, node: node,
                bytes: try Data(contentsOf: URL(fileURLWithPath: location.path + "/latest.log")))
            let bytes = try receipt.encode(uid: location.uid)
            try H.check(try InstallationDocumentPreimage.decode(bytes, uid: location.uid) == receipt, "orphan canonical positive control")
            let path = try location.path + "/custody/receipts/" + receipt.filename(uid: location.uid)
            try write(path, bytes)
            var created = stat(); try H.check(lstat(path, &created) == 0, "orphan fixture receipt identity")
            try refuses { try admitted() }
            var current = stat()
            try H.check(lstat(path, &current) == 0 && FileIdentity(current) == FileIdentity(created)
                && (try Data(contentsOf: URL(fileURLWithPath: path))) == bytes, "orphan receipt changed before removal")
            try H.check(unlink(path) == 0, "remove exact orphan fixture receipt")
            try admitted()
        }
    }
    static func unknownEndpointsAndNames() throws {
        for suffix in ["/state/shadow-sync/host.sock", "/state/shadow-sync/installation.sock",
                       "/home/Applications/.ShadowSync.app.incomplete.00000000-0000-4000-8000-000000000099",
                       "/home/Applications/.ShadowSync.app.quarantine.fixture"] {
            try fixture { root, _, owner, binding, lifecycle in
                try write(root + suffix, Data())
                try refuses { _ = try capture(lifecycle, owner, binding) }
                try H.check(FileManager.default.fileExists(atPath: root + suffix), "orphan evidence deleted")
            }
        }
    }
    static func retainedIdentityAndOwner() throws {
        try fixture { root, location, owner, binding, lifecycle in
            let proof = try capture(lifecycle, owner, binding)
            try fixture { _, _, other, _, _ in
                try refuses { try proof.revalidate(for: other) }
            }
            let saved = proof.canonicalPreimages[0]
            let name = location.path + "/custody/receipts/" + saved.filename
            try H.check(rename(name, root + "/retained-original") == 0, "retain original receipt inode")
            try write(name, saved.bytes)
            // Canonical same bytes and filename are insufficient: the capsule
            // retains the exact fsynced original description and rejects swap.
            try refuses { try proof.revalidate(for: owner) }
            try H.check(try Data(contentsOf: URL(fileURLWithPath: root + "/retained-original")) == saved.bytes,
                        "original preimage bytes changed")
        }
    }
    static func preimageCuts() throws {
        for cut in [CustodyCatalogStore.Fault.beforeSwap, .afterSwap, .afterDirectorySync] {
            try fixture { _, location, owner, binding, lifecycle in
                let source = try Data(contentsOf: URL(fileURLWithPath: location.path + "/latest.log"))
                lifecycle.testingSlotCaptureStoreFault = cut
                try refuses { _ = try capture(lifecycle, owner, binding) }
                try H.check(try Data(contentsOf: URL(fileURLWithPath: location.path + "/latest.log")) == source,
                            "capture fault changed original bytes")
                let store = try CustodyCatalogStore(leases: owner.retainExclusiveLeases())
                try refuses { try store.checkFence(ownRequests: [], scope: RunIdentity.make(), mode: .observation) }
                lifecycle.testingSlotCaptureStoreFault = nil
                _ = try capture(lifecycle, owner, binding)
            }
        }
    }
}
#endif
