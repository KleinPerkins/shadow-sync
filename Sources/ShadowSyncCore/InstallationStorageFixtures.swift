#if SHADOW_SYNC_TESTING
// Disposable metadata/storage fixtures. Synthetic commits establish no installed
// execution, publisher or authenticated staged-readiness evidence.
import Darwin
import Foundation

/// Actual reserved queue ownership for deterministic fixture interleavings.
/// The root retains it through every assertion throw; only group completion
/// proves it joined. It is never counted as a spawned/reaped child.
final class InstallationFixtureWork: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    init() { group.enter() }
    fileprivate func start(_ body: @escaping @Sendable () throws -> Void) {
        DispatchQueue(label: "shadow-sync.installation-fixture-work").async { [self] in
            let value: Result<Void, Error>
            do { try body(); value = .success(()) } catch { value = .failure(error) }
            lock.lock(); result = value; lock.unlock(); group.leave()
        }
    }
    func join(deadline: MonotonicDeadline) throws {
        guard group.wait(timeout: .init(uptimeNanoseconds: deadline.absoluteUptimeNanoseconds)) == .success else {
            throw CustodyRecordError.busy
        }
    }
    func value(deadline: MonotonicDeadline) throws {
        try join(deadline: deadline)
        lock.lock(); let value = result; lock.unlock()
        guard let value else { throw CustodyRecordError.fenced }; try value.get()
    }
}

/// Actual primitive owners registered before fallible socket effects.
protocol InstallationNamedSocketFixtureCustodyOwner: AnyObject {
    func retireNamedSocketFixture(deadline: MonotonicDeadline) throws
}

/// Testing-only outer custody. Failed joins retain these actual owners and the
/// exact root until the case/guardian observes successful independent drainage.
final class InstallationReadinessFixtureCustody: @unchecked Sendable {
    let root: String
    private let identity: FileIdentity
    private let lock = NSLock()
    private var journals: [CustodyCatalogStore.InstallationStagedJournal] = []
    private var work: [InstallationFixtureWork] = []
    private var registries: [RetainedCleanupRegistry] = []
    private var bootstraps: [InstallationBootstrap] = []
    private var namedSockets: [InstallationNamedSocketFixtureCustodyOwner] = []
    init(root: String, identity: FileIdentity) { self.root = root; self.identity = identity }
    func retain(_ journal: CustodyCatalogStore.InstallationStagedJournal) {
        lock.lock(); journals.append(journal); lock.unlock()
    }
    func retain(_ bootstrap: InstallationBootstrap) {
        lock.lock(); bootstraps.append(bootstrap); lock.unlock()
    }
    func retain(_ registry: RetainedCleanupRegistry) {
        lock.lock(); registries.append(registry); lock.unlock()
    }
    func retainNamedSocket(_ owner: InstallationNamedSocketFixtureCustodyOwner) {
        lock.lock(); namedSockets.append(owner); lock.unlock()
    }
    func startWork(_ body: @escaping @Sendable () throws -> Void) -> InstallationFixtureWork {
        let value = InstallationFixtureWork()
        lock.lock(); work.append(value); lock.unlock()
        value.start(body); return value
    }
    func finish(deadline: MonotonicDeadline) throws {
        lock.lock(); let journals = self.journals, work = self.work, registries = self.registries, namedSockets = self.namedSockets; lock.unlock()
        for journal in journals { try journal.closeReadiness(deadline: deadline) }
        for item in work { try item.join(deadline: deadline) }
        for registry in registries {
            guard !registry.hasRetainedWork, registry.testingOriginalHelpersReaped else { throw CustodyRecordError.busy }
        }
        for owner in namedSockets { try owner.retireNamedSocketFixture(deadline: deadline) }
        // Rejoin after other owned calls return: a crossing publication cannot
        // create new work after the earlier cancellation observation.
        for journal in journals { try journal.closeReadiness(deadline: deadline) }
        var current = stat()
        guard lstat(root, &current) == 0, FileIdentity(current).matchesStableNode(identity) else {
            throw CustodyRecordError.conflict
        }
        try FileManager.default.removeItem(atPath: root)
        lock.lock(); self.journals.removeAll(); self.work.removeAll(); self.registries.removeAll(); self.bootstraps.removeAll(); self.namedSockets.removeAll(); lock.unlock()
    }
}

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
        var name = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-ic.") + "XXXXXX").utf8CString)
        let root = try name.withUnsafeMutableBufferPointer { buffer in
            guard let pointer = mkdtemp(buffer.baseAddress) else { throw Failure(message: "fixture root creation") }
            return String(cString: pointer)
        }
        var identity = stat()
        try check(lstat(root, &identity) == 0, "fixture root identity")
        let custody = InstallationReadinessFixtureCustody(root: root, identity: FileIdentity(identity))
        try RuntimeFixtureSession.registerInstallationRoot(custody)
        var failure: Error?
        do {
            try check(mkdir(root + "/state", 0o700) == 0, "fixture state parent")
            try body(root, StateLocation.isolated(root: root))
        } catch { failure = error }
        do {
            try custody.finish(deadline: .init(seconds: 3))
            RuntimeFixtureSession.didFinishInstallationRoot(custody)
        } catch {
            // The outer case retains the actual journal/work/registry and root.
            // No defer removes a live tree or claims a timed-out join succeeded.
            fputs("INSTALLATION FIXTURE ROOT CLEANUP PENDING\n", stderr); fflush(stderr)
            throw error
        }
        if let failure { throw failure }
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
            // Every admission rereads and validates the chain: neither its old
            // digest nor its metadata can survive a changed receipt on disk.
            let receiptBytes = try Data(contentsOf: URL(fileURLWithPath: selected))
            let changed = receiptBytes + Data(" ".utf8)
            try changed.write(to: URL(fileURLWithPath: selected))
            try refuses { try store.checkFence(ownRequests: [], scope: RunIdentity.make(), mode: .read) }
            try receiptBytes.write(to: URL(fileURLWithPath: selected))
            try check(chmod(selected, 0o600) == 0, "restore receipt mode")
            try store.checkFence(ownRequests: [], scope: RunIdentity.make(), mode: .read)
            try check(chmod(selected, 0o644) == 0, "receipt mode drift fixture")
            try refuses { try store.checkFence(ownRequests: [], scope: RunIdentity.make(), mode: .read) }
            try check(chmod(selected, 0o600) == 0, "restore private receipt mode")
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
