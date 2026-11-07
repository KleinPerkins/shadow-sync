#if SHADOW_SYNC_TESTING
// Disposable metadata/storage fixtures. Synthetic commits establish no installed
// execution, publisher or authenticated staged-readiness evidence.
import Darwin
import Foundation

enum InstallationStorageFixtures {
    struct Failure: Error { let message: String }
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    static func refuses(_ body: () throws -> Void) throws {
        do { try body() }
        catch is CustodyRecordError { return }
        catch is InstallationRecordError { return }
        catch is SecureStateError { return }
        catch is PolicyAuthorityFileError { return }
        throw Failure(message: "unexpected installation metadata acceptance")
    }
    static func fixture(_ body: (String, StateLocation) throws -> Void) throws {
        var name = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-custody-catalog.") + "XXXXXX").utf8CString)
        guard let pointer = mkdtemp(&name) else { throw Failure(message: "fixture root creation") }
        let root = String(cString: pointer)
        var identity = stat()
        try check(lstat(root, &identity) == 0, "fixture root identity")
        defer {
            var current = stat()
            if lstat(root, &current) == 0, FileIdentity(current).matchesStableNode(FileIdentity(identity)) {
                try? FileManager.default.removeItem(atPath: root)
            }
        }
        try check(mkdir(root + "/state", 0o700) == 0, "fixture state parent")
        try body(root, StateLocation.isolated(root: root))
    }
    static func initial() throws {
        try fixture { root, location in
            var initializer: FreshStateInitialization? = try .testing(root: root)
            let result = try initializer!.publish()
            try check(try initializer!.publish() == result, "same-object publication retry")
            initializer = nil
            do {
                let leases = try CustodyAuthorityLeaseSet.retainReadLeases(at: location)
                let store = try CustodyCatalogStore(leases: leases)
                try refuses { try store.checkFence(ownRequests: [], scope: RunIdentity.make(), mode: .read) }
            }
            let owner = try LifecycleAdmissionAuthority.acquire(at: location)
            defer { owner.release() }
            let store = try CustodyCatalogStore(leases: owner.retainObservationLeases())
            try refuses { try store.checkFence(ownRequests: [], scope: RunIdentity.make(), mode: .observation) }
        }
    }
    static func committed() throws {
        try fixture { root, location in
            try TestIsolation.initializeState(at: location)
            var leases: CustodyAuthorityLeaseSet? = try .retainRecoveryLeases(at: location)
            try CustodyCatalogStore.testingInitialize(leases: leases!, root: root)
            leases = nil
            let read = try CustodyAuthorityLeaseSet.retainReadLeases(at: location)
            let store = try CustodyCatalogStore(leases: read)
            let start = DispatchTime.now().uptimeNanoseconds
            try store.checkFence(ownRequests: [], scope: RunIdentity.make(), mode: .read)
            try check(DispatchTime.now().uptimeNanoseconds - start < 750_000_000,
                      "committed metadata exceeded caller deadline")
            let path = location.path + "/custody/installation.json"
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            try check(unlink(path) == 0, "missing control fixture")
            try refuses { try store.checkFence(ownRequests: [], scope: RunIdentity.make(), mode: .read) }
            try bytes.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
            try check(chmod(path, 0o600) == 0, "restored fixture control mode")
            try store.checkFence(ownRequests: [], scope: RunIdentity.make(), mode: .read)
            let receipts = location.path + "/custody/receipts"
            let names = try FileManager.default.contentsOfDirectory(atPath: receipts)
            try check(names.count == 40, "complete fixture chain count")
            let selected = receipts + "/" + names.sorted().first!, saved = root + "/saved"
            try check(rename(selected, saved) == 0, "missing step receipt fixture")
            try refuses { try store.checkFence(ownRequests: [], scope: RunIdentity.make(), mode: .read) }
            try check(rename(saved, selected) == 0, "restore exact fixture receipt")
            try store.checkFence(ownRequests: [], scope: RunIdentity.make(), mode: .read)
        }
    }
    static func publishedReplacement() throws {
        try fixture { root, location in
            let owner = try FreshStateInitialization.testing(root: root)
            _ = try owner.publish()
            let path = location.path + "/custody/installation.json", saved = root + "/saved"
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            try check(rename(path, saved) == 0, "preserve original fixture control")
            try bytes.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
            try check(chmod(path, 0o600) == 0, "replacement fixture control mode")
            try refuses { _ = try owner.publish() }
            try refuses { _ = try owner.takeInstallationAuthority() }
        }
    }
    static func writeCuts() throws {
        for partial in [false, true] {
            try fixture { root, location in
                var owner: FreshStateInitialization? = try .testing(root: root)
                owner!.testingFault(partial ? .partialWrite("installation.json") : .temporaryCreated("installation.json"))
                try refuses { _ = try owner!.publish() }
                owner = nil
                let next = try FreshStateInitialization.testing(root: root)
                _ = try next.publish()
                try check(FileManager.default.fileExists(atPath: location.path + "/custody/installation.json"),
                          "resumed publication omitted control")
            }
        }
    }
}
#endif
