#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

// Actual descriptor ownership in disposable state; no publisher or installation
// qualification is inferred from the fixture-only consumed-owner constructor.
enum InstallationOwnershipFixtures {
    typealias H = InstallationStorageFixtures
    static func fixture(_ body: (String, StateLocation, RunAuthority) throws -> Void) throws {
        try H.fixture { root, location in
            var initializer: FreshStateInitialization? = try .testing(root: root)
            _ = try initializer!.publish()
            let original = try initializer!.takeInstallationAuthority()
            initializer = nil
            defer { original.release() }
            try body(root, location, original)
        }
    }
    static func excluded(_ location: StateLocation, name: String = "operation.lock", expected: Bool = true) throws {
        let fd = open(location.path + "/" + name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try H.check(fd >= 0, "open fixture contender")
        defer { close(fd) }
        let result = flock(fd, LOCK_EX | LOCK_NB), code = errno
        try H.check(expected ? result == -1 && code == EWOULDBLOCK : result == 0,
                    "original installation exclusion changed")
        // Closing only this fresh contender never converts/unlocks the owner.
    }
    static func oldAliases() throws {
        try fixture { root, location, original in
            try H.refuses { _ = try original.duplicateOperationLease() }
            try H.refuses { _ = try original.openRetainedLogForWriting() }
            var owner: InstallationTransactionOwner? = try .testingConsume(original, root: root)
            weak var weakOwner = owner
            try H.refuses { _ = try InstallationTransactionOwner.testingConsume(original, root: root) }
            original.release()
            try H.refuses { _ = try original.retainCommandLeases() }
            try H.refuses { _ = try original.retainObservationLeases() }
            try H.refuses { try original.permitStagedHostAdmission() }
            try H.refuses { try original.acquireRetirementNamespace(timeout: 0) }
            try owner!.revalidate()
            for name in ["operation.lock", "lifecycle.lock", "latest.log", "run.lock"] {
                try excluded(location, name: name)
            }
            owner = nil
            try H.check(weakOwner == nil, "consumed owner unexpectedly retained")
            for name in ["operation.lock", "lifecycle.lock", "latest.log", "run.lock"] {
                try excluded(location, name: name, expected: false)
            }
        }
    }
    static func borrowedLifetime() throws {
        try fixture { root, location, original in
            var owner: InstallationTransactionOwner? = try .testingConsume(original, root: root)
            weak var weakOwner = owner
            var lease: CustodyAuthorityLeaseSet? = try owner!.retainExclusiveLeases()
            var descendant: CustodyAuthorityLeaseSet? = try lease!.duplicate()
            owner = nil; original.release(); lease = nil
            try H.check(weakOwner != nil, "descendant lost consumed owner")
            try descendant!.validate(); try excluded(location)
            descendant = nil
            try H.check(weakOwner == nil, "last descendant retained owner")
            try excluded(location, expected: false)
        }
    }
    static func closedBorrowing() throws {
        try fixture { root, location, original in
            var owner: InstallationTransactionOwner? = try .testingConsume(original, root: root)
            weak var weakOwner = owner
            var lease: CustodyAuthorityLeaseSet? = try owner!.retainExclusiveLeases()
            try H.check(try lease!.descriptorClaims().count == 4, "exclusive family role count")
            try H.refuses { _ = try owner!.closeBorrowing() }
            try H.refuses { _ = try owner!.retainExclusiveLeases() }
            lease = nil
            var closed: ClosedInstallationBorrowing? = try owner!.closeBorrowing()
            var retirement: RetainedCleanupRegistry.InstallationRetirement? = try
                RetainedCleanupRegistry.testingInstance().installationRetirement(after: closed!)
            try retirement!.revalidate(for: owner!)
            owner = nil; closed = nil; original.release()
            try H.check(weakOwner != nil, "retirement dropped original owner")
            try excluded(location)
            retirement = nil
            try H.check(weakOwner == nil, "retirement owner leaked")
            try excluded(location, expected: false)
        }
    }
    static func busyTransfer() throws {
        try fixture { root, location, original in
            var lease: CustodyAuthorityLeaseSet? = try original.retainCommandLeases()
            var descendant: CustodyAuthorityLeaseSet? = try lease!.duplicate()
            lease = nil
            try H.refuses { _ = try InstallationTransactionOwner.testingConsume(original, root: root) }
            try H.refuses { _ = try original.retainCommandLeases() }
            try H.refuses { _ = try original.retainObservationLeases() }
            try descendant!.validate(); try excluded(location)
            descendant = nil
            try excluded(location)
            original.release()
            try excluded(location, expected: false)
        }
    }
    static func protectionChanges() throws {
        for relative in ["", "/latest.log", "/lifecycle.lock", "/operation.lock", "/run.lock", "/launcher.lock", "/custody/catalog.lock"] {
            try fixture { root, location, original in
                let path = location.path + relative, old: mode_t = relative.isEmpty ? 0o700 : 0o600
                try H.check(chmod(path, old | 0o040) == 0, "change fixture protection before transfer")
                try H.refuses { _ = try InstallationTransactionOwner.testingConsume(original, root: root) }
                try excluded(location)
                try H.check(chmod(path, old) == 0, "restore fixture protection")
                let owner = try InstallationTransactionOwner.testingConsume(original, root: root)
                let closed = try owner.closeBorrowing()
                let retirement = try RetainedCleanupRegistry.testingInstance().installationRetirement(after: closed)
                try H.check(chmod(path, old | 0o040) == 0, "change fixture protection after closure")
                try H.refuses { try owner.revalidate() }
                try H.refuses { try closed.validate() }
                try H.refuses { try retirement.revalidate(for: owner) }
                try excluded(location)
                try H.check(chmod(path, old) == 0, "restore closed fixture protection")
                try retirement.revalidate(for: owner)
            }
        }
    }
    static func withACLGrant(_ path: String, body: () throws -> Void) throws {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try H.check(fd >= 0, "fixture ACL descriptor")
        defer { close(fd) }
        var acl = acl_init(1)
        defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
        var entry: acl_entry_t?
        try H.check(acl_create_entry(&acl, &entry) == 0 && entry != nil, "fixture ACL entry")
        // An arbitrary fixture UUID suffices: private state rejects every grant,
        // including grants that do not resolve to a local account.
        var uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!.uuid
        try H.check(acl_set_tag_type(entry!, ACL_EXTENDED_ALLOW) == 0
            && acl_set_qualifier(entry!, &uuid) == 0, "fixture ACL qualifier")
        var permissions: acl_permset_t?
        try H.check(acl_get_permset(entry!, &permissions) == 0 && permissions != nil, "fixture ACL permissions")
        try H.check(acl_add_perm(permissions!, ACL_READ_DATA) == 0
            && acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0, "fixture ACL grant")
        // This entire node belongs to the disposable fixture. Keep the grant
        // present through every refusal and remove it before fixture cleanup.
        defer {
            if let empty = acl_init(0) {
                _ = acl_set_fd_np(fd, empty, ACL_TYPE_EXTENDED)
                acl_free(UnsafeMutableRawPointer(empty))
            }
        }
        try body()
    }
    static func aclChanges() throws {
        for relative in ["", "/latest.log", "/lifecycle.lock", "/operation.lock", "/run.lock", "/launcher.lock", "/custody/catalog.lock"] {
            for after in [false, true] {
                try fixture { root, location, original in
                    let owner = try after ? InstallationTransactionOwner.testingConsume(original, root: root) : nil
                    let closed = try owner?.closeBorrowing()
                    let registry = RetainedCleanupRegistry.testingInstance()
                    let retirement = try closed.map { try registry.installationRetirement(after: $0) }
                    try withACLGrant(location.path + relative) {
                        if let owner, let closed, let retirement {
                            try H.refuses { try owner.revalidate() }
                            try H.refuses { try closed.validate() }
                            try H.refuses { try retirement.revalidate(for: owner) }
                        } else {
                            try H.refuses { _ = try InstallationTransactionOwner.testingConsume(original, root: root) }
                        }
                        try excluded(location)
                    }
                }
            }
        }
    }
    static func stateReplacement() throws {
        try fixture { root, location, original in
            let owner = try InstallationTransactionOwner.testingConsume(original, root: root)
            let closed = try owner.closeBorrowing()
            let saved = location.path + ".saved"
            try H.check(rename(location.path, saved) == 0 && mkdir(location.path, 0o700) == 0, "replace fixture state")
            try H.refuses { try owner.revalidate() }
            try H.refuses { try closed.validate() }
            try H.check(rmdir(location.path) == 0 && rename(saved, location.path) == 0, "restore original state")
            try excluded(location); try closed.validate()
        }
    }
    static func wrongOwner() throws {
        try fixture { root, _, original in
            let owner = try InstallationTransactionOwner.testingConsume(original, root: root)
            let closed = try owner.closeBorrowing()
            let retirement = try RetainedCleanupRegistry.testingInstance().installationRetirement(after: closed)
            try fixture { otherRoot, _, otherOriginal in
                let other = try InstallationTransactionOwner.testingConsume(otherOriginal, root: otherRoot)
                try H.refuses { try retirement.revalidate(for: other) }
                try H.check(!closed.belongs(to: other), "closed owner capsule was transferable")
                try retirement.revalidate(for: owner)
            }
        }
    }
    static func bindingSource(_ root: String, _ original: RunAuthority) throws -> InstallationBindingTestingSource {
        let candidate = try InstallationControlFixtures.transaction().candidate!
        let process = ProcessIdentity(processID: 400, processGroupID: 401, userID: original.stateDirectory.uid,
            startSeconds: 1, startMicroseconds: 2, executablePath: "/fixture/ShadowSync.app/Contents/Helpers/ShadowSyncLifecycleCoordinator",
            generation: InstallationControlFixtures.generation)
        return try InstallationBindingTestingSource(root: root, candidate: candidate,
            process: process, boot: InstallationControlFixtures.boot)
    }
    static func liveBindingStable() throws {
        try fixture { root, location, original in
            var owner: InstallationTransactionOwner? = try .testingConsume(original, root: root)
            weak var weakOwner = owner
            let source = try bindingSource(root, original)
            try owner!.testingSetBindingSource(source)
            var first: InstallationLiveBinding? = try owner!.installationBinding()
            do {
                let again = try owner!.installationBinding()
                try first!.revalidate(for: owner!); try again.revalidate(for: owner!)
                try H.check(first!.coordinator == again.coordinator && first!.candidate == again.candidate
                    && first!.state == again.state && first!.boot == again.boot
                    && first!.sourceReleaseDigest == again.sourceReleaseDigest, "binding changed on repeated use")
                try H.check(first!.coordinator.process.generation == source.process.generation,
                    "coordinator generation changed")
                try first!.coordinator.validate(uid: original.stateDirectory.uid); try first!.state.validate()
                try H.refuses { try owner!.testingSetBindingSource(source) }
            }
            original.release(); owner = nil
            try H.check(weakOwner != nil, "live evidence lost consumed owner")
            try excluded(location)
            first = nil
            try H.check(weakOwner == nil, "live evidence retained owner after last reference")
            try excluded(location, expected: false)
        }
    }
    static func liveBindingMismatch() throws {
        try fixture { root, _, original in
            let owner = try InstallationTransactionOwner.testingConsume(original, root: root)
            try H.refuses { _ = try owner.installationBinding() }
            let source = try bindingSource(root, original)
            try owner.testingSetBindingSource(source)
            let binding = try owner.installationBinding()
            try fixture { otherRoot, _, otherOriginal in
                let other = try InstallationTransactionOwner.testingConsume(otherOriginal, root: otherRoot)
                let otherSource = try bindingSource(otherRoot, otherOriginal)
                try H.refuses { try other.testingSetBindingSource(source) }
                try other.testingSetBindingSource(otherSource)
                _ = try other.installationBinding()
                try H.refuses { try binding.revalidate(for: other) }
                // Same bytes under another fixture source still cannot rebind.
                source.identity = otherSource.identity
                try H.refuses { try binding.revalidate(for: owner) }
                source.identity = try LifecyclePublisher.InstallationIdentity.testing(root: root, candidate: binding.candidate)
                try binding.revalidate(for: owner)
            }
        }
    }
    static func liveBindingDrift() throws {
        for change in ["boot", "pid", "start", "group", "uid", "path", "generation", "bundle", "app", "helper", "release", "unavailable"] {
            try fixture { root, location, original in
                let owner = try InstallationTransactionOwner.testingConsume(original, root: root)
                let source = try bindingSource(root, original)
                try owner.testingSetBindingSource(source)
                let binding = try owner.installationBinding(), p = source.process, c = binding.candidate
                if change == "boot" { source.boot = InstallationControlFixtures.uuid }
                else if change == "unavailable" { source.available = false }
                else if ["bundle", "app", "helper", "release"].contains(change) {
                    let release = try change == "release" ? ReleaseIdentity(sourceRevision: String(repeating: "e", count: 40),
                        sourceInputSHA256: c.release.sourceInputSHA256,
                        releaseContractSHA256: InstallationControlFixtures.sha, architecture: "arm64", buildMode: "production") : c.release
                    let candidate = InstallationCandidate(release: release,
                        bundleDigest: change == "bundle" ? InstallationControlFixtures.otherSHA : c.bundleDigest,
                        appCDHash: change == "app" ? String(repeating: "d", count: 40) : c.appCDHash,
                        coordinatorCDHash: change == "helper" ? String(repeating: "e", count: 40) : c.coordinatorCDHash)
                    source.identity = try LifecyclePublisher.InstallationIdentity.testing(root: root, candidate: candidate)
                } else {
                    source.process = ProcessIdentity(processID: change == "pid" ? p.processID + 1 : p.processID,
                        processGroupID: change == "group" ? p.processGroupID + 1 : p.processGroupID,
                        userID: change == "uid" ? p.userID + 1 : p.userID,
                        startSeconds: change == "start" ? p.startSeconds + 1 : p.startSeconds,
                        startMicroseconds: p.startMicroseconds,
                        executablePath: change == "path" ? "/fixture/other-coordinator" : p.executablePath,
                        generation: change == "generation" ? InstallationControlFixtures.uuid : p.generation)
                }
                try H.refuses { try binding.revalidate(for: owner) }
                try H.refuses { try owner.revalidate() }
                try H.refuses { _ = try owner.installationBinding() }
                try excluded(location)
                source.boot = binding.boot; source.process = p; source.available = true
                source.identity = try LifecyclePublisher.InstallationIdentity.testing(root: root, candidate: c)
                try binding.revalidate(for: owner)
            }
        }
    }
    static func liveBindingStateDrift() throws {
        try fixture { root, location, original in
            let owner = try InstallationTransactionOwner.testingConsume(original, root: root)
            try owner.testingSetBindingSource(bindingSource(root, original))
            let binding = try owner.installationBinding()
            for relative in ["", "/operation.lock", "/custody/catalog.lock"] {
                let path = location.path + relative, mode: mode_t = relative.isEmpty ? 0o700 : 0o600
                try H.check(chmod(path, mode | 0o040) == 0, "change bound state protection")
                try H.refuses { try binding.revalidate(for: owner) }
                try H.refuses { _ = try owner.installationBinding() }
                try H.check(chmod(path, mode) == 0, "restore bound state protection")
                try binding.revalidate(for: owner)
            }
            let saved = location.path + ".binding-saved"
            try H.check(rename(location.path, saved) == 0 && mkdir(location.path, 0o700) == 0, "replace bound state")
            try H.refuses { try binding.revalidate(for: owner) }
            try H.check(rmdir(location.path) == 0 && rename(saved, location.path) == 0, "restore bound state")
            try binding.revalidate(for: owner); try excluded(location)
        }
    }

}
#endif
