#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

/// Registered unauthenticated cases exercise real original journals. Positive
/// cleanup and its cuts require the signed native driver to supply its actual
/// journal/NormalStarted; no fixture can mint the cleanup permit or joined proof.
enum InstallationCoordinationCleanupFixtures {
    typealias H = InstallationStorageFixtures
    typealias J = CustodyCatalogStore.InstallationStagedJournal
    static func closedSessionIsNotPermission() throws {
        try InstallationStagedJournalFixtures.fixture { _, location, _, _, _, journal, _ in
            let deadline = MonotonicDeadline(seconds: 3)
            _ = try journal.completeAdmission(deadline: deadline)
            guard let endpoint = journal.testingEndpoint else { throw H.Failure(message: "cleanup fixture missing endpoint") }
            let original = try endpoint.image
            try journal.closeReadiness(deadline: deadline)
            try endpoint.requireServiceClosed()
            try H.refuses { _ = try journal.takeNormalStarted() }
            try H.check(journal.testingCleanupPermit == nil && journal.cleanupObservation() == .notAttempted
                && endpoint.testingCleanupStage == .untouched && endpoint.testingAcquisitionRetained,
                "service closure minted causal cleanup permission")
            try H.check(try endpoint.image == original, "service closure changed named generation")
            let control = try stored(location, profile: journal.testingValidationProfile)
            try H.check(control.phase == .active && control.readinessCommit == nil,
                        "service closure fabricated durable startup")
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    private static func stored(_ location: StateLocation, profile: InstallationValidationProfile) throws -> InstallationControlRecord {
        try InstallationControlRecord.decode(Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json")), profile: profile)
    }
    /// Run once per freshly authenticated native scenario. This helper is not
    /// counted as a passing synthetic case or registered without its real peers.
    static func authenticatedPositive(_ journal: J, root: String, location: StateLocation) throws {
        let paths = try InstallationPaths.isolated(root: TestIsolation.validateRoot(root))
        guard paths.state.path == location.path, let endpoint = journal.testingEndpoint else {
            throw H.Failure(message: "causal cleanup native prerequisites absent")
        }
        let started = try journal.takeNormalStarted()
        let initial = try stored(location, profile: journal.testingValidationProfile)
        let ownerBytes = try Data(contentsOf: URL(fileURLWithPath: location.path + "/host-owner.json"))
        var ownerBefore = stat(), socketBefore = stat()
        try H.check(lstat(location.path + "/host-owner.json", &ownerBefore) == 0
            && lstat(location.path + "/host.sock", &socketBefore) == 0, "normal host nodes absent")
        var permit: J.CleanupPermit?
        journal.testingCleanupProbe = { actual in
            permit = actual
            try H.check(actual.deadline.absoluteUptimeNanoseconds == started.deadline.absoluteUptimeNanoseconds,
                        "cleanup replaced original readiness clock")
            let intent = try stored(location, profile: journal.testingValidationProfile)
            try H.check(intent.step?.action == .cleanupCoordination && intent.step?.status == .intent
                && intent.readinessCommit == initial.readinessCommit, "cleanup permit preceded durable intent")
            // This is outside the journal's serialized mutation turn. Even the
            // genuine permit cannot authorize an independent caller's action.
            try H.refuses { try actual.validate(endpoint: endpoint, owner: journal.testingOwner) }
            try H.refuses { _ = try journal.cleanupCoordination(after: started) }
        }
        defer { journal.testingCleanupProbe = nil }
        let completed = try journal.cleanupCoordination(after: started)
        var ownerAfter = stat(), socketAfter = stat(), removed = stat()
        try H.check(lstat(location.path + "/installation.sock", &removed) == -1 && errno == ENOENT,
                    "causal cleanup did not remove its fixed endpoint")
        try H.check(lstat(location.path + "/host-owner.json", &ownerAfter) == 0
            && lstat(location.path + "/host.sock", &socketAfter) == 0
            && ownerBefore.st_dev == ownerAfter.st_dev && ownerBefore.st_ino == ownerAfter.st_ino
            && socketBefore.st_dev == socketAfter.st_dev && socketBefore.st_ino == socketAfter.st_ino
            && ownerBytes == (try Data(contentsOf: URL(fileURLWithPath: location.path + "/host-owner.json"))),
                    "cleanup changed the running host's owner/socket")
        try H.check(try stored(location, profile: journal.testingValidationProfile) == completed && completed.readinessCommit == initial.readinessCommit
            && completed.step?.action == .cleanupCoordination && completed.step?.status == .complete
            && completed.revision == initial.revision + 2
            && completed.transaction?.slots.images[.installationSocket]?.node == nil
            && completed.transaction?.slots.images[.hostOwner]?.node?.inode == UInt64(ownerAfter.st_ino)
            && completed.transaction?.slots.images[.hostSocket]?.node?.inode == UInt64(socketAfter.st_ino)
            && endpoint.testingCleanupStage == .complete && !endpoint.testingAcquisitionRetained,
                    "cleanup completion lacked durable exact postimage or retained named custody")
        try H.check(journal.cleanupObservation() == .complete && journal.testingCleanupPermit == nil,
                    "cleanup failed to retire its one-use permit")
        if let permit { try H.refuses { try permit.validate(endpoint: endpoint, owner: journal.testingOwner, completion: true) } }
        else { throw H.Failure(message: "cleanup never minted causal intent permit") }
        try H.refuses { _ = try journal.cleanupCoordination(after: started) }
        try InstallationOwnershipFixtures.excluded(location)
    }
    static func authenticatedEndpointCut(_ journal: J, location: StateLocation,
                                          cut: InstallationReadinessEndpoint.CleanupCut) throws {
        guard let endpoint = journal.testingEndpoint else { throw H.Failure(message: "cut prerequisite absent") }
        let started = try journal.takeNormalStarted()
        endpoint.testingCleanupCut = cut
        try H.refuses { _ = try journal.cleanupCoordination(after: started) }
        let expected: InstallationReadinessEndpoint.CleanupStage
        switch cut {
        case .beforeUnlink, .unlinkFailure: expected = .claimed
        case .afterUnlink, .parentSyncFailure: expected = .unlinked
        case .afterParentSync: expected = .parentSynced
        case .beforeAncestorClose: expected = .absentVerified
        }
        try H.check(endpoint.testingCleanupStage == expected && endpoint.testingAcquisitionRetained
            && journal.cleanupObservation() == .pending, "cleanup cut lost actual causal stage")
        let current = try stored(location, profile: journal.testingValidationProfile)
        try H.check(current.readinessCommit == started.control.readinessCommit,
                    "cleanup cut erased immutable readiness commit")
        try H.refuses { _ = try journal.cleanupCoordination(after: started) }
        try InstallationOwnershipFixtures.excluded(location)
    }
    static func authenticatedCompletionCut(_ journal: J, location: StateLocation,
        failure: J.TestingPublicationFailure) throws {
        guard let endpoint = journal.testingEndpoint else { throw H.Failure(message: "publication cut prerequisite absent") }
        let started = try journal.takeNormalStarted()
        let probe = J.TestingPublicationProbe(action: .cleanupCoordination, status: .complete, failure: failure)
        try journal.testingObservePublication(probe)
        try H.refuses { _ = try journal.cleanupCoordination(after: started) }
        guard let trace = probe.observed else { throw H.Failure(message: "completion cut never reached actual publication") }
        try H.check(trace.before.step?.action == .cleanupCoordination && trace.before.step?.status == .intent
            && trace.after.readinessCommit == started.control.readinessCommit
            && trace.receipt.postimage?.images[.installationSocket]?.node == nil
            && endpoint.testingCleanupStage == .absentVerified && endpoint.testingAcquisitionRetained
            && journal.cleanupObservation() == .pending && journal.testingHasPending,
                    "completion cut converted unlinked pending action into success")
        // Exact pending evidence may be structurally fenced by a persistence
        // cut; do not decode/adopt it as a fresh cleanup authority.
        try H.refuses { _ = try journal.cleanupCoordination(after: started) }
        try InstallationOwnershipFixtures.excluded(location)
    }
    static func authenticatedWrongOwner(_ journal: J, root: String, location: StateLocation) throws {
        guard let endpoint = journal.testingEndpoint else { throw H.Failure(message: "owner cut prerequisite absent") }
        let started = try journal.takeNormalStarted()
        // A separate real original journal owns a different actual endpoint.
        // Its fixture has no ability to mint this transaction's startup event.
        try InstallationStagedJournalFixtures.fixture { _, _, foreignOwner, _, _, foreign, _ in
            _ = try foreign.completeAdmission(deadline: started.deadline)
            guard let foreignEndpoint = foreign.testingEndpoint else { throw H.Failure(message: "foreign endpoint absent") }
            let foreignImage = try foreignEndpoint.image
            journal.testingCleanupProbe = { permit in
                try H.refuses { try permit.validate(endpoint: endpoint, owner: foreignOwner) }
                try H.refuses { try permit.validate(endpoint: foreignEndpoint, owner: journal.testingOwner) }
                try H.check(try foreignEndpoint.image == foreignImage, "foreign permit changed endpoint")
            }
            defer { journal.testingCleanupProbe = nil }
            _ = try journal.cleanupCoordination(after: started)
            try H.check(journal.cleanupObservation() == .complete, "wrong-owner refusal consumed original permit")
            try H.check(try foreignEndpoint.image == foreignImage, "cleanup crossed original endpoint ownership")
        }
        try InstallationOwnershipFixtures.excluded(location)
    }

    static func authenticatedReaderAlias(_ journal: J, root: String, location: StateLocation) throws {
        guard let endpoint = journal.testingEndpoint else { throw H.Failure(message: "reader cut prerequisite absent") }
        let started = try journal.takeNormalStarted()
        let observationDeadline = started.deadline
        let barrier = CustodyLeaseTestingBarrier()
        let custody = try RuntimeFixtureSession.installationRoot(root)
        var work: InstallationFixtureWork?
        defer { barrier.release(); journal.testingCleanupProbe = nil }
        journal.testingCleanupProbe = { _ in
            endpoint.testingPauseNextObservation(at: .beforeValidation, barrier: barrier)
            work = custody.startWork { try endpoint.revalidate(deadline: observationDeadline) }
            try H.check(barrier.waitUntilEntered() && endpoint.testingActiveObservations == 1,
                        "cleanup alias fixture never acquired real observation")
        }
        try H.refuses { _ = try journal.cleanupCoordination(after: started) }
        try H.check(endpoint.testingCleanupStage == .untouched && endpoint.testingAcquisitionRetained
            && journal.cleanupObservation() == .pending && journal.testingMetadataLockAvailable,
                    "active observation authorized unlink or held journal lock across retirement")
        barrier.release()
        // Only fixture teardown receives a separate budget; cleanup cannot be
        // retried or continue under it. Join the actual registered work handle.
        let teardown = MonotonicDeadline(seconds: 3)
        try work?.join(deadline: teardown)
        try journal.closeReadiness(deadline: teardown)
        try H.check(endpoint.testingActiveObservations == 0, "cleanup alias work did not actually join")
        try H.refuses { _ = try journal.cleanupCoordination(after: started) }
        try InstallationOwnershipFixtures.excluded(location)
    }
    /// A fault observes an actual checked close. Darwin.close executes once;
    /// EIO is then injected at the retirement boundary. The product must retain
    /// uncertainty even though this fixture separately knows its FD was closed.
    final class CloseFault: InstallationNamedSocketFixtureCustodyOwner, @unchecked Sendable {
        private let condition = NSCondition()
        private var owner: OwnedFileDescriptor?
        private var attempts = 0
        private var actualClose: Int32?
        func enroll(_ descriptor: OwnedFileDescriptor) {
            condition.lock()
            guard owner == nil else { condition.unlock(); return }
            owner = descriptor
            descriptor.testingClose = { [self] raw in
                let code: Int32 = Darwin.close(raw) == 0 ? 0 : errno
                condition.lock(); attempts += 1; actualClose = code; condition.broadcast(); condition.unlock()
                return code == 0 ? EIO : code
            }
            condition.broadcast(); condition.unlock()
        }
        var descriptor: OwnedFileDescriptor? { condition.lock(); defer { condition.unlock() }; return owner }
        var observed: (attempts: Int, actual: Int32?) {
            condition.lock(); defer { condition.unlock() }; return (attempts, actualClose)
        }
        func wait(deadline: MonotonicDeadline) throws {
            condition.lock(); defer { condition.unlock() }
            while actualClose == nil && !deadline.hasExpired {
                _ = condition.wait(until: Date(timeIntervalSinceNow: min(0.01, Double(deadline.remainingMilliseconds) / 1000)))
            }
            guard attempts == 1, actualClose == 0 else { throw CustodyRecordError.fenced }
        }
        func verify() throws {
            let result = observed
            try H.check(result.attempts == 1 && result.actual == 0
                && descriptor?.value == -1 && descriptor?.retirementObservation == .uncertain(EIO),
                "actual descriptor uncertainty was lost or close was retried")
        }
        func retireNamedSocketFixture(deadline: MonotonicDeadline) throws {
            // This proves only the fixture's native call, never product cleanup.
            // Product owners remain enrolled separately and retain pending state.
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            if let descriptor { try verify(); descriptor.testingClose = nil }
        }
    }
    final class QueueGate: InstallationNamedSocketFixtureCustodyOwner, @unchecked Sendable {
        private let condition = NSCondition()
        private var entered = false, released = false
        private let cutoff: UInt64
        init(deadline: MonotonicDeadline) {
            // Fault lifetime only. No production caller receives this endpoint.
            cutoff = deadline.absoluteUptimeNanoseconds + 3_000_000_000
        }
        func hold() {
            condition.lock(); defer { condition.unlock() }; entered = true; condition.broadcast()
            while !released && DispatchTime.now().uptimeNanoseconds < cutoff {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.01))
            }
        }
        var isHolding: Bool { condition.lock(); defer { condition.unlock() }; return entered && !released }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
        func retireNamedSocketFixture(deadline: MonotonicDeadline) throws { release() }
    }
    private final class Client: InstallationNamedSocketFixtureCustodyOwner {
        private var socketOwner: OwnedFileDescriptor?
        func connect(path: String) throws {
            let raw = socket(AF_UNIX, SOCK_STREAM, 0)
            guard raw >= 0 else { throw CustodyRecordError.persistence(errno) }
            socketOwner = OwnedFileDescriptor(raw)
            try InstallationPrecommitTransport.configure(raw)
            var address = try HostControlIO.address(path: path)
            let result = withUnsafePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(raw, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { throw CustodyRecordError.persistence(errno) }
        }
        func retireNamedSocketFixture(deadline: MonotonicDeadline) throws {
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            if let socketOwner, socketOwner.retireChecked() != .succeeded { throw CustodyRecordError.fenced }
        }
    }
    enum CausalFault: CaseIterable, Equatable { case queueJoin, listenerClose, acceptedClose, extraPeerClose, ancestorClose, controlReplacement }
    @inline(never)
    static func authenticatedStalledJoin(_ journal: J, root: String, location: StateLocation) throws {
        try authenticatedFault(journal, root: root, location: location, fault: .queueJoin)
    }
    @inline(never)
    static func authenticatedListenerClose(_ journal: J, root: String, location: StateLocation) throws {
        try authenticatedFault(journal, root: root, location: location, fault: .listenerClose)
    }
    @inline(never)
    static func authenticatedAcceptedClose(_ journal: J, root: String, location: StateLocation) throws {
        try authenticatedFault(journal, root: root, location: location, fault: .acceptedClose)
    }
    @inline(never)
    static func authenticatedExtraPeerClose(_ journal: J, root: String, location: StateLocation) throws {
        try authenticatedFault(journal, root: root, location: location, fault: .extraPeerClose)
    }
    @inline(never)
    static func authenticatedAncestorClose(_ journal: J, root: String, location: StateLocation) throws {
        try authenticatedFault(journal, root: root, location: location, fault: .ancestorClose)
    }
    @inline(never)
    static func authenticatedControlReplacement(_ journal: J, root: String, location: StateLocation) throws {
        try authenticatedFault(journal, root: root, location: location, fault: .controlReplacement)
    }
    /// Every fault starts with the actual journal's one-use authenticated event.
    /// No helper can synthesize startup, join, a durable write or a permit.
    private static func authenticatedFault(_ journal: J, root: String, location: StateLocation, fault: CausalFault) throws {
        let paths = try InstallationPaths.isolated(root: TestIsolation.validateRoot(root))
        guard paths.state.path == location.path, let endpoint = journal.testingEndpoint,
              let session = journal.testingSession else { throw CustodyRecordError.fenced }
        let started = try journal.takeNormalStarted()
        guard started.session === session else { throw CustodyRecordError.fenced }
        let custody = try RuntimeFixtureSession.installationRoot(root)
        let deadline = started.deadline, originalOwner = journal.testingOwner
        let close = CloseFault(), gate = QueueGate(deadline: deadline), client = Client()
        custody.retainNamedSocket(close); custody.retainNamedSocket(gate); custody.retainNamedSocket(client)
        let controlMutation = NamedMutation(parent: location.path + "/custody", name: "installation.json")
        custody.retainNamedSocket(controlMutation)
        var minted: J.CleanupPermit?, intent: InstallationControlRecord?
        let endpointPath = location.path + "/installation.sock"
        var endpointBefore = stat(), hostOwner = stat(), hostSocket = stat()
        try H.check(lstat(endpointPath, &endpointBefore) == 0
            && lstat(location.path + "/host-owner.json", &hostOwner) == 0
            && lstat(location.path + "/host.sock", &hostSocket) == 0, "actual startup nodes absent")
        let ownerBytes = try Data(contentsOf: URL(fileURLWithPath: location.path + "/host-owner.json"))
        var primary: Error?
        do {
            journal.testingCleanupProbe = { permit in
                minted = permit; intent = try stored(location, profile: journal.testingValidationProfile)
                try H.check(permit.matches(session: session, started: started)
                    && permit.deadline.absoluteUptimeNanoseconds == deadline.absoluteUptimeNanoseconds
                    && intent?.step?.action == .cleanupCoordination && intent?.step?.status == .intent
                    && intent?.readinessCommit == started.control.readinessCommit,
                    "fault was not after this journal's genuine durable permit")
                switch fault {
                case .queueJoin: try session.testingArmCleanupQueue(gate)
                case .listenerClose: close.enroll(try endpoint.testingCleanupDescriptor(ancestor: false))
                case .acceptedClose: try session.testingArmCleanupAccepted(close)
                case .extraPeerClose:
                    try session.testingArmCleanupExtra(close)
                    try client.connect(path: endpointPath)
                    try close.wait(deadline: deadline)
                case .ancestorClose: close.enroll(try endpoint.testingCleanupDescriptor(ancestor: true))
                case .controlReplacement:
                    try controlMutation.capture(); try controlMutation.park(cut: nil)
                    // Identical canonical content on a different actual inode:
                    // only live pinned-generation validation detects this cut.
                    try controlMutation.replace(bytes: Data(contentsOf: URL(fileURLWithPath:
                        location.path + "/custody/.fixture-cleanup-installation.json")), cut: nil)
                }
            }
            try H.refuses { _ = try journal.cleanupCoordination(after: started) }
            guard let minted, let intent else { throw H.Failure(message: "causal fault never reached genuine permit") }
            let actual = try stored(location, profile: journal.testingValidationProfile)
            try H.check(journal.testingOwner === originalOwner && journal.testingCleanupPermit === minted
                && journal.cleanupObservation() == .pending && endpoint.testingAcquisitionRetained
                && endpoint.testingCleanupSharedParentLive && actual.readinessCommit == started.control.readinessCommit
                && session.testingAnchoredDeadline?.absoluteUptimeNanoseconds == deadline.absoluteUptimeNanoseconds,
                "causal fault lost original owner, deadline, permit, immutable commit or named custody")
            if fault == .ancestorClose {
                var absent = stat()
                try H.check(endpoint.testingCleanupStage == .absentVerified
                    && actual.step?.action == .cleanupCoordination && actual.step?.status == .complete
                    && actual.transaction?.slots.images[.installationSocket]?.node == nil
                    && actual.revision >= intent.revision + 1
                    && lstat(endpointPath, &absent) == -1 && errno == ENOENT,
                    "ancestor close uncertainty lost durable completion/actual unlink stage")
            } else {
                var current = stat()
                try H.check(endpoint.testingCleanupStage == .untouched && lstat(endpointPath, &current) == 0
                    && FileIdentity(current).matchesStableNode(FileIdentity(endpointBefore))
                    && actual.step?.action == .cleanupCoordination && actual.step?.status == .intent,
                    "pre-unlink retirement refusal changed endpoint or action stage")
            }
            let pending = session.testingCleanupResources
            switch fault {
            case .queueJoin:
                try H.check(gate.isHolding && !pending.finished && pending.retained
                    && pending.connection != nil && deadline.hasExpired,
                    "cleanup did not time out joining its actual stalled queue on the original deadline")
            case .acceptedClose:
                try close.verify(); try H.check(pending.connection === close.descriptor && pending.retained,
                    "accepted-stream close uncertainty lost original descriptor owner")
            case .extraPeerClose:
                try close.verify(); try H.check(pending.extra === close.descriptor && pending.retained,
                    "extra-peer close uncertainty lost original descriptor owner")
            case .listenerClose, .ancestorClose:
                try close.verify()
                guard let descriptor = close.descriptor else { throw CustodyRecordError.fenced }
                try H.check(endpoint.testingCleanupRetains(descriptor, ancestor: fault == .ancestorClose),
                    "checked-close failure discarded its exact retained endpoint descriptor")
                if fault == .listenerClose {
                    try H.check(pending.finished && pending.retained, "listener uncertainty lost original session retirement owner")
                }
            case .controlReplacement:
                try controlMutation.verifyParked()
                try H.check(actual == intent, "replacement was adopted or overwritten")
            }
            var currentOwner = stat(), currentSocket = stat()
            try H.check(lstat(location.path + "/host-owner.json", &currentOwner) == 0
                && lstat(location.path + "/host.sock", &currentSocket) == 0
                && FileIdentity(currentOwner).matchesStableNode(FileIdentity(hostOwner))
                && FileIdentity(currentSocket).matchesStableNode(FileIdentity(hostSocket))
                && ownerBytes == (try Data(contentsOf: URL(fileURLWithPath: location.path + "/host-owner.json"))),
                "cleanup fault modified actual running-host nodes")
            try H.refuses { _ = try journal.cleanupCoordination(after: started) }
            try H.refuses { try minted.validate(endpoint: endpoint, owner: originalOwner) }
            try InstallationOwnershipFixtures.excluded(location)
        } catch { primary = error }
        journal.testingCleanupProbe = nil; gate.release()
        // A distinct teardown allowance joins work only. It is never supplied to
        // cleanupCoordination or used to retry uncertain numeric descriptors.
        let teardown = MonotonicDeadline(seconds: 3)
        var cleanup: Error?
        do {
            // Cancellation can correctly remain pending on an injected close.
            // Always join the real queue, even when that pending result throws.
            do { try journal.closeReadiness(deadline: teardown) }
            catch {
                if ![CausalFault.listenerClose, .acceptedClose, .extraPeerClose].contains(fault) { cleanup = error }
            }
            try session.testingJoinCleanupQueue(deadline: teardown)
            try client.retireNamedSocketFixture(deadline: teardown)
            try controlMutation.restore()
            if close.descriptor != nil { try close.verify() }
        } catch { cleanup = error }
        if let cleanup { throw TeardownFailure(primary: primary, cleanup: cleanup) }
        if let primary { throw primary }
        // For close-uncertainty cases the registered original product owner is
        // still pending, by design. The signed driver must report that exact
        // retained root; these helpers do not claim successful root retirement.
    }
    @inline(never)
    static func causalPrerequisiteRefusal() throws {
        for fault in CausalFault.allCases {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, _, journal, _ in
                _ = try journal.completeAdmission(deadline: .init(seconds: 3))
                try journal.closeReadiness(deadline: .init(seconds: 3))
                let before = try stored(location, profile: journal.testingValidationProfile)
                try H.refuses {
                    switch fault {
                    case .queueJoin: try authenticatedStalledJoin(journal, root: root, location: location)
                    case .listenerClose: try authenticatedListenerClose(journal, root: root, location: location)
                    case .acceptedClose: try authenticatedAcceptedClose(journal, root: root, location: location)
                    case .extraPeerClose: try authenticatedExtraPeerClose(journal, root: root, location: location)
                    case .ancestorClose: try authenticatedAncestorClose(journal, root: root, location: location)
                    case .controlReplacement: try authenticatedControlReplacement(journal, root: root, location: location)
                    }
                }
                for cut in NamedCut.allCases {
                    try H.refuses { try authenticatedNamedDrift(journal, root: root, location: location,
                        drift: .substituted, cut: cut) }
                }
                try H.check(try stored(location, profile: journal.testingValidationProfile) == before && journal.testingCleanupPermit == nil
                    && journal.cleanupObservation() == .notAttempted, "missing signed startup reached causal fault helper")
            }
        }
    }
    enum NamedDrift { case missing, substituted }
    enum NamedCut: CaseIterable {
        case afterParking, afterReplacementOpen, afterReplacementIdentity, afterReplacementClose, beforeRestore
    }
    /// Enrolled in the root before opening the parent or moving any name. Each
    /// successful syscall changes custody before the next fallible observation.
    private final class NamedMutation: InstallationNamedSocketFixtureCustodyOwner {
        let parentPath: String, name: String, parked: String
        private(set) var parent: OwnedFileDescriptor?
        private var parentNode: FileIdentity?
        private(set) var original: FileIdentity?
        private(set) var replacement: OwnedFileDescriptor?
        private var replacementNode: FileIdentity?
        private(set) var moved = false
        private var replacementCreated = false
        private var restored = false
        private var returnedOriginal = false
        init(parent: String, name: String) {
            parentPath = parent; self.name = name; parked = ".fixture-cleanup-" + name
        }
        func verifyParent() throws {
            guard let parent, let parentNode else { throw CustodyRecordError.fenced }
            var held = stat(), named = stat()
            guard fstat(parent.value, &held) == 0, lstat(parentPath, &named) == 0,
                  FileIdentity(held).matchesStableNode(parentNode),
                  FileIdentity(named).matchesStableNode(parentNode), held.st_flags == 0,
                  held.st_uid == geteuid(), held.st_mode == S_IFDIR | 0o700 else { throw CustodyRecordError.conflict }
            _ = try PolicyAuthorityFile.privateStateACL(parent.value)
        }
        func capture() throws {
            let raw = open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard raw >= 0 else { throw CustodyRecordError.persistence(errno) }
            parent = OwnedFileDescriptor(raw)
            var node = stat()
            guard fstat(raw, &node) == 0 else { throw CustodyRecordError.persistence(errno) }
            parentNode = FileIdentity(node); try verifyParent()
            guard fstatat(raw, name, &node, AT_SYMLINK_NOFOLLOW) == 0, node.st_nlink == 1,
                  node.st_uid == geteuid(), node.st_flags == 0 else { throw CustodyRecordError.conflict }
            original = FileIdentity(node)
            try absent(parked)
        }
        private func absent(_ name: String) throws {
            guard let parent else { throw CustodyRecordError.fenced }
            var node = stat()
            guard fstatat(parent.value, name, &node, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else {
                throw CustodyRecordError.conflict
            }
        }
        private func exact(_ name: String, _ identity: FileIdentity) throws {
            try verifyParent(); var node = stat()
            guard let parent, fstatat(parent.value, name, &node, AT_SYMLINK_NOFOLLOW) == 0,
                  FileIdentity(node).matchesStableNode(identity), node.st_nlink == 1,
                  node.st_flags == 0 else { throw CustodyRecordError.conflict }
        }
        func park(cut: NamedCut?) throws {
            guard let parent, let original, !moved else { throw CustodyRecordError.fenced }
            try exact(name, original); try absent(parked)
            guard renameatx_np(parent.value, name, parent.value, parked, UInt32(RENAME_EXCL)) == 0 else { throw CustodyRecordError.persistence(errno) }
            moved = true
            if cut == .afterParking { throw CustodyRecordError.injectedFailure }
            try exact(parked, original); try absent(name)
        }
        func replace(bytes: Data = Data(), cut: NamedCut?) throws {
            guard moved, let parent else { throw CustodyRecordError.fenced }
            try verifyParent(); try absent(name)
            let raw = openat(parent.value, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard raw >= 0 else { throw CustodyRecordError.persistence(errno) }
            replacement = OwnedFileDescriptor(raw); replacementCreated = true
            if cut == .afterReplacementOpen { throw CustodyRecordError.injectedFailure }
            try captureReplacement()
            if cut == .afterReplacementIdentity { throw CustodyRecordError.injectedFailure }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.write(raw, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw CustodyRecordError.persistence(errno) }; offset += n
                }
            }
            guard fsync(raw) == 0, replacement?.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }
            if cut == .afterReplacementClose { throw CustodyRecordError.injectedFailure }
            guard fsync(parent.value) == 0 else { throw CustodyRecordError.persistence(errno) }
        }
        private func captureReplacement() throws {
            guard let replacement else { throw CustodyRecordError.fenced }
            if replacementNode == nil {
                var node = stat()
                guard fstat(replacement.value, &node) == 0, node.st_nlink == 1,
                      node.st_mode == S_IFREG | 0o600, node.st_uid == geteuid(), node.st_flags == 0 else {
                    throw CustodyRecordError.conflict
                }
                replacementNode = FileIdentity(node)
            }
            try exact(name, replacementNode!)
        }
        func verifyParked() throws {
            guard let original, moved else { throw CustodyRecordError.fenced }; try exact(parked, original)
            if replacementCreated { try captureReplacement() } else { try absent(name) }
        }
        func restore() throws {
            if restored { return }
            guard let parent else { restored = true; return }
            if !moved {
                // A prior restore may have renamed successfully then failed
                // sync/postflight. Keep that actual state and revalidate it.
                if returnedOriginal {
                    try verifyParent(); try exact(name, original!); try absent(parked)
                    guard fsync(parent.value) == 0 else { throw CustodyRecordError.persistence(errno) }
                }
                guard parent.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }
                restored = true; return
            }
            try verifyParked()
            if replacementCreated {
                guard let replacement, replacement.retireChecked() == .succeeded,
                      let replacementNode else { throw CustodyRecordError.fenced }
                try exact(name, replacementNode)
                guard unlinkat(parent.value, name, 0) == 0 else { throw CustodyRecordError.persistence(errno) }
                replacementCreated = false
            }
            try absent(name); try exact(parked, original!)
            guard renameatx_np(parent.value, parked, parent.value, name, UInt32(RENAME_EXCL)) == 0 else { throw CustodyRecordError.persistence(errno) }
            moved = false; returnedOriginal = true
            // Keep post-rename progress, including a failed sync/close, retained.
            guard fsync(parent.value) == 0 else { throw CustodyRecordError.persistence(errno) }
            try exact(name, original!); try absent(parked)
            guard parent.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }
            restored = true
        }
        func retireNamedSocketFixture(deadline: MonotonicDeadline) throws {
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }; try restore()
        }
    }
    private struct TeardownFailure: Error { let primary: Error?; let cleanup: Error }
    private static func withMutation(_ mutation: NamedMutation, root: String,
                                     beforeRestore: () throws -> Void = {}, body: () throws -> Void) throws {
        let custody = try RuntimeFixtureSession.installationRoot(root)
        custody.retainNamedSocket(mutation)
        var primary: Error?
        do { try mutation.capture(); try body() } catch { primary = error }
        do { try beforeRestore(); try mutation.restore() }
        catch { throw TeardownFailure(primary: primary, cleanup: error) }
        if let primary { throw primary }
    }
    @inline(never)
    static func authenticatedNamedDrift(_ journal: J, root: String, location: StateLocation,
                                       drift: NamedDrift, cut: NamedCut? = nil) throws {
        let paths = try InstallationPaths.isolated(root: TestIsolation.validateRoot(root))
        guard paths.state.path == location.path, let endpoint = journal.testingEndpoint,
              let session = journal.testingSession else { throw CustodyRecordError.fenced }
        let started = try journal.takeNormalStarted()
        let mutation = NamedMutation(parent: location.path, name: "installation.sock")
        try withMutation(mutation, root: root, beforeRestore: {
            // Fault/assertion unwinds can precede the production cancel turn.
            // Join the actual original queue before touching either fixture name.
            let teardown = MonotonicDeadline(seconds: 3)
            try journal.closeReadiness(deadline: teardown)
            try session.testingJoinCleanupQueue(deadline: teardown)
        }) {
            journal.testingCleanupProbe = { _ in
                try mutation.park(cut: cut)
                if drift == .substituted { try mutation.replace(cut: cut) }
            }
            defer { journal.testingCleanupProbe = nil }
            try H.refuses { _ = try journal.cleanupCoordination(after: started) }
            try H.check(mutation.moved && endpoint.testingCleanupStage == .untouched && endpoint.testingAcquisitionRetained,
                        "missing/substituted name reached causal unlink")
            try mutation.verifyParked()
            try H.check(try stored(location, profile: journal.testingValidationProfile).readinessCommit == started.control.readinessCommit,
                        "named drift erased immutable commit")
            try H.refuses { _ = try journal.cleanupCoordination(after: started) }
            try InstallationOwnershipFixtures.excluded(location)
            if cut == .beforeRestore { throw CustodyRecordError.injectedFailure }
        }
    }

    /// Real name/descriptor unwind cases, independent of signed startup. They
    /// exercise the same registered custodian as authenticatedNamedDrift.
    @inline(never)
    static func namedMutationUnwind() throws {
        for cut in NamedCut.allCases {
            try H.fixture { root, location in
                let name = location.path + "/installation.sock"
                // An inert fixture node is sufficient to test exception-safe
                // name custody. It grants no endpoint or cleanup authority.
                try Data("fixture original".utf8).write(to: URL(fileURLWithPath: name), options: .withoutOverwriting)
                try H.check(chmod(name, 0o600) == 0, "unwind fixture original mode")
                var before = stat(); try H.check(lstat(name, &before) == 0, "unwind original identity")
                let mutation = NamedMutation(parent: location.path, name: "installation.sock")
                try H.refuses {
                    try withMutation(mutation, root: root) {
                        try mutation.park(cut: cut); try mutation.replace(cut: cut)
                        if cut == .beforeRestore { throw CustodyRecordError.injectedFailure }
                    }
                }
                var after = stat(), missing = stat()
                try H.check(lstat(name, &after) == 0 && FileIdentity(after).matchesStableNode(FileIdentity(before))
                    && lstat(location.path + "/.fixture-cleanup-installation.sock", &missing) == -1 && errno == ENOENT
                    && mutation.parent?.retirementObservation == .succeeded
                    && (mutation.replacement == nil || mutation.replacement?.retirementObservation == .succeeded),
                    "assertion unwind failed to restore exact original or retire owned descriptors")
            }
        }
    }


}
#endif
