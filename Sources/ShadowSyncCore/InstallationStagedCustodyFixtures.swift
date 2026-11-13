#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

// Closed staged ownership/representation fixtures. These do not authenticate a
// candidate, publish staged actions or run launchctl. Existing preparation owns
// and drains its fixture helper before yielding to each synchronous body.
enum InstallationStagedCustodyFixtures {
    typealias H = InstallationStorageFixtures
    private static func staged(_ body: (StateLocation, InstallationTransactionOwner,
                                       InstallationStagedAdmission, RetainedCleanupRegistry) throws -> Void) throws {
        try InstallationExclusivePreparationFixtures.withPreparedIntent { _, location, owner, intent, registry in
            let retired = try registry.installationRetirement(after: owner.closeBorrowing())
            let admission = try owner.transferToStagedAdmission(intent: intent, after: retired,
                deadline: .init(seconds: 0.750))
            try body(location, owner, admission, registry)
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    private static func held(_ leases: CustodyAuthorityLeaseSet, mode: CustodyAuthorityMode) throws {
        try leases.validate()
        let claims = try leases.descriptorClaims()
        try H.check(leases.mode == mode && Set(claims.map(\.role)) == [.state, .namespace, .lifecycle, .operation],
                    "staged leases changed closed roles")
        try H.check(leases.testingDescriptorFlags().allSatisfy { $0.1 & FD_CLOEXEC != 0 },
                    "staged lease lost close-on-exec")
        // A representational mode cannot bypass installation fencing or mint a
        // context through a generic metadata-scope initializer.
        try H.refuses {
            _ = try CustodyMetadataScope(leases: leases, releaseSHA256: String(repeating: "a", count: 64),
                generation: RunIdentity.make())
        }
    }
    static func leaseContinuity() throws {
        try staged { location, owner, admission, _ in
            let before = try Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json"))
            let first = try admission.retainStartLeases()
            let second = try first.duplicate()
            try held(first, mode: .installationStagedStart); try held(second, mode: .installationStagedStart)
            try admission.revalidate(); try owner.revalidate()
            try H.check(try first.descriptorClaims() == second.descriptorClaims(), "staged descendant changed identity")
            for name in ["latest.log", "lifecycle.lock"] {
                let fd = open(location.path + "/" + name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                try H.check(fd >= 0, "staged shared contender open")
                defer { close(fd) }
                try H.check(flock(fd, LOCK_SH | LOCK_NB) == 0, "staged admission is not shared")
                try InstallationOwnershipFixtures.excluded(location, name: name)
            }
            try InstallationOwnershipFixtures.excluded(location)
            try InstallationOwnershipFixtures.excluded(location, name: "run.lock", expected: false)
            try H.refuses { _ = try owner.retainExclusiveLeases() }
            try H.refuses { _ = try owner.installationCommandHelper() }
            try H.check(try Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json")) == before,
                        "lease borrowing changed durable intent")
        }
    }
    static func oneWayClosure() throws {
        try staged { location, owner, admission, registry in
            var root: CustodyAuthorityLeaseSet? = try admission.retainStartLeases()
            var descendant: CustodyAuthorityLeaseSet? = try root!.duplicate()
            weak var retainedRoot = root
            try H.refuses { _ = try admission.closeStarts() }
            try H.refuses { try admission.revalidate() }
            try H.refuses { _ = try admission.retainStartLeases() }
            try H.refuses { _ = try root!.duplicate() }
            try H.refuses { _ = try descendant!.duplicate() }
            root = nil
            try H.check(retainedRoot != nil, "staged child dropped root owner")
            try H.refuses { _ = try admission.closeStarts() }
            try descendant!.validate(); try InstallationOwnershipFixtures.excluded(location)
            descendant = nil
            try H.check(retainedRoot == nil, "staged descriptions not actually released")
            let closed = try admission.closeStarts()
            let retirement = try registry.installationStagedStartRetirement(after: closed)
            try retirement.revalidate(for: owner)
            let stop = try admission.stopOnly(after: retirement)
            try stop.revalidate()
            let leases = try stop.retainStopLeases()
            try held(leases, mode: .installationStagedStop)
            try H.refuses { _ = try admission.retainStartLeases() }
            try H.refuses { _ = try owner.retainExclusiveLeases() }
            try H.refuses { _ = try admission.stopOnly(after: retirement) }
            try H.refuses { try retirement.revalidate(for: owner) }
            try H.refuses { try closed.validate() }
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    static func wrongOwnerAndDrift() throws {
        try staged { location, owner, admission, registry in
            let path = location.path + "/operation.lock"
            try H.check(chmod(path, 0o640) == 0, "staged protection drift")
            do {
                defer { _ = chmod(path, 0o600) }
                try H.refuses { _ = try admission.retainStartLeases() }
                try H.refuses { _ = try admission.closeStarts() }
            }
            // Failed closure remains permanent even when protection is restored.
            try H.refuses { _ = try admission.retainStartLeases() }
            let closed = try admission.closeStarts()
            let retirement = try registry.installationStagedStartRetirement(after: closed)
            try staged { otherLocation, other, otherAdmission, otherRegistry in
                let otherClosed = try otherAdmission.closeStarts()
                let otherRetirement = try otherRegistry.installationStagedStartRetirement(after: otherClosed)
                try H.refuses { try retirement.revalidate(for: other) }
                try H.refuses { _ = try otherAdmission.stopOnly(after: retirement) }
                try H.refuses { _ = try admission.stopOnly(after: otherRetirement) }
                try retirement.revalidate(for: owner)
                try otherRetirement.revalidate(for: other)
                try InstallationOwnershipFixtures.excluded(otherLocation)
            }
            let stop = try admission.stopOnly(after: retirement)
            try stop.revalidate(); try InstallationOwnershipFixtures.excluded(location)
        }
    }

    private static let identity = CustodyBinding(
        requestID: "00000000-0000-4000-8000-000000000001", scopeID: "00000000-0000-4000-8000-000000000002",
        nonce: String(repeating: "a", count: 32), callerGeneration: "00000000-0000-4000-8000-000000000003",
        trustedUID: 501, bootID: "00000000-0000-4000-8000-000000000004", releaseSHA256: String(repeating: "b", count: 64))
    private static func request(_ mode: CustodyAuthorityMode, kind: CustodyCommandKind = .launchctlRead,
                                operation: String = "print", extra: CustodyDescriptorClaim.Role? = nil,
                                omit: CustodyDescriptorClaim.Role? = nil, input: Bool = true) throws -> UnvalidatedCustodyRequest {
        var roles: [CustodyDescriptorClaim.Role] = [.request, .control, .status, .state, .namespace,
            .lifecycle, .operation, .input, .workingDirectory]
        if let extra { roles.append(extra) }
        if let omit { roles.removeAll { $0 == omit } }
        let claims = roles.sorted { $0.number < $1.number }.map {
            CustodyDescriptorClaim(role: $0, device: 1, inode: $0.number, uid: 501,
                mode: $0 == .state ? 0o40700 : 0o100600, links: 1,
                access: [.namespace, .lifecycle, .operation].contains($0) ? .readWrite : .read)
        }
        return UnvalidatedCustodyRequest(binding: identity, kind: kind, authority: mode,
            arguments: [operation], environment: [:], budget: try CustodyBudget.make(kind: kind, workSeconds: 1, now: 100),
            stdoutLimit: 1024, stderrLimit: 1024, inputSHA256: input ? String(repeating: "c", count: 64) : nil,
            resourcesSHA256: String(repeating: "d", count: 64), descriptors: claims)
    }
    private static func journal(_ request: UnvalidatedCustodyRequest) throws -> CustodyJournal {
        try CustodyJournal(prepared: request,
            leases: request.descriptors.filter { [.state, .namespace, .lifecycle, .operation, .run].contains($0.role) })
    }
    static func wireRoundtrip() throws {
        for mode: CustodyAuthorityMode in [.installationStagedStart, .installationStagedStop] {
            let operations = mode == .installationStagedStart ? ["bootstrap", "kickstart"] : ["bootout"]
            let forms: [(CustodyCommandKind, String)] = [(.launchctlRead, "print"), (.signatureCheck, "--verify")]
                + operations.map { (.launchctlMutation, $0) }
            for (kind, operation) in forms {
                let value = try request(mode, kind: kind, operation: operation), bytes = try value.encode()
                let decoded = try UnvalidatedCustodyRequest.decode(bytes, expected: identity, permittedWorkSeconds: 1, now: 100)
                try H.check(try decoded.encode() == bytes, "staged request not canonical")
                let record = try journal(decoded), recordBytes = try record.encode()
                try H.check(try CustodyJournal.decode(recordBytes) == record, "staged journal did not roundtrip")
                let entry = CustodyCatalogEntry(record)
                try H.check(try CustodyCatalogEntry(wire: entry.wire) == entry, "staged catalog did not roundtrip")
            }
        }
    }
    private static func refusesWire(_ body: () throws -> Void) throws {
        do { try body() }
        catch is CustodyProtocolError { return }
        throw H.Failure(message: "staged wire unexpectedly accepted")
    }
    static func wireRefusals() throws {
        for mode: CustodyAuthorityMode in [.installationStagedStart, .installationStagedStop] {
            for kind in CustodyCommandKind.allCases where ![.launchctlRead, .signatureCheck, .launchctlMutation].contains(kind) {
                let value = try request(mode, kind: kind)
                try refusesWire { _ = try value.encode() }
                try H.refuses { _ = try journal(value) }
                // Persisted entry decoding cannot use the staged mode to widen
                // kinds even though it carries no executable/action metadata.
                var wire = try CustodyCatalogEntry(journal(request(mode))).wire.object(keys:
                    ["request", "scope", "boot", "release", "kind", "authority", "journal"])
                wire["kind"] = .string(kind.rawValue)
                try H.refuses { _ = try CustodyCatalogEntry(wire: .object(wire)) }
            }
            for extra: CustodyDescriptorClaim.Role in [.run, .code, .gitDirectory, .gitFile, .traceOutput] {
                try refusesWire { _ = try request(mode, extra: extra).encode() }
            }
            for omit: CustodyDescriptorClaim.Role in [.input, .operation, .state, .namespace, .lifecycle] {
                try refusesWire { _ = try request(mode, omit: omit).encode() }
            }
            try refusesWire { _ = try request(mode, input: false).encode() }
            try H.refuses { _ = try journal(request(mode, input: false)) }
            for operation in ["restore", "launchctl", mode == .installationStagedStart ? "bootout" : "bootstrap"] {
                try refusesWire { _ = try request(mode, kind: .launchctlMutation, operation: operation).encode() }
            }
            if mode == .installationStagedStop {
                try refusesWire { _ = try request(mode, kind: .launchctlMutation, operation: "kickstart").encode() }
            }
        }
        try H.check(CustodyAuthorityMode.observation.permits(kind: .launchctlRead)
            && CustodyAuthorityMode.observation.permits(kind: .signatureCheck)
            && !CustodyAuthorityMode.observation.permits(kind: .launchctlMutation), "observation widened")
    }
}
#endif
