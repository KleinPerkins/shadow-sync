#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

/// Runtime mechanism fixtures. None fabricate an authenticated server, peer,
/// normal-started observation or native success. Signed positives remain gated.
enum InstallationStartupFixtures {
    typealias H = InstallationStorageFixtures
    typealias P = InstallationPrecommitFixtures
    private static func transcript() throws -> InstallationStartupTranscript {
        try InstallationStartupTranscript(commit: InstallationReadinessWireFixtures.message(.commit))
    }
    static func ordering() throws {
        let deadline = MonotonicDeadline(seconds: 3)
        var value = try transcript()
        try P.rejects { _ = try value.message(.stop, deadline: deadline) }
        try P.rejects { _ = try value.message(.stopped, deadline: deadline) }
        for event in [InstallationReadinessMessage.Event.normalStarted, .stop, .stopped] {
            let next = try value.message(event, deadline: deadline)
            let opposite: InstallationReadinessMessage.Endpoint = event.sender == .host ? .coordinator : .host
            try P.rejects { try value.consume(next, sender: opposite, deadline: deadline) }
            try value.consume(next, sender: event.sender, deadline: deadline)
            try P.rejects { try value.consume(next, sender: event.sender, deadline: deadline) }
        }
        for event in InstallationReadinessMessage.Event.allCases {
            try P.rejects { _ = try value.message(event, deadline: deadline) }
        }
        try P.rejects { _ = try InstallationStartupTranscript(commit: InstallationReadinessWireFixtures.message(.ready)) }
    }
    static func bindings() throws {
        let deadline = MonotonicDeadline(seconds: 3)
        for event in [InstallationReadinessMessage.Event.normalStarted, .stop, .stopped] {
            for key in ["transaction", "boot", "revision", "candidate", "state", "hostGeneration", "nonce", "previous"] {
                var value = try transcript()
                for prior in [InstallationReadinessMessage.Event.normalStarted, .stop, .stopped] {
                    if prior == event { break }
                    try value.consume(value.message(prior, deadline: deadline), sender: prior.sender, deadline: deadline)
                }
                let next = try value.message(event, deadline: deadline)
                var wire = try JSONSerialization.jsonObject(with: next.encode()) as! [String: Any]
                switch key {
                case "transaction", "boot", "hostGeneration": wire[key] = "00000000-0000-0000-0000-000000000099"
                case "revision": wire[key] = next.controlRevision + 2
                case "nonce": wire[key] = String(repeating: "e", count: 32)
                default: wire[key] = String(repeating: "f", count: 64)
                }
                let data = try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys, .withoutEscapingSlashes])
                let altered = try InstallationReadinessMessage.decode(data)
                try P.rejects { try value.consume(altered, sender: event.sender, deadline: deadline) }
                try value.consume(next, sender: event.sender, deadline: deadline)
            }
        }
    }
    static func originalDeadline() throws {
        var value = try transcript()
        let original = MonotonicDeadline(seconds: 0.01)
        let normal = try value.message(.normalStarted, deadline: original)
        try value.consume(normal, sender: .host, deadline: original)
        Thread.sleep(forTimeInterval: 0.02)
        try P.rejects { _ = try value.message(.stop, deadline: original) }
        try P.rejects { try value.consume(normal, sender: .host, deadline: original) }
        // Existing shared-frame deadline and EOF assertions remain exercised.
        try InstallationReadinessWireFixtures.sharedDeadline()
        try InstallationReadinessWireFixtures.eofAndEmpty()
    }
    static func cancelledActualSession() throws {
        try InstallationStagedJournalFixtures.fixture { _, location, _, _, _, journal, _ in
            let deadline = MonotonicDeadline(seconds: 3)
            _ = try journal.completeAdmission(deadline: deadline)
            guard let session = journal.testingSession else { throw H.Failure(message: "startup fixture missing actual session") }
            try journal.closeReadiness(deadline: deadline)
            try P.rejects { _ = try session.takeNormalStarted() }
            let control = try InstallationControlRecord.decode(Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json")))
            try H.check(control.phase == .active && control.readinessCommit == nil,
                        "cancelled readiness fabricated committed normal startup")
            try InstallationOwnershipFixtures.excluded(location)
            try journal.testingRemoveReadinessEndpoint()
        }
    }
    static func deadlineActualSession() throws {
        try InstallationStagedJournalFixtures.fixture { _, location, _, _, _, journal, _ in
            let deadline = MonotonicDeadline(seconds: 0.75)
            _ = try journal.completeAdmission(deadline: deadline)
            guard let session = journal.testingSession else { throw H.Failure(message: "startup deadline missing actual session") }
            let before = ProcessInfo.processInfo.systemUptime
            try P.rejects { _ = try session.takeNormalStarted() }
            try H.check(ProcessInfo.processInfo.systemUptime - before < 0.75,
                        "startup observation restarted the original caller budget")
            // A separate fixture-owned teardown budget proves queue retirement;
            // it cannot retry startup or manufacture an acknowledgment.
            try journal.closeReadiness(deadline: .init(seconds: 3))
            try P.rejects { _ = try session.takeNormalStarted() }
            try InstallationOwnershipFixtures.excluded(location)
            try journal.testingRemoveReadinessEndpoint()
        }
    }
    /// Exercise the same one-shot peer owner and completion predicate used by
    /// staged stopAndJoin with a real accepted, isolated Unix socket. This does
    /// not mint a staged host owner or an authenticated startup/stop event.
    private static func withAcceptedSocket(
        _ retirement: HostControlServer.StagedPeerRetirement,
        handle: (Int32, Int32) throws -> Void,
        retired: (Int32) throws -> Void = { _ in }
    ) throws {
        try H.fixture { root, _ in
            let deadline = MonotonicDeadline(seconds: 3)
            let listener = OwnedFileDescriptor(socket(AF_UNIX, SOCK_STREAM, 0))
            guard listener.value >= 0 else { throw H.Failure(message: "startup peer fixture listener") }
            defer { listener.closeNow() }
            try InstallationPrecommitTransport.configure(listener.value)
            var address = try HostControlIO.address(path: root + "/peer.sock")
            let bound = withUnsafePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener.value, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try H.check(bound == 0 && listen(listener.value, 1) == 0, "startup peer fixture bind")
            let client = OwnedFileDescriptor(socket(AF_UNIX, SOCK_STREAM, 0))
            guard client.value >= 0 else { throw H.Failure(message: "startup peer fixture client") }
            defer { client.closeNow() }
            try InstallationPrecommitTransport.configure(client.value)
            let connected = withUnsafePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(client.value, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connected != 0 {
                try H.check(errno == EINPROGRESS || errno == EAGAIN, "startup peer fixture connect")
                try HostControlIO.wait(client.value, events: Int16(POLLOUT), deadline: deadline)
                var code: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                try H.check(getsockopt(client.value, SOL_SOCKET, SO_ERROR, &code, &length) == 0 && code == 0,
                            "startup peer fixture pending connect")
            }
            try HostControlIO.wait(listener.value, events: Int16(POLLIN), deadline: deadline)
            let accepted = accept(listener.value, nil, nil)
            guard accepted >= 0 else { throw H.Failure(message: "startup peer fixture accept") }
            // Ownership starts before any assertion or fallible peer handling.
            try retirement.withAcceptedPeer(accepted) { try handle($0, client.value) }
            try retired(client.value)
            try H.check(client.retireChecked() == .succeeded && listener.retireChecked() == .succeeded,
                        "startup peer fixture cleanup")
        }
    }
    static func acceptedPeerDrain() throws {
        let retirement = HostControlServer.StagedPeerRetirement()
        var closeCalls = 0, pendingCloseRefused = false
        retirement.testingCloseAcceptedPeer = { raw in
            closeCalls += 1
            do { try retirement.requireRetired() } catch { pendingCloseRefused = true }
            return Darwin.close(raw) == 0 ? 0 : errno
        }
        defer { retirement.testingCloseAcceptedPeer = nil }
        for _ in 0..<3 {
            try withAcceptedSocket(retirement, handle: { peer, _ in
                try H.refuses { try retirement.requireRetired() }
                var uid: uid_t = 0, gid: gid_t = 0
                try H.check(getpeereid(peer, &uid, &gid) == 0 && uid == geteuid(),
                            "startup accepted peer identity")
            }, retired: { client in
                var byte: UInt8 = 0
                try H.check(recv(client, &byte, 1, MSG_DONTWAIT) == 0,
                            "successful accepted peer retirement did not deliver EOF")
                try retirement.requireRetired()
            })
        }
        // A handler rejection/throw still retires its enrolled peer exactly once.
        try H.refuses {
            try withAcceptedSocket(retirement, handle: { _, _ in
                try H.refuses { try retirement.requireRetired() }
                throw CustodyRecordError.injectedFailure
            })
        }
        try retirement.requireRetired()
        try H.check(closeCalls == 4 && pendingCloseRefused,
                    "accepted peer drain skipped ownership or repeated a close")
    }
    static func acceptedPeerCloseUncertain() throws {
        for code in [EINTR, EIO] {
            let retirement = HostControlServer.StagedPeerRetirement()
            var closeCalls = 0, actuallyClosed = false
            retirement.testingCloseAcceptedPeer = { raw in
                closeCalls += 1
                actuallyClosed = Darwin.close(raw) == 0
                // The fixture knows the effect; production receives only the
                // uncertain syscall outcome and must not infer that effect.
                return actuallyClosed ? code : errno
            }
            defer { retirement.testingCloseAcceptedPeer = nil }
            try withAcceptedSocket(retirement, handle: { _, _ in
                try H.refuses { try retirement.requireRetired() }
            })
            try H.check(actuallyClosed && closeCalls == 1, "accepted peer close cut not reached")
            for _ in 0..<3 { try H.refuses { try retirement.requireRetired() } }
            retirement.testingCloseAcceptedPeer = nil
            try withAcceptedSocket(retirement, handle: { _, _ in })
            try H.refuses { try retirement.requireRetired() }
            try H.check(closeCalls == 1, "uncertain accepted peer close was retried")
        }
    }
    static func acceptedPeerCloseReuse() throws {
        let retirement = HostControlServer.StagedPeerRetirement()
        var source: Int32 = -1, closeCalls = 0
        var replacement: OwnedFileDescriptor?
        retirement.testingCloseAcceptedPeer = { raw in
            closeCalls += 1
            guard Darwin.close(raw) == 0 else { return errno }
            guard dup2(source, raw) == raw else { return errno }
            // This is a new fixture-owned description at the consumed number.
            // Only this new owner may retire it; the old owner must never retry.
            replacement = OwnedFileDescriptor(raw)
            return EINTR
        }
        defer {
            retirement.testingCloseAcceptedPeer = nil
            replacement?.closeNow()
        }
        try withAcceptedSocket(retirement, handle: { _, client in source = client })
        guard let replacement else { throw H.Failure(message: "accepted peer reuse cut not reached") }
        retirement.testingCloseAcceptedPeer = nil
        for _ in 0..<3 {
            try H.refuses { try retirement.requireRetired() }
            try H.check(try replacement.withOriginalSocket { fcntl($0, F_GETFD) >= 0 },
                        "uncertain old peer owner closed a reused descriptor")
        }
        try withAcceptedSocket(retirement, handle: { _, _ in })
        try H.refuses { try retirement.requireRetired() }
        try H.check(closeCalls == 1 && replacement.retireChecked() == .succeeded,
                    "accepted peer uncertainty lost one-shot retirement")
    }
    /// A real unstarted journal cannot supply signed startup prerequisites.
    /// This refusal is separately registered and never stands in for native success.
    @inline(never)
    static func startupNativeHarnessPrerequisites() throws {
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, _, journal, registry in
            let path = URL(fileURLWithPath: location.path + "/custody/installation.json")
            let before = try Data(contentsOf: path)
            try H.check(journal.testingSession == nil, "startup prerequisite fixture unexpectedly has a session")
            do {
                try authenticatedStartupAndStop(journal, root: root, location: location)
                throw H.Failure(message: "startup harness accepted an absent session")
            } catch let failure as H.Failure where failure.message == "actual signed startup prerequisite missing" {
                // Only this prerequisite refusal is expected. Setup, root and
                // assertion errors must continue through the original guardian.
            }
            try H.check(journal.testingSession == nil && registry.testingCount == 0
                && (try Data(contentsOf: path)) == before,
                "startup prerequisite refusal created session, command or durable state")
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    /// Prerequisite-gated native continuation. The driver must bring the actual
    /// production-like signed peers, committed journal, app initialization and
    /// supported audit-token implementation. No constructor or fake verifier is
    /// provided. This is NOT registered as an executed synthetic positive.
    /// Unqualified until a real signed driver supplies a fresh original journal
    /// per cut. These are actual fault/retention seams, never authenticated-token
    /// constructors; source registration does not count them as passing cases.
    enum StopRetirementCut { case store, completion, heldCompletion }
    @_silgen_name("shadowSyncTesting_authenticatedStopRetirementCut")
    @inline(never)
    static func authenticatedStopRetirementCut(_ journal: CustodyCatalogStore.InstallationStagedJournal,
        location: StateLocation, cut: StopRetirementCut) throws {
        let started = try journal.takeNormalStarted()
        var actual: CustodyCatalogStore.InstallationStagedJournal.StopDelivery?
        var held: CustodyAuthorityLeaseSet?
        journal.testingStopDeliveryProbe = { delivery in
            actual = delivery
            switch cut {
            case .store: try delivery.testingUncertainClose(.store)
            case .completion: try delivery.testingUncertainClose(.completion)
            case .heldCompletion: held = try delivery.testingRetainCompletion()
            }
        }
        defer { journal.testingStopDeliveryProbe = nil; held = nil }
        try H.refuses { _ = try journal.stopStartedHost(started) }
        guard let actual else { throw H.Failure(message: "actual stop delivery was never published") }
        let (acknowledgment, progress) = journal.stoppedHostObservation()
        try H.check(acknowledgment?.host == started.host
            && acknowledgment?.control.readinessCommit == started.control.readinessCommit
            && acknowledgment?.deadline.absoluteUptimeNanoseconds == started.deadline.absoluteUptimeNanoseconds
            && progress == .pending, "stop cut lost authenticated identity or pending outcome")
        switch cut {
        case .store:
            try H.check(actual.testingStoreRetained
                && actual.testingStoreCloseResults == [.succeeded, .uncertain(EIO), .notAttempted, .notAttempted]
                && actual.testingCompletionResult == .notAttempted, "partial store close lost actual custody")
        case .completion:
            try H.check(!actual.testingStoreRetained && actual.testingCompletionResult == .uncertain(EIO),
                        "uncertain completion lease became successful")
        case .heldCompletion:
            try H.check(held != nil && !actual.testingStoreRetained && actual.testingCompletionResult == .notAttempted,
                        "retained completion lease was declared retired")
            held = nil
            try H.check(actual.testingCompletionResult == .succeeded && journal.stoppedHostObservation().1 == .pending,
                        "late lease destruction erased the original pending retirement")
        }
        try H.refuses { try actual.testingRefuseRetirementReplay() }
        try H.refuses { try actual.revalidate() }
        try H.refuses { _ = try journal.stopStartedHost(started) }
        try H.check(journal.testingOwner.testingTerminalOwnership().operation == .notAttempted,
                    "stop completion retired original operation")
        try InstallationOwnershipFixtures.excluded(location)
    }
    // Keep this actual Swift-ABI harness symbol stable for binary exclusion
    // and positive controls; Swift word substitution otherwise abbreviates
    // Startup against the enclosing fixture type. No C entry or wrapper exists.
    @_silgen_name("shadowSyncTesting_authenticatedStartupAndStop")
    @inline(never)
    static func authenticatedStartupAndStop(_ journal: CustodyCatalogStore.InstallationStagedJournal,
                                           root: String, location: StateLocation) throws {
        let paths = try InstallationPaths.isolated(root: TestIsolation.validateRoot(root))
        try H.check(paths.state.path == location.path, "startup native root mismatch")
        guard let session = journal.testingSession, let deadline = session.testingAnchoredDeadline,
              !deadline.hasExpired else { throw H.Failure(message: "actual signed startup prerequisite missing") }
        let startup = try journal.takeNormalStarted()
        try H.check(startup.control.phase == .committed && startup.control.readinessCommit != nil,
                    "normal-started lacked the exact durable commit")
        try P.rejects { _ = try journal.takeNormalStarted() }
        let stopped = try journal.stopStartedHost(startup)
        try H.check(stopped.control.readinessCommit == startup.control.readinessCommit
            && stopped.control.phase == .recovery && stopped.control.revision == startup.control.revision + 1,
                    "authenticated stop changed committed identity")
        let (retained, progress) = journal.stoppedHostObservation()
        try H.check(retained === stopped && stopped.host == startup.host
            && stopped.deadline.absoluteUptimeNanoseconds == startup.deadline.absoluteUptimeNanoseconds
            && progress == .complete && journal.testingSession == nil,
                    "stop returned before same-session join and checked completion retirement")
        try journal.testingOwner.validateStagedCommandAliasesRetired()
        try P.rejects { _ = try journal.stopStartedHost(startup) }
        try journal.closeReadiness(deadline: deadline)
        try InstallationOwnershipFixtures.excluded(location)
        // Named endpoint and original operation remain for causal cleanup.
    }
}
#endif
