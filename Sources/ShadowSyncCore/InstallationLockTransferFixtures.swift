#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

// Exercise actual one-way descriptor changes in fresh fixture-only state. The
// preparation helper runs custody diagnostics, releases journal/store/capture
// aliases, and yields its actual registry. No installed host or startup is used.
enum InstallationLockTransferFixtures {
    typealias H = InstallationStorageFixtures
    typealias P = InstallationExclusivePreparationFixtures
    typealias I = CustodyCatalogStore.InstallationStagedAdmissionIntent
    typealias R = RetainedCleanupRegistry.InstallationRetirement
    private static func retired(_ owner: InstallationTransactionOwner, _ registry: RetainedCleanupRegistry) throws -> R {
        try H.check(!registry.hasRetainedWork && registry.testingCount == 0 && registry.testingOriginalHelpersReaped,
                    "installation transfer requires actual registry removal")
        return try registry.installationRetirement(after: owner.closeBorrowing())
    }
    private static func shared(_ location: StateLocation, _ name: String, succeeds: Bool) throws {
        let fd = open(location.path + "/" + name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try H.check(fd >= 0, "transfer shared probe open"); defer { close(fd) }
        let result = flock(fd, LOCK_SH | LOCK_NB), code = errno
        try H.check(succeeds ? result == 0 : result == -1 && code == EWOULDBLOCK,
                    "transfer shared probe result")
    }
    private static func fence(_ location: StateLocation) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json"))
    }
    private static func verifyStaged(_ owner: InstallationTransactionOwner, _ staged: InstallationStagedAdmission,
                                     _ location: StateLocation, before: Data) throws {
        try staged.revalidate(); try owner.revalidate()
        for name in ["latest.log", "lifecycle.lock"] {
            try shared(location, name, succeeds: true)
            try InstallationOwnershipFixtures.excluded(location, name: name)
        }
        try InstallationOwnershipFixtures.excluded(location)
        try shared(location, "operation.lock", succeeds: false)
        try InstallationOwnershipFixtures.excluded(location, name: "run.lock", expected: false)
        try H.check(try fence(location) == before, "lock transfer altered durable fence")
        try H.refuses { _ = try owner.retainExclusiveLeases() }
        try H.refuses { _ = try owner.closeBorrowing() }
        try H.refuses { _ = try owner.installationSourceBundle() }
    }
    static func positiveAndRepeated() throws {
        try P.withPreparedIntent { _, location, owner, intent, registry in
            let proof = try retired(owner, registry), before = try fence(location)
            try shared(location, "lifecycle.lock", succeeds: false)
            let staged = try owner.transferToStagedAdmission(intent: intent, after: proof, deadline: .init(seconds: 3))
            try verifyStaged(owner, staged, location, before: before)
            try H.refuses { _ = try owner.transferToStagedAdmission(intent: intent, after: proof, deadline: .init(seconds: 3)) }
            try verifyStaged(owner, staged, location, before: before)
        }
    }
    static func publicationAliases() throws {
        try RunAuthority.testingPublicationCapture.arm()
        defer { RunAuthority.testingPublicationCapture.clear() }
        try P.withPreparedIntent { _, location, owner, intent, registry in
            var aliases: (CustodyAuthorityLeaseSet, CustodyAuthorityLeaseSet)? = try RunAuthority.testingPublicationCapture.take()
            var root: CustodyAuthorityLeaseSet? = aliases!.0
            var descendant: CustodyAuthorityLeaseSet? = aliases!.1
            aliases = nil
            weak var actualRoot = root
            let proof = try retired(owner, registry), before = try fence(location)
            // Consumption closed the real initializer family, including every
            // existing descendant's ability to duplicate or create spawn actions.
            try H.refuses { _ = try root!.duplicate() }
            try H.refuses { _ = try descendant!.duplicate() }
            try H.refuses { _ = try owner.transferToStagedAdmission(intent: intent, after: proof, deadline: .init(seconds: 3)) }
            root = nil
            try H.check(actualRoot != nil, "publication root lost live descendant")
            try H.refuses { _ = try owner.transferToStagedAdmission(intent: intent, after: proof, deadline: .init(seconds: 3)) }
            try InstallationOwnershipFixtures.excluded(location)
            try shared(location, "lifecycle.lock", succeeds: false)
            descendant = nil
            try H.check(actualRoot == nil, "publication root descriptions still live")
            let staged = try owner.transferToStagedAdmission(intent: intent, after: proof, deadline: .init(seconds: 3))
            try verifyStaged(owner, staged, location, before: before)
        }
    }
    static func borrowedAliases() throws {
        try P.withPreparedIntent { _, location, owner, intent, registry in
            var root: CustodyAuthorityLeaseSet? = try owner.retainExclusiveLeases()
            var descendant: CustodyAuthorityLeaseSet? = try root!.duplicate()
            weak var actualRoot = root
            try H.refuses { _ = try owner.closeBorrowing() }
            try H.refuses { _ = try root!.duplicate() }
            try H.refuses { _ = try descendant!.duplicate() }
            root = nil
            try H.check(actualRoot != nil, "borrow root lost descendant")
            try H.refuses { _ = try owner.closeBorrowing() }
            try InstallationOwnershipFixtures.excluded(location)
            descendant = nil
            try H.check(actualRoot == nil, "borrow root did not retire")
            let proof = try retired(owner, registry), before = try fence(location)
            let staged = try owner.transferToStagedAdmission(intent: intent, after: proof, deadline: .init(seconds: 3))
            try verifyStaged(owner, staged, location, before: before)
        }
    }
    static func wrongProofsAndDeadline() throws {
        try P.withPreparedIntent { _, location, owner, intent, registry in
            let proof = try retired(owner, registry), before = try fence(location)
            try P.withPreparedIntent { _, otherLocation, other, otherIntent, otherRegistry in
                try H.refuses { _ = try other.transferToStagedAdmission(intent: intent, after: proof, deadline: .init(seconds: 3)) }
                try H.check(!other.commandAdmissionIsOpen, "wrong proof left borrowing open")
                let otherProof = try retired(other, otherRegistry)
                try H.refuses { _ = try owner.transferToStagedAdmission(intent: otherIntent, after: proof, deadline: .init(seconds: 3)) }
                try H.refuses { _ = try owner.transferToStagedAdmission(intent: intent, after: otherProof, deadline: .init(seconds: 3)) }
                try H.refuses { _ = try owner.transferToStagedAdmission(intent: intent, after: proof, deadline: .init(seconds: 0)) }
                try InstallationOwnershipFixtures.excluded(location)
                try InstallationOwnershipFixtures.excluded(otherLocation)
                try shared(location, "lifecycle.lock", succeeds: false)
            }
            let staged = try owner.transferToStagedAdmission(intent: intent, after: proof, deadline: .init(seconds: 3))
            try verifyStaged(owner, staged, location, before: before)
        }
    }
    // Inline one-shot observation at the exact admission boundary. No worker,
    // group or timed join exists: root cleanup can only run after transfer returns.
    private static func atGap(_ owner: InstallationTransactionOwner, _ intent: I, _ proof: R,
                              afterAcquisition: Bool = false,
                              deadline: MonotonicDeadline = .init(seconds: 3),
                              _ body: @escaping () throws -> Void) throws -> Result<InstallationStagedAdmission, Error> {
        var entered = false
        let observation = { entered = true; try body() }
        if afterAcquisition { owner.testingObserveAdmissionPostflight(observation) }
        else { owner.testingObserveAdmissionTransfer(observation) }
        defer {
            // Also remove an uninvoked hook if preflight refused. This breaks any
            // fixture capture cycle without manufacturing transfer completion.
            owner.testingObserveAdmissionPostflight(nil)
            owner.testingObserveAdmissionTransfer(nil)
        }
        let result = Result { try owner.transferToStagedAdmission(intent: intent, after: proof, deadline: deadline) }
        try H.check(entered, "testingObserveAdmissionTransfer/testingObserveAdmissionPostflight: transfer never reached exact observation boundary")
        return result
    }
    static func synchronousDeadlineCleanup() throws {
        var retainedRoot: String?
        var observationReturned = false, transferReturned = false
        try P.withPreparedIntent { root, location, owner, intent, registry in
            retainedRoot = root
            let proof = try retired(owner, registry), before = try fence(location)
            let deadline = MonotonicDeadline(seconds: 3)
            let result = try atGap(owner, intent, proof, deadline: deadline) {
                var actual = stat()
                try H.check(!transferReturned && lstat(root, &actual) == 0,
                            "fixture root cleaned before inline observation completed")
                // Consume only this transfer's existing absolute budget. There is
                // no fresh wait/cleanup allowance and no background completion.
                while !deadline.hasExpired {
                    usleep(UInt32(min(10, deadline.remainingMilliseconds)) * 1_000)
                }
                try H.check(lstat(root, &actual) == 0, "expired observation lost fixture root")
                try InstallationOwnershipFixtures.excluded(location)
                observationReturned = true
            }
            transferReturned = true
            try H.check(observationReturned && deadline.hasExpired,
                        "deadline failure preceded inline completion")
            try H.refuses { _ = try result.get() }
            try InstallationOwnershipFixtures.excluded(location)
            try H.check(try fence(location) == before, "deadline failure changed fence")
            for name in ["latest.log", "lifecycle.lock", "run.lock"] {
                try InstallationOwnershipFixtures.excluded(location, name: name, expected: false)
            }
            try H.refuses { _ = try owner.transferToStagedAdmission(intent: intent, after: proof, deadline: .init(seconds: 3)) }
        }
        var remaining = stat()
        try H.check(observationReturned && transferReturned && retainedRoot != nil,
                    "synchronous deadline fixture did not complete")
        try H.check(lstat(retainedRoot!, &remaining) == -1 && errno == ENOENT,
                    "joined synchronous fixture root was not cleaned")
    }
    static func contentionAndContinuity() throws {
        for name in ["latest.log", "lifecycle.lock"] {
            try P.withPreparedIntent { _, location, owner, intent, registry in
                let proof = try retired(owner, registry), before = try fence(location)
                var contender: Int32 = -1
                defer { if contender >= 0 { close(contender) } }
                let result = try atGap(owner, intent, proof) {
                    // Owner, registry and durable evidence remain callable here:
                    // no enclosing mutex/catalog guard survives into the gap.
                    try owner.revalidate(); try proof.revalidate(for: owner)
                    try intent.revalidate(for: owner, deadline: .init(seconds: 3))
                    try InstallationOwnershipFixtures.excluded(location)
                    try shared(location, "operation.lock", succeeds: false)
                    contender = open(location.path + "/" + name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                    try H.check(contender >= 0 && flock(contender, LOCK_EX | LOCK_NB) == 0, "close-last did not release admission")
                }
                try H.refuses { _ = try result.get() }
                close(contender); contender = -1
                try InstallationOwnershipFixtures.excluded(location)
                try H.check(try fence(location) == before, "contention changed durable fence")
                // Both fresh temporary descriptions were released; the old EX
                // descriptions were not reconstructed and a retry is forbidden.
                for admission in ["latest.log", "lifecycle.lock", "run.lock"] {
                    try InstallationOwnershipFixtures.excluded(location, name: admission, expected: false)
                }
                try H.refuses { _ = try owner.transferToStagedAdmission(intent: intent, after: proof, deadline: .init(seconds: 3)) }
                try H.refuses { _ = try owner.retainExclusiveLeases() }
            }
        }
    }
    private static func write(_ path: String, _ bytes: Data = Data()) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try H.check(fd >= 0, "transfer fixture replacement create"); defer { close(fd) }
        try bytes.withUnsafeBytes { data in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, data.baseAddress!.advanced(by: offset), data.count - offset)
                try H.check(count > 0, "transfer fixture replacement write"); offset += count
            }
        }
        try H.check(fsync(fd) == 0, "transfer fixture replacement sync")
    }
    static func substitutionAtGap() throws {
        for name in ["latest.log", "lifecycle.lock", "operation.lock"] {
            try P.withPreparedIntent { root, location, owner, intent, registry in
                let proof = try retired(owner, registry), before = try fence(location)
                let path = location.path + "/" + name, retained = root + "/retained-original-lock"
                var displaced = false
                defer { if displaced { _ = unlink(path); _ = rename(retained, path) } }
                let result = try atGap(owner, intent, proof) {
                    try H.check(rename(path, retained) == 0, "transfer fixture displacement")
                    displaced = true; try write(path)
                }
                try H.refuses { _ = try result.get() }
                try H.check(unlink(path) == 0 && rename(retained, path) == 0, "transfer fixture restore exact inode")
                displaced = false
                try InstallationOwnershipFixtures.excluded(location)
                try H.check(try fence(location) == before, "substitution changed durable fence")
                try H.refuses { _ = try owner.transferToStagedAdmission(intent: intent, after: proof, deadline: .init(seconds: 3)) }
                for admission in ["latest.log", "lifecycle.lock", "run.lock"] {
                    try InstallationOwnershipFixtures.excluded(location, name: admission, expected: false)
                }
            }
        }
    }
    static func postflightFailure() throws {
        try P.withPreparedIntent { root, location, owner, intent, registry in
            let proof = try retired(owner, registry), before = try fence(location)
            let path = location.path + "/custody/installation.json", retained = root + "/retained-postflight-control"
            var displaced = false
            defer { if displaced { _ = unlink(path); _ = rename(retained, path) } }
            let result = try atGap(owner, intent, proof, afterAcquisition: true) {
                try shared(location, "latest.log", succeeds: true)
                try shared(location, "lifecycle.lock", succeeds: true)
                try InstallationOwnershipFixtures.excluded(location)
                try H.check(rename(path, retained) == 0, "postflight control displacement")
                displaced = true; try write(path, before)
            }
            try H.refuses { _ = try result.get() }
            try H.check(unlink(path) == 0 && rename(retained, path) == 0, "postflight restore exact control")
            displaced = false
            try InstallationOwnershipFixtures.excluded(location)
            try H.check(try fence(location) == before, "postflight failure changed fence")
            for name in ["latest.log", "lifecycle.lock", "run.lock"] {
                try InstallationOwnershipFixtures.excluded(location, name: name, expected: false)
            }
            try H.refuses { _ = try owner.transferToStagedAdmission(intent: intent, after: proof, deadline: .init(seconds: 3)) }
        }
    }
    static func staleIntentAndProtection() throws {
        try P.withPreparedIntent { root, location, owner, intent, registry in
            let proof = try retired(owner, registry), before = try fence(location)
            let path = location.path + "/custody/installation.json", retained = root + "/retained-control"
            try H.check(rename(path, retained) == 0, "transfer control displacement")
            var displaced = true
            defer { if displaced { _ = unlink(path); _ = rename(retained, path) } }
            try write(path, before)
            try H.refuses { _ = try owner.transferToStagedAdmission(intent: intent, after: proof, deadline: .init(seconds: 3)) }
            try shared(location, "lifecycle.lock", succeeds: false)
            try H.check(unlink(path) == 0 && rename(retained, path) == 0, "transfer restore control")
            displaced = false
            for name in ["latest.log", "lifecycle.lock", "operation.lock", "run.lock", "launcher.lock", "custody/catalog.lock"] {
                let node = location.path + "/" + name
                try H.check(chmod(node, 0o640) == 0, "transfer fixture permission change")
                do {
                    defer { _ = chmod(node, 0o600) }
                    try H.refuses { _ = try owner.transferToStagedAdmission(intent: intent, after: proof, deadline: .init(seconds: 3)) }
                }
                try InstallationOwnershipFixtures.withACLGrant(node) {
                    try H.refuses { _ = try owner.transferToStagedAdmission(intent: intent, after: proof, deadline: .init(seconds: 3)) }
                }
            }
            let staged = try owner.transferToStagedAdmission(intent: intent, after: proof, deadline: .init(seconds: 3))
            try verifyStaged(owner, staged, location, before: before)
        }
    }
}
#endif
