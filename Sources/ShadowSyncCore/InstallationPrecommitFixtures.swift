#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

/// No synthetic positive native verifier. These cases prove source mechanisms
/// only; signed supported-host mutual authentication is a separate gate.
enum InstallationPrecommitFixtures {
    typealias H = InstallationStorageFixtures
    static func rejects(_ body: () throws -> Void) throws {
        do { try body() }
        catch is CustodyProtocolError { return }
        catch is CustodyRecordError { return }
        catch is SecureStateError { return }
        catch is PublisherPolicyError { return }
        catch is PolicyAuthorityFileError { return }
        throw H.Failure(message: "InstallationPrecommitFixtures accepted invalid transition")
    }
    static func order() throws {
        try InstallationReadinessWireFixtures.challengeExcessBeforeReady()
        let hello = InstallationReadinessWireFixtures.message()
        let deadline = MonotonicDeadline(seconds: 3)
        var transcript = try InstallationPrecommitTranscript(hello: hello)
        try transcript.consume(hello, sender: .host, deadline: deadline)
        let challenge = try transcript.message(.challenge)
        try transcript.consume(challenge, sender: .coordinator, deadline: deadline)
        let ready = try transcript.message(.ready)
        try transcript.consume(ready, sender: .host, deadline: deadline)
        try H.check(transcript.completedDigest != nil, "three-message transcript missing")
        for event in InstallationReadinessMessage.Event.allCases {
            try rejects { _ = try transcript.message(event) }
            try rejects { try transcript.consume(InstallationReadinessWireFixtures.message(event), sender: event.sender, deadline: deadline) }
        }
        var fresh = try InstallationPrecommitTranscript(hello: hello)
        try rejects { try fresh.consume(hello, sender: .coordinator, deadline: deadline) }
        try rejects { try fresh.consume(challenge, sender: .coordinator, deadline: deadline) }
        try fresh.consume(hello, sender: .host, deadline: deadline)
        try rejects { try fresh.consume(hello, sender: .host, deadline: deadline) }
    }
    static func bindings() throws {
        let hello = InstallationReadinessWireFixtures.message()
        for key in ["transaction", "boot", "revision", "candidate", "state", "hostGeneration", "nonce", "previous"] {
            var transcript = try InstallationPrecommitTranscript(hello: hello)
            let deadline = MonotonicDeadline(seconds: 3)
            try transcript.consume(hello, sender: .host, deadline: deadline)
            let challenge = try transcript.message(.challenge)
            var wire = try JSONSerialization.jsonObject(with: challenge.encode()) as! [String: Any]
            switch key {
            case "transaction", "boot", "hostGeneration": wire[key] = "00000000-0000-0000-0000-000000000099"
            case "revision": wire[key] = 25
            case "nonce": wire[key] = String(repeating: "e", count: 32)
            default: wire[key] = String(repeating: "f", count: 64)
            }
            let bytes = try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys, .withoutEscapingSlashes])
            let altered = try InstallationReadinessMessage.decode(bytes)
            try rejects { try transcript.consume(altered, sender: .coordinator, deadline: deadline) }
        }
    }
    static func deadlineAndEOF() throws {
        var transcript = try InstallationPrecommitTranscript(hello: InstallationReadinessWireFixtures.message())
        try rejects { try transcript.consume(InstallationReadinessWireFixtures.message(), sender: .host, deadline: .init(seconds: 0)) }
        try InstallationReadinessWireFixtures.eofAndEmpty()
        try InstallationReadinessWireFixtures.sharedDeadline()
    }
    static func endpoint() throws {
        try InstallationStagedJournalFixtures.fixture { _, location, _, _, _, journal, _ in
            let completed = try journal.completeAdmission(deadline: .init(seconds: 3))
            guard let endpoint = journal.testingEndpoint, let image = completed.transaction?.slots.images[.installationSocket],
                  let node = image.node else { throw H.Failure(message: "missing actual readiness endpoint") }
            try endpoint.revalidate()
            try H.check(node.type == .socket && node.mode == 0o140600 && node.links == 1
                && image.contentDigest == nil, "endpoint postimage differs")
            let control = try InstallationControlRecord.decode(Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json")))
            try H.check(control == completed, "endpoint completion not durable")
            try journal.closeReadiness(deadline: .init(seconds: 3))
            // Closing service never erases its recovery evidence.
            try endpoint.revalidate()
            try journal.testingRemoveReadinessEndpoint()
        }
    }
    // The paused reader is the actual session queue polling the original
    // endpoint. The second reader traverses the real journal/slot validation.
    // Neither path receives a synthetic authenticated peer or completion.
    static func concurrentEndpointReaders() throws {
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, _, journal, _ in
            let deadline = MonotonicDeadline(seconds: 3)
            let completed = try journal.completeAdmission(deadline: deadline)
            guard let endpoint = journal.testingEndpoint, let session = journal.testingSession else {
                throw H.Failure(message: "concurrent endpoint owners missing")
            }
            try endpoint.testingEnableMetadataCollection()
            let listener = try endpoint.listener
            let image = try endpoint.image
            let barrier = CustodyLeaseTestingBarrier()
            defer { barrier.release() }
            endpoint.testingPauseNextObservation(at: .beforeValidation, barrier: barrier)
            try H.check(barrier.waitUntilEntered() && endpoint.testingActiveObservations == 1,
                "actual service reader did not retain observation")
            let observation = try journal.bootstrapCandidateIntent(deadline: deadline)
            try H.check(endpoint.testingActiveObservations == 1 && journal.testingSession === session
                && (try endpoint.listener) === listener && (try endpoint.image) == image,
                "journal validation replaced or closed the concurrent service reader")
            let durable = try InstallationControlRecord.decode(Data(contentsOf:
                URL(fileURLWithPath: location.path + "/custody/installation.json")))
            try H.check(durable == observation.binding.control && durable.revision > completed.revision
                && durable.step?.action == .bootstrapCandidate && durable.step?.status == .intent
                && durable.readinessCommit == nil, "concurrent journal intent did not bind exact durable state")
            try H.check(endpoint.testingObservedMetadataDeadlines.contains(deadline.absoluteUptimeNanoseconds),
                "concurrent validation replaced caller deadline")
            barrier.release()
            try journal.closeReadiness(deadline: deadline)
            try H.check(endpoint.testingActiveObservations == 0 && journal.testingSession == nil
                && !session.start(), "concurrent endpoint service did not join")
            try endpoint.requireServiceClosed()
            try endpoint.revalidate(deadline: deadline)
            try observation.revalidate(deadline: deadline)
            // After successful service close, a real journal metadata reader
            // remains valid across idempotent close, but still excludes unlink.
            let metadata = CustodyLeaseTestingBarrier()
            defer { metadata.release() }
            endpoint.testingPauseNextObservation(at: .beforeValidation, barrier: metadata)
            let work = try RuntimeFixtureSession.installationRoot(root).startWork {
                try observation.revalidate(deadline: deadline)
            }
            try H.check(metadata.waitUntilEntered() && endpoint.testingActiveObservations == 1,
                "closed-service journal reader did not retain originals")
            endpoint.closeService()
            try endpoint.requireServiceClosed()
            try rejects { try endpoint.testingRemoveOwnedEndpoint(deadline: deadline) }
            try H.check(endpoint.testingActiveObservations == 1 && (try endpoint.image) == image,
                "idempotent close or cleanup disturbed metadata reader")
            metadata.release()
            try work.value(deadline: deadline)
            try H.check(endpoint.testingActiveObservations == 0, "closed-service metadata work did not join")
            try rejects { try endpoint.revalidate(deadline: .init(seconds: 0)) }
            try journal.testingRemoveReadinessEndpoint()
        }
    }
    // Hold the actual service inside its listener getter, after revalidation.
    // The journal must finish both revalidation and image reads while that
    // exclusive service lock is held; pausing revalidation alone misses this.
    static func endpointGetterOverlap() throws {
        try InstallationStagedJournalFixtures.fixture { _, location, _, _, _, journal, _ in
            let deadline = MonotonicDeadline(seconds: 3)
            let completed = try journal.completeAdmission(deadline: deadline)
            guard let endpoint = journal.testingEndpoint, let session = journal.testingSession else {
                throw H.Failure(message: "getter overlap endpoint owners missing")
            }
            try endpoint.testingEnableMetadataCollection()
            let preparing = CustodyLeaseTestingBarrier()
            let getter = CustodyLeaseTestingBarrier()
            let resumed = CustodyLeaseTestingBarrier()
            defer { preparing.release(); getter.release(); resumed.release() }
            // Set up while the service owns a read reservation, so this test's
            // initial listener capture cannot race another listener getter.
            endpoint.testingPauseNextObservation(at: .beforeValidation, barrier: preparing)
            try H.check(preparing.waitUntilEntered() && endpoint.testingActiveObservations == 1,
                "getter overlap setup did not retain actual service reader")
            let listener = try endpoint.listener
            let image = try endpoint.image
            endpoint.testingPauseNextListener(barrier: getter)
            preparing.release()
            try H.check(getter.waitUntilEntered() && endpoint.testingActiveObservations == 0,
                "actual listener getter did not pause after service revalidation")
            let observation = try journal.bootstrapCandidateIntent(deadline: deadline)
            let durable = try InstallationControlRecord.decode(Data(contentsOf:
                URL(fileURLWithPath: location.path + "/custody/installation.json")))
            try H.check(durable == observation.binding.control && durable.revision > completed.revision
                && durable.step?.action == .bootstrapCandidate && durable.step?.status == .intent
                && durable.readinessCommit == nil && (try endpoint.image) == image,
                "listener getter blocked journal image or durable intent")
            try H.check(journal.testingSession === session && session.testingOutcome == nil
                && listener.retirementObservation == .notAttempted && listener.value >= 0
                && endpoint.testingActiveObservations == 0
                && endpoint.testingObservedMetadataDeadlines.contains(deadline.absoluteUptimeNanoseconds),
                "getter overlap changed service ownership or caller deadline")
            // Observe the actual next polling turn, proving that the retained
            // listener getter also completed without a reader collision.
            endpoint.testingPauseNextObservation(at: .beforeValidation, barrier: resumed)
            getter.release()
            try H.check(resumed.waitUntilEntered() && endpoint.testingActiveObservations == 1
                && session.testingOutcome == nil && (try endpoint.listener) === listener,
                "actual service did not resume after concurrent journal image reads")
            try observation.revalidate(deadline: deadline)
            resumed.release()
            try journal.closeReadiness(deadline: deadline)
            try H.check(endpoint.testingActiveObservations == 0 && journal.testingSession == nil
                && listener.retirementObservation == .succeeded && !session.start(),
                "getter overlap service and listener did not join")
            try endpoint.requireServiceClosed()
            try observation.revalidate(deadline: deadline)
            try H.check((try endpoint.image) == image, "service close withdrew durable endpoint metadata")
            try journal.testingRemoveReadinessEndpoint()
            try rejects { _ = try endpoint.image }
        }
    }
    // Exercise the real retained endpoint after joining its original service.
    // No peer, deadline renewal, descriptor replacement or synthetic success.
    static func metadataCollectionCapacity() throws {
        try InstallationStagedJournalFixtures.fixture { _, _, _, _, _, journal, _ in
            let deadline = MonotonicDeadline(seconds: 30)
            _ = try journal.completeAdmission(deadline: deadline)
            guard let endpoint = journal.testingEndpoint, let session = journal.testingSession else {
                throw H.Failure(message: "metadata capacity original owners missing")
            }
            try journal.closeReadiness(deadline: deadline)
            let image = try endpoint.image
            // Cancellation may already have recorded an actual reader failure.
            // Keep that first outcome; these completed calls cannot replace it.
            let priorFailure = endpoint.testingFirstRevalidationFailure
            for _ in 0..<513 { try endpoint.revalidate(deadline: deadline) }
            try H.check(endpoint.testingObservedMetadataDeadlines.isEmpty
                && endpoint.testingObservedMetadataCapacityRefusals == 0
                && endpoint.testingFirstRevalidationFailure?.stage == priorFailure?.stage
                && endpoint.testingFirstRevalidationFailure?.metadataCount == priorFailure?.metadataCount
                && !session.start(),
                "unenrolled metadata sink altered endpoint validation or service ownership")
            try endpoint.testingEnableMetadataCollection()
            for _ in 0..<512 { try endpoint.revalidate(deadline: deadline) }
            let captured = endpoint.testingObservedMetadataDeadlines
            try H.check(captured == Array(repeating: deadline.absoluteUptimeNanoseconds, count: 512)
                && endpoint.testingObservedMetadataCapacityRefusals == 0,
                "enrolled metadata sink lost exact original call deadlines")
            do {
                try endpoint.revalidate(deadline: deadline)
                throw H.Failure(message: "enrolled metadata sink accepted a 513th call")
            } catch CustodyRecordError.busy {}
            // A busy entry deadline or sticky prior failure cannot prove overflow.
            // This observation changes only inside the actual collector guard.
            try H.check(endpoint.testingObservedMetadataCapacityRefusals == 1,
                "metadata overflow did not reach the actual capacity guard")
            let failure = endpoint.testingFirstRevalidationFailure
            try H.check(failure?.stage == (priorFailure?.stage ?? .capacity)
                && failure?.metadataCount == (priorFailure?.metadataCount ?? 512)
                && endpoint.testingObservedMetadataDeadlines == captured,
                "enrolled metadata sink changed the original capacity refusal")
            // With the collector still full, an expired entry must refuse before
            // the capacity guard and must not create another capacity observation.
            do {
                try endpoint.revalidate(deadline: MonotonicDeadline(uptimeNanoseconds: 0))
                throw H.Failure(message: "metadata capacity accepted an expired entry")
            } catch CustodyRecordError.busy {}
            try H.check(endpoint.testingObservedMetadataCapacityRefusals == 1
                && endpoint.testingObservedMetadataDeadlines == captured
                && endpoint.testingFirstRevalidationFailure?.stage == failure?.stage
                && endpoint.testingFirstRevalidationFailure?.metadataCount == failure?.metadataCount,
                "expired metadata entry changed capacity observation or first failure")
            try rejects { try endpoint.testingEnableMetadataCollection() }
            try H.check(endpoint.testingObservedMetadataDeadlines == captured
                && endpoint.testingFirstRevalidationFailure?.stage == failure?.stage
                && endpoint.testingFirstRevalidationFailure?.metadataCount == failure?.metadataCount,
                "metadata enrollment replay reset capture or first failure")
            try H.check(endpoint.testingObservedMetadataCapacityRefusals == 1,
                "metadata enrollment replay reset capacity observation")
            try endpoint.requireServiceClosed()
            try H.check(try endpoint.image == image && journal.testingSession == nil && !session.start(),
                "metadata capacity changed the original named endpoint or joined service")
            try journal.testingRemoveReadinessEndpoint()
        }
    }
    static func diagnosticScopes() throws {
        let outer = InstallationInvocationTesting.Context()
        let inner = InstallationInvocationTesting.Context()
        var outerFailure: InstallationInvocationTesting.Failure?
        var innerFailure: InstallationInvocationTesting.Failure?
        try InstallationInvocationTesting.withInvocation(outer) {
            InstallationInvocationTesting.stage(5)
            InstallationInvocationTesting.locate(.owner, node: InstallationInvocationTesting.Node.none)
            try rejects {
                try InstallationInvocationTesting.withInvocation(inner) {
                    InstallationInvocationTesting.stage(6)
                    InstallationInvocationTesting.locate(.retainedParent, node: InstallationInvocationTesting.Node.none)
                    do { try InstallationReadinessEndpoint.testingObserveParentNode(-1) }
                    catch {
                        let saved = errno
                        innerFailure = inner.failure(error)
                        try H.check(saved == EBADF && errno == saved,
                            "diagnostic changed actual failed fstat errno")
                        throw error
                    }
                }
            }
            try rejects {
                do { _ = try InstallationStateBinding.capture(stateDescriptor: -1, uid: geteuid()) }
                catch { outerFailure = outer.failure(error); throw error }
            }
        }
        try H.check(innerFailure?.stage == 6 && innerFailure?.phase == .retainedParent
            && innerFailure?.predicate == .statCall && innerFailure?.system == .badDescriptor
            && innerFailure?.error == .unsafeMetadata,
            "inner diagnostic did not preserve actual failed call")
        try H.check(outerFailure?.stage == 5 && outerFailure?.phase == .captureIdentity
            && outerFailure?.node == .state && outerFailure?.predicate == .statCall
            && outerFailure?.system == .badDescriptor && outerFailure?.error == .unsafeMetadata,
            "nested diagnostic did not restore caller binding")
        let successful = InstallationInvocationTesting.Context()
        let value = InstallationInvocationTesting.withInvocation(successful) { 7 }
        // A later unscoped actual failure must not contaminate a completed scope.
        try rejects { try InstallationReadinessEndpoint.testingObserveParentNode(-1) }
        let untouched = successful.failure(CustodyRecordError.fenced)
        try H.check(value == 7 && untouched.predicate == .thrown && untouched.system == .none,
            "scope success or unscoped failure created causal evidence")
    }
    static func endpointReaderClosure() throws {
        for point in [InstallationReadinessEndpoint.TestingObservationPoint.beforeValidation, .afterValidation] {
            try InstallationStagedJournalFixtures.fixture { _, location, _, _, admission, journal, registry in
                let deadline = MonotonicDeadline(seconds: 3)
                _ = try journal.completeAdmission(deadline: deadline)
                guard let endpoint = journal.testingEndpoint, let session = journal.testingSession else {
                    throw H.Failure(message: "close overlap endpoint owners missing")
                }
                let listener = try endpoint.listener
                let image = try endpoint.image
                let barrier = CustodyLeaseTestingBarrier()
                defer { barrier.release() }
                endpoint.testingPauseNextObservation(at: point, barrier: barrier)
                try H.check(barrier.waitUntilEntered() && endpoint.testingActiveObservations == 1,
                    "close overlap actual service reader missing")
                endpoint.closeService()
                try rejects { try endpoint.requireServiceClosed() }
                let competingInvocation = InstallationInvocationTesting.Context()
                var competingFailure: InstallationInvocationTesting.Failure?
                try rejects {
                    try InstallationInvocationTesting.withInvocation(competingInvocation) {
                        do { try endpoint.revalidate(deadline: deadline) }
                        catch { competingFailure = competingInvocation.failure(error); throw error }
                    }
                }
                try H.check(competingFailure?.stage == 2 && competingFailure?.error == .fenced,
                    "competing caller did not record its actual closed-observation refusal")
                try rejects { try endpoint.testingRemoveOwnedEndpoint(deadline: deadline) }
                try H.check(listener.retirementObservation == .notAttempted && listener.value >= 0
                    && endpoint.testingActiveObservations == 1 && endpoint.testingAcquisitionRetained
                    && (try endpoint.image) == image, "closure retired active reader originals or named fence")
                var node = stat()
                try H.check(lstat(location.path + "/installation.sock", &node) == 0
                    && UInt64(node.st_dev) == image.node?.device && UInt64(node.st_ino) == image.node?.inode,
                    "overlapping cleanup removed or replaced original endpoint")
                barrier.release()
                try journal.closeReadiness(deadline: deadline)
                guard case .failure(let failure)? = session.testingOutcome,
                      let refusal = failure as? CustodyRecordError, case .fenced = refusal else {
                    throw H.Failure(message: "closed observation returned stale success")
                }
                try H.check(endpoint.testingActiveObservations == 0 && journal.testingSession == nil
                    && listener.retirementObservation == .succeeded && !session.start(),
                    "closed reader and original listener did not join")
                let serve = session.testingKickstartState.serveInvocation
                try H.check(serve?.stage == 9 && serve?.error == .fenced
                    && session.testingKickstartState.firstServeFailureSite == .initialEndpointRevalidation
                    && endpoint.testingFirstRevalidationFailure?.stage.rawValue == 2,
                    "serve diagnostic borrowed another invocation's earlier endpoint failure")
                try endpoint.requireServiceClosed()
                try endpoint.revalidate(deadline: deadline)
                let retired = try registry.installationStagedStartRetirement(after: admission.closeStarts())
                let stop = try admission.stopOnly(after: retired)
                let stopped = try journal.candidateStopIntent(admission: stop, deadline: deadline)
                let durable = try InstallationControlRecord.decode(Data(contentsOf:
                    URL(fileURLWithPath: location.path + "/custody/installation.json")))
                try H.check(durable == stopped.binding.control && durable.phase == .recovery
                    && durable.step?.action == .candidateStop && durable.step?.status == .intent
                    && durable.readinessCommit == nil && (try endpoint.image) == image,
                    "joined service closure blocked exact post-close stop intent metadata")
                try journal.testingRemoveReadinessEndpoint()
                try rejects { try endpoint.revalidate(deadline: deadline) }
            }
        }
    }
    // New native-mechanism fixture sources are registered but unexecuted until
    // supported-host admission. They never replace exact native authentication.
    static func partialCreator() throws {
        for cut in [InstallationReadinessEndpoint.TestingCut.afterMode, .afterListen] {
            try InstallationStagedJournalFixtures.fixture { _, location, owner, _, _, journal, _ in
                let deadline = MonotonicDeadline(seconds: 3)
                journal.testingReadinessCut(cut)
                try rejects { _ = try journal.completeAdmission(deadline: deadline) }
                guard let partial = journal.testingEndpoint else { throw H.Failure(message: "partial creator not enrolled") }
                try H.check(partial.testingPartialRetained, "partial creator lost actual descriptions")
                try owner.validateReadinessOwner()
                try rejects { _ = try partial.image }
                try rejects { _ = try journal.completeAdmission(deadline: deadline) }
                let control = try InstallationControlRecord.decode(Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json")))
                try H.check(control.step?.action == .openStagedAdmission && control.step?.status == .intent
                    && control.transaction?.slots.images[.installationSocket]?.node == nil,
                    "partial creator manufactured durable completion")
                var node = stat()
                try H.check(lstat(location.path + "/installation.sock", &node) == 0
                    && node.st_mode == S_IFSOCK | 0o600 && node.st_nlink == 1,
                    "partial creator effect was not preserved")
                try journal.closeReadiness(deadline: deadline)
                try partial.requireServiceClosed()
                try journal.testingRemoveReadinessEndpoint()
            }
        }
    }
    static func creatorAddressBytes() throws {
        typealias Address = InstallationNamedSocketObservation.Address
        for path in ["relative", "/private//tmp", "/private/../tmp", "/private/./tmp", "/private/tmp\0suffix",
                     "/private/" + String(repeating: "é", count: 60), "/private/e\u{301}"] {
            try rejects { _ = try Address(canonicalParent: path, endpoint: .installation) }
        }
        let address = try Address(canonicalParent: "/private/tmp/fixture-owner", endpoint: .installation)
        var native = address.socketAddress()
        let actual = withUnsafeBytes(of: &native.sun_path) { Data($0.prefix(address.bytes.count)) }
        try H.check(actual == address.bytes && native.sun_len == UInt8(MemoryLayout<sockaddr_un>.size)
            && native.sun_family == sa_family_t(AF_UNIX), "creator address bytes or ABI length differ")
        let terminated = withUnsafeBytes(of: &native.sun_path) { $0[address.bytes.count] == 0 }
        try H.check(terminated, "creator address missing terminator")
    }
    static func creatorMetadataDrift() throws {
        try InstallationStagedJournalFixtures.fixture { _, location, _, _, _, journal, _ in
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            try journal.closeReadiness(deadline: .init(seconds: 3))
            guard let endpoint = journal.testingEndpoint else { throw H.Failure(message: "missing creator for drift") }
            let name = location.path + "/installation.sock"
            var before = stat(); try H.check(lstat(name, &before) == 0, "creator drift original node")
            try H.check(chmod(name, 0o640) == 0, "creator drift mode change")
            try rejects { try endpoint.revalidate() }
            try rejects { try endpoint.testingRemoveOwnedEndpoint() }
            var after = stat()
            try H.check(lstat(name, &after) == 0 && after.st_dev == before.st_dev && after.st_ino == before.st_ino
                && after.st_mode == S_IFSOCK | 0o640, "creator drift refusal changed named node")
            // Restore only fixture permissions. This is not restored creator
            // authority; original registered root custody owns final removal.
            try H.check(chmod(name, 0o600) == 0, "creator drift fixture mode restore")
        }
    }
    private final class ObserverFixture: InstallationNamedSocketFixtureCustodyOwner {
        private var lifecycle: LifecycleAdmissionAuthority?
        private var launcher: LauncherAuthority?
        private var endpoint: InstallationPrecommitHostEndpoint?
        func prepare(location: StateLocation, control: InstallationControlRecord, deadline: MonotonicDeadline) throws {
            guard lifecycle == nil, launcher == nil, endpoint == nil else { throw CustodyRecordError.fenced }
            let lifecycle = try LifecycleAdmissionAuthority.acquire(at: location); self.lifecycle = lifecycle
            let launcher = try LauncherAuthority.acquireForReadiness(admission: lifecycle) { self.launcher = $0 }
            endpoint = try InstallationPrecommitHostEndpoint(admission: lifecycle, launcher: launcher,
                control: control, deadline: deadline)
        }
        func connect() throws {
            guard let endpoint else { throw CustodyRecordError.fenced }
            try endpoint.connect()
        }
        func retireNamedSocketFixture(deadline: MonotonicDeadline) throws {
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            if let endpoint { guard endpoint.retireFailedHostResources() == .succeeded else { throw CustodyRecordError.fenced } }
            if let lifecycle { guard lifecycle.closeCommittedHostObservationBorrowing() == .succeeded else { throw CustodyRecordError.fenced } }
            if let launcher { guard launcher.retireCommittedHostLauncher() == .succeeded else { throw CustodyRecordError.fenced } }
            if let lifecycle { guard lifecycle.retireCommittedHostAdmission() == .succeeded else { throw CustodyRecordError.fenced } }
            endpoint = nil; launcher = nil; lifecycle = nil
        }
    }
    static func observerNamedRefusal() throws {
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, _, journal, _ in
            let deadline = MonotonicDeadline(seconds: 3)
            let control = try journal.completeAdmission(deadline: deadline)
            try journal.closeReadiness(deadline: deadline)
            let observer = ObserverFixture()
            try RuntimeFixtureSession.installationRoot(root).retainNamedSocket(observer)
            try observer.prepare(location: location, control: control, deadline: deadline)
            let name = location.path + "/installation.sock"
            var before = stat(); try H.check(lstat(name, &before) == 0, "observer original named node")
            try H.check(chmod(name, 0o640) == 0, "observer mode refusal setup")
            try rejects { try observer.connect() }
            try rejects { try observer.connect() }
            var after = stat()
            try H.check(lstat(name, &after) == 0 && after.st_dev == before.st_dev && after.st_ino == before.st_ino
                && after.st_mode == S_IFSOCK | 0o640, "observer repaired or removed endpoint")
            try observer.retireNamedSocketFixture(deadline: deadline)
            try H.check(chmod(name, 0o600) == 0, "observer fixture mode restore")
        }
    }
    static func unknownEndpoint() throws {
        for symlinked in [false, true] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, _, journal, _ in
                let name = location.path + "/installation.sock"
                if symlinked { try H.check(symlink(root, name) == 0, "fixture symlink") }
                else {
                    let fd = open(name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                    try H.check(fd >= 0, "fixture endpoint impostor"); close(fd)
                }
                var before = stat(); try H.check(lstat(name, &before) == 0, "fixture impostor before")
                try rejects { _ = try journal.completeAdmission(deadline: .init(seconds: 3)) }
                var after = stat(); try H.check(lstat(name, &after) == 0 && FileIdentity(before) == FileIdentity(after), "unknown endpoint altered")
            }
        }
    }
    static func substitution() throws {
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, _, journal, _ in
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            try journal.closeReadiness(deadline: .init(seconds: 3))
            guard let endpoint = journal.testingEndpoint else { throw H.Failure(message: "missing endpoint") }
            let name = location.path + "/installation.sock", saved = root + "/owned-endpoint"
            try H.check(rename(name, saved) == 0, "fixture endpoint move")
            let fd = open(name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            try H.check(fd >= 0, "fixture endpoint substitute"); close(fd)
            try rejects { try endpoint.revalidate() }
            try rejects { try endpoint.testingRemoveOwnedEndpoint() }
            // Restore only this fixture-created substitute and original inode.
            try H.check(unlink(name) == 0 && rename(saved, name) == 0, "restore owned endpoint")
            try endpoint.revalidate()
            try InstallationOwnershipFixtures.withACLGrant(location.path) {
                try rejects { try endpoint.revalidate() }
                try rejects { try endpoint.testingRemoveOwnedEndpoint() }
            }
            try endpoint.revalidate()
            try journal.testingRemoveReadinessEndpoint()
        }
    }
    static func partialPublication() throws {
        try InstallationStagedJournalFixtures.fixture { _, location, _, _, _, journal, _ in
            journal.testingCut(.afterReceipt)
            try rejects { _ = try journal.completeAdmission(deadline: .init(seconds: 3)) }
            try H.check(journal.testingHasPending, "partial endpoint publication lost receipt")
            guard let endpoint = journal.testingEndpoint else { throw H.Failure(message: "partial endpoint missing") }
            try endpoint.revalidate()
            let record = try InstallationControlRecord.decode(Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json")))
            try H.check(record.step?.status == .intent && record.transaction?.slots.images[.installationSocket]?.node == nil,
                "partial publication manufactured completion")
            try journal.testingRemoveReadinessEndpoint()
        }
    }
    static func extraPeer() throws {
        try H.fixture { root, _ in
            let path = root + "/extra.sock"
            let listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { throw H.Failure(message: "fixture listener") }
            defer { close(listener) }
            try InstallationPrecommitTransport.configure(listener)
            var address = try HostControlIO.address(path: path)
            let result = withUnsafePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            try H.check(result == 0 && listen(listener, 2) == 0, "fixture listener bound")
            var before = stat(); try H.check(lstat(path, &before) == 0, "fixture listener identity")
            defer {
                var after = stat()
                if lstat(path, &after) == 0 && FileIdentity(before).matchesStableNode(FileIdentity(after)) { _ = unlink(path) }
            }
            try InstallationPrecommitTransport.refuseAdditionalPeer(listener: listener)
            var peers: [Int32] = []
            defer { for fd in peers { close(fd) } }
            for _ in 0..<2 {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { throw H.Failure(message: "fixture additional peer") }
                peers.append(fd)
                let connected = withUnsafePointer(to: &address) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                try H.check(connected == 0, "fixture peer connect")
            }
            let first = accept(listener, nil, nil)
            try H.check(first >= 0, "fixture first peer"); close(first)
            try rejects { try InstallationPrecommitTransport.refuseAdditionalPeer(listener: listener) }
            try InstallationPrecommitTransport.refuseAdditionalPeer(listener: listener)
        }
        try InstallationStagedJournalFixtures.fixture { _, location, _, _, _, journal, _ in
            let deadline = MonotonicDeadline(seconds: 3)
            _ = try journal.completeAdmission(deadline: deadline)
            guard let session = journal.testingSession else { throw H.Failure(message: "missing real session") }
            // No fake authenticated peer is admitted. A real untrusted socket
            // must end the bounded session without publishing readiness.
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw H.Failure(message: "fixture peer socket") }
            defer { close(fd) }
            var address = try HostControlIO.address(path: location.path + "/installation.sock")
            let connected = withUnsafePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            try H.check(connected == 0, "untrusted peer did not connect")
            try session.testingWaitForAuthenticationRefusal(deadline: deadline)
            try journal.closeReadiness(deadline: deadline)
            let control = try InstallationControlRecord.decode(Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json")))
            try H.check(control.readinessCommit == nil && control.step?.action == .openStagedAdmission,
                "untrusted peer changed installation phase")
            try journal.testingRemoveReadinessEndpoint()
        }
    }
    static func publicationCancellation() throws {
        // A completed close must fence the actual admission turn before it can
        // bind a new endpoint, even when admission has never started.
        try InstallationStagedJournalFixtures.fixture { _, location, _, _, _, journal, _ in
            try journal.closeReadiness(deadline: .init(seconds: 3))
            try rejects { _ = try journal.completeAdmission(deadline: .init(seconds: 3)) }
            var node = stat()
            try H.check(lstat(location.path + "/installation.sock", &node) == -1 && errno == ENOENT,
                "closed admission created an endpoint")
            try H.check(journal.testingEndpoint == nil && journal.testingSession == nil,
                "closed admission retained new service work")
        }
        // A reserved turn is visible to close before source verification or
        // endpoint effects. A failed bounded join cannot claim retirement.
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, _, journal, _ in
            let barrier = CustodyLeaseTestingBarrier(), deadline = MonotonicDeadline(seconds: 3)
            defer { barrier.release() }
            journal.testingPauseSource(barrier)
            let work = try RuntimeFixtureSession.installationRoot(root).startWork {
                try rejects { _ = try journal.completeAdmission(deadline: deadline) }
            }
            try H.check(barrier.waitUntilEntered(), "admission turn barrier did not enter")
            try rejects { try journal.closeReadiness(deadline: .init(seconds: 0.02)) }
            var node = stat()
            try H.check(lstat(location.path + "/installation.sock", &node) == -1 && errno == ENOENT,
                "admission endpoint preceded reserved source turn")
            barrier.release(); try work.value(deadline: deadline)
            try journal.closeReadiness(deadline: deadline)
            try H.check(journal.testingSession == nil, "closed admission work survived join")
        }
        try InstallationStagedJournalFixtures.fixture { root, _, _, _, _, journal, _ in
            let barrier = CustodyLeaseTestingBarrier(), deadline = MonotonicDeadline(seconds: 3)
            defer { barrier.release() }
            journal.testingPausePublication(barrier)
            let work = try RuntimeFixtureSession.installationRoot(root).startWork {
                try H.refuses { _ = try journal.completeAdmission(deadline: deadline) }
            }
            try H.check(barrier.waitUntilEntered(), "publication barrier did not enter")
            guard let reserved = journal.testingSession else { throw H.Failure(message: "session was not published") }
            try journal.closeReadiness(deadline: deadline)
            try H.check(journal.testingSession == nil, "unlaunched reservation not joined")
            barrier.release(); try work.value(deadline: deadline)
            try H.check(!reserved.start(), "cancelled session launched late work")
            try journal.testingEndpoint?.revalidate()
        }
    }
    static func verificationCancellation() throws {
        try InstallationStagedJournalFixtures.fixture { root, _, _, _, _, journal, _ in
            let deadline = MonotonicDeadline(seconds: 3)
            _ = try journal.completeAdmission(deadline: deadline)
            let barrier = CustodyLeaseTestingBarrier()
            defer { barrier.release() }
            journal.testingPauseSource(barrier)
            let work = try RuntimeFixtureSession.installationRoot(root).startWork {
                _ = try journal.bootstrapCandidateIntent(deadline: deadline)
            }
            try H.check(barrier.waitUntilEntered(), "source verification barrier did not enter")
            try H.check(journal.testingMetadataLockAvailable, "journal mutex spans source verification")
            try journal.closeReadiness(deadline: .init(seconds: 0.2))
            try H.check(journal.testingSession == nil, "source verification blocked cancellation")
            barrier.release(); try work.value(deadline: deadline)
        }
    }
    static func failedJoinRetainsRoot() throws {
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, _, journal, _ in
            let deadline = MonotonicDeadline(seconds: 3)
            _ = try journal.completeAdmission(deadline: deadline)
            guard let session = journal.testingSession else { throw H.Failure(message: "missing owned session") }
            let barrier = CustodyLeaseTestingBarrier()
            defer { barrier.release() }
            session.testingPauseVerification(barrier)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw H.Failure(message: "join fixture socket") }; defer { close(fd) }
            var address = try HostControlIO.address(path: location.path + "/installation.sock")
            let connected = withUnsafePointer(to: &address) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            try H.check(connected == 0 && barrier.waitUntilEntered(), "join fixture did not reach actual queue")
            let custody = try RuntimeFixtureSession.installationRoot(root)
            try H.refuses { try custody.finish(deadline: .init(seconds: 0.02)) }
            var info = stat()
            try H.check(lstat(root, &info) == 0 && journal.testingSession === session,
                "failed join lost root or actual session owner")
            try H.check(try RuntimeFixtureSession.installationRoot(root) === custody,
                "outer fixture custody lost unresolved owner")
            barrier.release()
            try journal.closeReadiness(deadline: deadline)
            try H.check(journal.testingSession == nil, "released verifier did not really join")
        }
    }
    /// Value/unsigned-storage coverage only. No native authenticated host,
    /// ReadyObservation, admission or positive verifier is manufactured here.
    static func commitBinding() throws {
        var harness = try InstallationControlFixtures.Harness()
        try harness.throughReady()
        let kickstartReceipts = Array(harness.receipts.dropLast(2))
        let last = kickstartReceipts.last!
        let base = InstallationControlRecord(revision: harness.record.revision - 2, phase: .active,
            state: harness.state, transaction: harness.transaction, step: try last.step(),
            latestReceiptDigest: try last.digest(uid: harness.state.directory.uid), readinessCommit: nil, recoveryReason: nil)
        try base.validateReceiptChain(kickstartReceipts)
        try harness.commitReady()
        let expected = try InstallationHostCommitBinding.expectedControl(after: base,
            host: InstallationControlFixtures.process(401), transcriptDigest: InstallationControlFixtures.otherSHA)
        try H.check(expected == harness.record, "host expected a different four-edge commit")
        try H.refuses { _ = try InstallationHostCommitBinding.expectedControl(after: expected,
            host: InstallationControlFixtures.process(401), transcriptDigest: InstallationControlFixtures.otherSHA) }
        let ready = InstallationReadinessMessage(event: .ready, transactionID: harness.transaction.id,
            boot: harness.transaction.boot, controlRevision: base.revision,
            candidateReleaseDigest: harness.transaction.candidate!.release.releaseContractSHA256,
            stateBindingDigest: try base.state.digest(), hostGeneration: InstallationControlFixtures.generation,
            sessionNonce: String(repeating: "d", count: 32), previousMessageDigest: InstallationControlFixtures.sha)
        let message = InstallationReadinessMessage(event: .commit, transactionID: ready.transactionID,
            boot: ready.boot, controlRevision: expected.revision, candidateReleaseDigest: ready.candidateReleaseDigest,
            stateBindingDigest: ready.stateBindingDigest, hostGeneration: ready.hostGeneration,
            sessionNonce: ready.sessionNonce, previousMessageDigest: try ready.digest())
        try InstallationHostCommitBinding.validateMessage(message, ready: ready, committed: expected, deadline: .init(seconds: 1))
        try rejects { try InstallationHostCommitBinding.validateMessage(message, ready: ready, committed: expected, deadline: .init(seconds: 0)) }
        for key in ["event", "transaction", "boot", "revision", "candidate", "state", "hostGeneration", "nonce", "previous"] {
            var value = try JSONSerialization.jsonObject(with: message.encode()) as! [String: Any]
            switch key {
            case "event": value[key] = "challenge"
            case "transaction", "boot", "hostGeneration": value[key] = "00000000-0000-4000-8000-000000000099"
            case "revision": value[key] = expected.revision + 1
            case "nonce": value[key] = String(repeating: "e", count: 32)
            default: value[key] = String(repeating: "f", count: 64)
            }
            let altered = try InstallationReadinessMessage.decode(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]))
            try rejects { try InstallationHostCommitBinding.validateMessage(altered, ready: ready, committed: expected, deadline: .init(seconds: 1)) }
        }
    }
    static func deliveryOrdering() throws {
        // Pure ordering values cannot mint a journal capability or touch IO.
        var state = InstallationCommitDeliveryState()
        try H.refuses { try state.begin() }
        try H.refuses { try state.finish() }
        try state.submit()
        try H.refuses { try state.submit() }
        try H.refuses { try state.finish() }
        try state.begin()
        try H.refuses { try state.submit() }
        try H.refuses { try state.begin() }
        try state.finish()
        try H.refuses { try state.submit() }
        try H.refuses { try state.begin() }
        try H.refuses { try state.finish() }
        // Cancellation/failure at every prefix permanently forbids retry,
        // including a failure after send reservation/possible partial write.
        for prefix in 0...3 {
            for cancelled in [false, true] {
                var value = InstallationCommitDeliveryState()
                if prefix > 0 { try value.submit() }
                if prefix > 1 { try value.begin() }
                if prefix > 2 { try value.finish() }
                if cancelled { value.cancel() } else { value.fail() }
                try H.refuses { try value.submit() }
                try H.refuses { try value.begin() }
                try H.refuses { try value.finish() }
            }
        }
    }
    static func deliveryBinding() throws {
        var harness = try InstallationControlFixtures.Harness()
        try harness.throughReady(); try harness.commitReady()
        let ready = InstallationReadinessMessage(event: .ready, transactionID: harness.transaction.id,
            boot: harness.transaction.boot, controlRevision: harness.record.revision - 4,
            candidateReleaseDigest: harness.transaction.candidate!.release.releaseContractSHA256,
            stateBindingDigest: try harness.state.digest(), hostGeneration: InstallationControlFixtures.generation,
            sessionNonce: String(repeating: "d", count: 32), previousMessageDigest: InstallationControlFixtures.sha)
        let deadline = MonotonicDeadline(seconds: 1)
        let message = try InstallationCommitDeliveryBinding.message(ready: ready, committed: harness.record, deadline: deadline)
        try H.check(message.event == .commit && message.controlRevision == harness.record.revision
            && message.previousMessageDigest == (try ready.digest()), "delivery lost revision or ready predecessor")
        try InstallationHostCommitBinding.validateMessage(message, ready: ready, committed: harness.record, deadline: deadline)
        try H.refuses { _ = try InstallationCommitDeliveryBinding.message(ready: ready, committed: harness.record,
            deadline: .init(seconds: 0)) }
        for key in ["event", "transaction", "boot", "revision", "candidate", "state", "hostGeneration"] {
            var wire = try JSONSerialization.jsonObject(with: ready.encode()) as! [String: Any]
            switch key {
            case "event": wire[key] = "challenge"
            case "transaction", "boot", "hostGeneration": wire[key] = "00000000-0000-4000-8000-000000000099"
            case "revision": wire[key] = ready.controlRevision + 1
            default: wire[key] = String(repeating: "f", count: 64)
            }
            let changed = try InstallationReadinessMessage.decode(JSONSerialization.data(withJSONObject: wire,
                options: [.sortedKeys, .withoutEscapingSlashes]))
            try rejects { _ = try InstallationCommitDeliveryBinding.message(ready: changed, committed: harness.record, deadline: deadline) }
        }
    }
    static func deliveryUnready() throws {
        try InstallationStagedJournalFixtures.fixture { _, location, _, _, _, journal, _ in
            let path = location.path + "/custody/installation.json"
            let before = try Data(contentsOf: URL(fileURLWithPath: path))
            try H.refuses { _ = try journal.deliverReadinessCommit() }
            try journal.closeReadiness(deadline: .init(seconds: 3))
            try H.refuses { _ = try journal.deliverReadinessCommit() }
            try H.check(try Data(contentsOf: URL(fileURLWithPath: path)) == before,
                "unready delivery wrote durable state")
        }
    }

    /// Source harness only: requires an actual signed current coordinator and
    /// peer, real ReadyObservation, retired diagnostics and durable commit.
    /// No such fixture factory is supplied here; this is NOT an unsigned case.
    static func authenticatedDelivery(_ journal: CustodyCatalogStore.InstallationStagedJournal,
                                      committed: InstallationControlRecord) throws {
        let observation = try journal.deliverReadinessCommit()
        try H.check(observation.controlRevision == committed.revision && committed.phase == .committed,
            "transport observation differs from durable commit")
        try H.refuses { _ = try journal.deliverReadinessCommit() }
        // Host consumption/startup must be independently observed by its owner.
    }

    /// Both barriers stop the actual sole queue, not a synthetic send callback.
    /// The guardian retains the work/root if joining fails. A driver must supply
    /// a fresh real committed session for EACH point; this does not mint one.
    static func authenticatedDeliveryCloseRace(_ journal: CustodyCatalogStore.InstallationStagedJournal,
        point: InstallationPrecommitSession.TestingDeliveryPoint, root: String, location: StateLocation) throws {
        let paths = try InstallationPaths.isolated(root: TestIsolation.validateRoot(root))
        try H.check(paths.state.path == location.path && paths.state.uid == location.uid,
            "delivery race root mismatch")
        guard let session = journal.testingSession, let deadline = session.testingAnchoredDeadline,
              !deadline.hasExpired else { throw H.Failure(message: "actual committed session prerequisite missing") }
        let path = location.path + "/custody/installation.json"
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let committed = try InstallationControlRecord.decode(before)
        try H.check(committed.phase == .committed && committed.readinessCommit != nil,
            "delivery race requires durable commit")
        let barrier = CustodyLeaseTestingBarrier()
        defer { barrier.release() }
        try session.testingPauseDelivery(at: point, barrier: barrier)
        let work = try RuntimeFixtureSession.installationRoot(root).startWork {
            try rejects { _ = try journal.deliverReadinessCommit() }
        }
        try H.check(barrier.waitUntilEntered(), "actual delivery reservation not reached")
        let short = MonotonicDeadline(uptimeNanoseconds: min(deadline.absoluteUptimeNanoseconds,
            MonotonicDeadline(seconds: 0.02).absoluteUptimeNanoseconds))
        do {
            try journal.closeReadiness(deadline: short)
            throw H.Failure(message: "close succeeded with a reserved delivery still in flight")
        } catch CustodyRecordError.busy {}
        try H.check(journal.testingSession === session, "failed close lost original session owner")
        barrier.release()
        try work.value(deadline: deadline)
        try journal.closeReadiness(deadline: deadline)
        try H.check(journal.testingSession == nil, "delivery queue survived successful close")
        try H.refuses { _ = try journal.deliverReadinessCommit() }
        try H.check(try Data(contentsOf: URL(fileURLWithPath: path)) == before,
            "failed delivery rolled committed control back")
    }

    static func commitEOFDistinction() throws {
        for extra in [false, true] {
            var fds: [Int32] = [-1, -1]
            try H.check(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "commit fixture socket pair")
            let owned = OwnedFileDescriptor(fds[0]), peer = OwnedFileDescriptor(fds[1])
            defer { owned.closeNow(); peer.closeNow() }
            try InstallationPrecommitTransport.configure(owned.value)
            try InstallationPrecommitTransport.configure(peer.value)
            try InstallationHostCommitBinding.requireNoPostcommitInput(owned)
            if extra {
                var byte: UInt8 = 1
                try H.check(Darwin.write(peer.value, &byte, 1) == 1, "commit fixture extra frame")
                try rejects { try InstallationHostCommitBinding.requireNoPostcommitInput(owned) }
            } else {
                peer.closeNow()
                try rejects { try InstallationPrecommitTransport.requireQuiet(owned) }
                try InstallationHostCommitBinding.requireNoPostcommitInput(owned)
            }
            owned.closeNow()
            try rejects { try InstallationHostCommitBinding.requireNoPostcommitInput(owned) }
        }
    }

    static func commitLauncherOwnership() throws {
        try H.fixture { root, location in
            var initializer: FreshStateInitialization? = try .testing(root: root)
            _ = try initializer!.publish(); initializer = nil
            let lifecycle = try LifecycleAdmissionAuthority.acquire(at: location)
            let launcher = try LauncherAuthority.acquireWithinLifecycle(at: location)
            defer { launcher.release(); lifecycle.release() }
            let state = try InstallationStateBinding.capture(stateDescriptor: lifecycle.stateDirectory.descriptor.value, uid: location.uid)
            try launcher.validateRetainedInstallation(state)
            // Moving the owned inode does not transfer its lock to a replacement.
            let path = location.path + "/launcher.lock", saved = root + "/retained-launcher"
            try H.check(rename(path, saved) == 0, "fixture retained launcher move")
            let replacement = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            try H.check(replacement >= 0, "fixture replacement launcher")
            close(replacement)
            try H.refuses { try launcher.validateRetainedInstallation(state) }
            let changed = try InstallationStateBinding.capture(stateDescriptor: lifecycle.stateDirectory.descriptor.value, uid: location.uid)
            // Even freshly decoded state matching the replacement cannot turn
            // the retained old description into ownership of that replacement.
            try H.refuses { try launcher.validateRetainedInstallation(changed) }
            try H.check(unlink(path) == 0 && rename(saved, path) == 0, "fixture launcher restore")
            try launcher.validateRetainedInstallation(state)
            launcher.release()
            try H.refuses { try launcher.validateRetainedInstallation(state) }
        }
    }

    /// Requires a genuinely constructed current signed host and a concurrent
    /// genuine coordinator. Not a registered unsigned positive or a factory.
    /// Native execution and the postcommit socket/slot fault matrix stay open.
    static func authenticatedCommitHandoff(_ host: InstallationPrecommitHost) throws {
        let admission = try host.run()
        let ownership = try admission.take()
        defer { ownership.close() }
        try rejects { _ = try admission.take() }
        try ownership.validateBeforeStartup()
        ownership.close()
        try rejects { try ownership.validateBeforeStartup() }
        try rejects { _ = try admission.take() }
        try rejects { _ = try host.run() }
    }

    static func commitStoredReadback() throws {
        try H.fixture { root, location in
            var initializer: FreshStateInitialization? = try .testing(root: root)
            _ = try initializer!.publish(); initializer = nil
            let admission = try LifecycleAdmissionAuthority.acquire(at: location)
            defer { admission.release() }
            let state = try InstallationStateBinding.capture(stateDescriptor: admission.stateDirectory.descriptor.value, uid: location.uid)
            var harness = try InstallationControlFixtures.Harness(state: state)
            try harness.throughReady(); try harness.commitReady()
            let directory = location.path + "/custody/", receipts = directory + "receipts/"
            for receipt in harness.receipts {
                let path = receipts + (try receipt.filename(uid: location.uid))
                try receipt.encode(uid: location.uid).write(to: URL(fileURLWithPath: path))
                try H.check(chmod(path, 0o600) == 0, "fixture receipt mode")
            }
            let path = directory + InstallationControlRecord.filename
            try harness.record.encode().write(to: URL(fileURLWithPath: path))
            let deadline = MonotonicDeadline(seconds: 3)
            let observed = try CustodyCatalogStore.committedHostObservation(admission: admission, expected: harness.record, deadline: deadline)
            try observed.revalidate(deadline: deadline)
            // Same bytes on a replacement inode still invalidate retained evidence.
            for selected in [path, receipts + (try harness.receipts.last!.filename(uid: location.uid))] {
                let saved = root + "/retained-host-readback"
                let bytes = try Data(contentsOf: URL(fileURLWithPath: selected))
                try H.check(rename(selected, saved) == 0, "fixture retained readback move")
                try H.refuses { try observed.revalidate(deadline: deadline) }
                try bytes.write(to: URL(fileURLWithPath: selected))
                try H.check(chmod(selected, 0o600) == 0, "fixture replacement mode")
                try H.refuses { try observed.revalidate(deadline: deadline) }
                try H.check(unlink(selected) == 0 && rename(saved, selected) == 0, "fixture retained readback restore")
                try observed.revalidate(deadline: deadline)
            }
            try H.refuses { try observed.revalidate(deadline: .init(seconds: 0)) }
            admission.release()
            try H.refuses { _ = try CustodyCatalogStore.committedHostObservation(admission: admission,
                expected: harness.record, deadline: deadline) }
        }
    }

    static func pendingHostWait() throws {
        var harness = try InstallationControlFixtures.Harness()
        try harness.pair(.reserve)
        for action in [InstallationAction.drainPrior, .stageApplication, .stagePlist, .retireApplication,
                       .retirePlist, .retireCoordination, .translateState, .moveStateForward,
                       .promoteApplication, .promotePlist, .openStagedAdmission, .bootstrapCandidate] {
            try harness.add(action, status: .intent); try harness.add(action, status: .complete)
        }
        try harness.add(.kickstartCandidate, status: .intent)
        let pending = harness.record, deadline = MonotonicDeadline(seconds: 0.2)
        let original = deadline.absoluteUptimeNanoseconds
        try InstallationPrecommitWait.validateSuccessor(pending, of: pending, deadline: deadline)
        let complete = try InstallationPrecommitWait.completion(of: pending).0
        try harness.add(.kickstartCandidate, status: .complete)
        try H.check(complete == harness.record, "pending wait expected a different durable edge")
        try InstallationPrecommitWait.validateSuccessor(complete, of: pending, deadline: deadline)
        try H.check(deadline.absoluteUptimeNanoseconds == original, "pending wait reset budget")
        try rejects { try InstallationPrecommitWait.validateSuccessor(pending, of: complete, deadline: deadline) }
        try rejects { try InstallationPrecommitWait.validateSuccessor(complete, of: pending, deadline: .init(seconds: 0)) }
        // Waiting observation never satisfies hello's completed-control predicate.
        try rejects { try InstallationPrecommitTranscript.validateHello(InstallationReadinessWireFixtures.message(), control: pending) }
    }

}
#endif
