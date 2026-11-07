import CryptoKit
import Foundation

// Closed persisted observations, never process ownership or permission to signal.
enum CustodyRecordError: Error {
    case invalidRecord, invalidTransition, conflict, fenced, busy, unsafeMetadata
    case persistence(Int32)
    // The replacement is durable; only obsolete-preimage cleanup failed.
    // This still closes admission, but must never be described as a rollback.
    case committedCleanupFailure(Int32)
    #if SHADOW_SYNC_TESTING
    case injectedFailure
    #endif
}

enum CustodyPhase: String, Sendable {
    case prepared, admitted, executing, draining
    case cleanupPending = "cleanup-pending", terminal, recoveredAfterBoot = "recovered-after-boot"
    var isTerminal: Bool { self == .terminal || self == .recoveredAfterBoot }
}

enum CustodyOutcome: String, Sendable {
    case completed, commandFailed = "command-failed", admissionRefused = "admission-refused"
    case cancelledDrained = "cancelled-drained", timedOutDrained = "timed-out-drained"
    case interruptedUnknown = "interrupted-unknown"
}

enum CustodyReason: String, Sendable {
    case none, cancelled, timeout, protocolFault = "protocol-fault"
    case invalidResource = "invalid-resource", identityFailure = "identity-failure"
    case outputLimit = "output-limit", ioFailure = "io-failure", startFailure = "start-failure"
    case ownershipLost = "ownership-lost", persistenceFailure = "persistence-failure", bootChanged = "boot-changed"
}

struct CustodyRecordBinding: Equatable, Sendable {
    let requestID: String
    let scopeID: String
    let nonceSHA256: String
    let generation: String
    let uid: UInt32
    let bootID: String
    let releaseSHA256: String

    init(_ binding: CustodyBinding) throws {
        try binding.validate()
        requestID = binding.requestID; scopeID = binding.scopeID
        nonceSHA256 = Self.digest(Data(binding.nonce.utf8)); generation = binding.callerGeneration
        uid = binding.trustedUID; bootID = binding.bootID; releaseSHA256 = binding.releaseSHA256
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    var wire: PolicyWireValue { .object([
        "request": .string(requestID), "scope": .string(scopeID), "nonce_sha256": .string(nonceSHA256),
        "generation": .string(generation), "uid": .unsigned(UInt64(uid)),
        "boot": .string(bootID), "release": .string(releaseSHA256),
    ]) }
    init(wire: PolicyWireValue) throws {
        let v = try wire.object(keys: ["request", "scope", "nonce_sha256", "generation", "uid", "boot", "release"])
        requestID = try CustodyWire.text(v["request"]); scopeID = try CustodyWire.text(v["scope"])
        nonceSHA256 = try CustodyWire.text(v["nonce_sha256"]); generation = try CustodyWire.text(v["generation"])
        guard let uid = UInt32(exactly: try CustodyWire.uint(v["uid"])) else { throw CustodyRecordError.invalidRecord }
        self.uid = uid; bootID = try CustodyWire.text(v["boot"]); releaseSHA256 = try CustodyWire.text(v["release"])
        try validate()
    }
    func validate() throws {
        guard [requestID, scopeID, generation, bootID].allSatisfy(RunIdentity.isValid),
              CustodyWire.hex(nonceSHA256, bytes: 32), CustodyWire.hex(releaseSHA256, bytes: 32) else {
            throw CustodyRecordError.invalidRecord
        }
    }
}

struct CustodyProcessObservation: Equatable, Sendable {
    let pid: UInt32, group: UInt32, uid: UInt32
    let startSeconds: UInt64, startMicroseconds: UInt64
    let generation: String
    init(_ identity: ProcessIdentity) throws {
        guard identity.processID > 1, identity.processGroupID == identity.processID else {
            throw CustodyRecordError.invalidRecord
        }
        pid = UInt32(identity.processID); group = UInt32(identity.processGroupID); uid = identity.userID
        startSeconds = identity.startSeconds; startMicroseconds = identity.startMicroseconds
        generation = identity.generation; try validate()
    }
    var wire: PolicyWireValue { .object([
        "pid": .unsigned(UInt64(pid)), "group": .unsigned(UInt64(group)), "uid": .unsigned(UInt64(uid)),
        "start_seconds": .unsigned(startSeconds), "start_microseconds": .unsigned(startMicroseconds),
        "generation": .string(generation),
    ]) }
    init(wire: PolicyWireValue) throws {
        let v = try wire.object(keys: ["pid", "group", "uid", "start_seconds", "start_microseconds", "generation"])
        guard let pid = UInt32(exactly: try CustodyWire.uint(v["pid"])),
              let group = UInt32(exactly: try CustodyWire.uint(v["group"])),
              let uid = UInt32(exactly: try CustodyWire.uint(v["uid"])) else { throw CustodyRecordError.invalidRecord }
        self.pid = pid; self.group = group; self.uid = uid
        startSeconds = try CustodyWire.uint(v["start_seconds"])
        startMicroseconds = try CustodyWire.uint(v["start_microseconds"])
        generation = try CustodyWire.text(v["generation"]); try validate()
    }
    func validate() throws {
        guard pid > 1, pid <= UInt32(Int32.max), group == pid, startSeconds > 0,
              startMicroseconds < 1_000_000, RunIdentity.isValid(generation) else { throw CustodyRecordError.invalidRecord }
    }
}

struct CustodyJournal: Equatable, Sendable {
    static let maximumBytes = 32_768
    let binding: CustodyRecordBinding
    let kind: CustodyCommandKind
    let authority: CustodyAuthorityMode
    let budget: CustodyBudget
    let inputSHA256: String?
    let resourcesSHA256: String
    let leases: [CustodyDescriptorClaim]
    let ordinal: UInt64
    let phase: CustodyPhase
    let custodian: CustodyProcessObservation?
    let target: CustodyProcessObservation?
    let outcome: CustodyOutcome?
    let reason: CustodyReason?
    let waitStatus: UInt32?

    init(prepared request: UnvalidatedCustodyRequest, leases: [CustodyDescriptorClaim]) throws {
        binding = try CustodyRecordBinding(request.binding); kind = request.kind; authority = request.authority
        budget = request.budget; inputSHA256 = request.inputSHA256; resourcesSHA256 = request.resourcesSHA256
        self.leases = leases.sorted { $0.role.number < $1.role.number }
        ordinal = 0; phase = .prepared; custodian = nil; target = nil; outcome = nil; reason = nil; waitStatus = nil
        try validate()
    }
    private init(binding: CustodyRecordBinding, kind: CustodyCommandKind, authority: CustodyAuthorityMode,
                 budget: CustodyBudget, input: String?, resources: String, leases: [CustodyDescriptorClaim],
                 ordinal: UInt64, phase: CustodyPhase, custodian: CustodyProcessObservation?,
                 target: CustodyProcessObservation?, outcome: CustodyOutcome?, reason: CustodyReason?, status: UInt32?) {
        self.binding = binding; self.kind = kind; self.authority = authority; self.budget = budget
        inputSHA256 = input; resourcesSHA256 = resources; self.leases = leases; self.ordinal = ordinal
        self.phase = phase; self.custodian = custodian; self.target = target
        self.outcome = outcome; self.reason = reason; waitStatus = status
    }
    // This constructs a proposed observation only. Durable writes require the
    // typed writer in the catalog/context layer, not a decoded journal or UUID.
    func advancing(to next: CustodyPhase, custodian: CustodyProcessObservation? = nil,
                   target: CustodyProcessObservation? = nil, outcome: CustodyOutcome? = nil,
                   reason: CustodyReason? = nil, waitStatus: UInt32? = nil) throws -> Self {
        guard !phase.isTerminal, ordinal < UInt64.max else { throw CustodyRecordError.invalidTransition }
        let allowed: Bool
        switch (phase, next) {
        case (.prepared, .admitted), (.prepared, .draining), (.prepared, .terminal),
             (.admitted, .executing), (.admitted, .draining), (.admitted, .terminal),
             (.executing, .executing), (.executing, .draining), (.executing, .terminal),
             (.draining, .cleanupPending), (.draining, .terminal),
             (.cleanupPending, .terminal): allowed = true
        default: allowed = false
        }
        guard allowed else { throw CustodyRecordError.invalidTransition }
        let value = Self(binding: binding, kind: kind, authority: authority, budget: budget,
            input: inputSHA256, resources: resourcesSHA256, leases: leases, ordinal: ordinal + 1, phase: next,
            custodian: custodian ?? self.custodian, target: target ?? self.target,
            outcome: outcome, reason: reason, status: waitStatus)
        try value.validate()
        if let old = self.custodian, value.custodian != old { throw CustodyRecordError.invalidTransition }
        if phase == .prepared && next == .terminal && outcome != .admissionRefused { throw CustodyRecordError.invalidTransition }
        return value
    }
    // Pure transition only. CustodyRecoveryContext proves a different kernel
    // boot and exclusive original leases before this can become durable.
    func recoveredAfterBoot() throws -> Self {
        guard !phase.isTerminal, ordinal < UInt64.max else { throw CustodyRecordError.invalidTransition }
        let value = Self(binding: binding, kind: kind, authority: authority, budget: budget,
            input: inputSHA256, resources: resourcesSHA256, leases: leases, ordinal: ordinal + 1,
            phase: .recoveredAfterBoot, custodian: custodian, target: target,
            outcome: .interruptedUnknown, reason: .bootChanged, status: nil)
        try value.validate(); return value
    }
    func validate() throws {
        try binding.validate()
        let b = budget
        guard b.issued < b.work, b.work <= b.term, b.term <= b.kill, b.kill <= b.receipt,
              b.work - b.issued <= UInt64(ChildProcessBudget.seconds(kind.maximumWorkSeconds) * 1_000_000_000),
              b.term - b.work <= UInt64(ChildProcessBudget.seconds(2) * 1_000_000_000),
              b.kill - b.term <= UInt64(ChildProcessBudget.seconds(2) * 1_000_000_000),
              b.receipt - b.kill <= UInt64(ChildProcessBudget.seconds(1) * 1_000_000_000),
              inputSHA256.map({ CustodyWire.hex($0, bytes: 32) }) ?? true,
              CustodyWire.hex(resourcesSHA256, bytes: 32) else { throw CustodyRecordError.invalidRecord }
        guard authority.permits(kind: kind), !authority.isInstallationStaged || inputSHA256 != nil else {
            throw CustodyRecordError.invalidRecord
        }
        var roles: Set<CustodyDescriptorClaim.Role> = [.state, .namespace, .lifecycle]
        if authority.needsOperation { roles.insert(.operation) }
        if authority == .mutation { roles.insert(.run) }
        guard Set(leases.map(\.role)) == roles, leases.count == roles.count,
              leases.map({ $0.role.number }) == leases.map({ $0.role.number }).sorted() else { throw CustodyRecordError.invalidRecord }
        for lease in leases {
            guard lease.device > 0, lease.inode > 0, lease.uid == binding.uid,
                  lease.access == .read || lease.access == .readWrite,
                  lease.role == .state ? (lease.mode == 0o40700 && lease.links > 0)
                    : (lease.mode == 0o100600 && lease.links == 1) else { throw CustodyRecordError.invalidRecord }
        }
        if let custodian { try custodian.validate(); guard custodian.uid == binding.uid else { throw CustodyRecordError.invalidRecord } }
        if let target { try target.validate(); guard target.uid == binding.uid, custodian != nil, target.pid != custodian?.pid else { throw CustodyRecordError.invalidRecord } }
        guard (phase == .prepared) == (ordinal == 0) else { throw CustodyRecordError.invalidRecord }
        if phase == .prepared && (custodian != nil || target != nil) { throw CustodyRecordError.invalidRecord }
        if phase == .admitted && (custodian == nil || target != nil) { throw CustodyRecordError.invalidRecord }
        if phase == .executing && (custodian == nil || target == nil) { throw CustodyRecordError.invalidRecord }
        if phase.isTerminal {
            guard let outcome, let reason else { throw CustodyRecordError.invalidRecord }
            if phase == .terminal {
                guard (target == nil) == (waitStatus == nil) else { throw CustodyRecordError.invalidRecord }
                if let waitStatus {
                    let low = waitStatus & 0x7f
                    guard waitStatus <= 0xffff, low == 0 || (low > 0 && low < 0x7f) else { throw CustodyRecordError.invalidRecord }
                }
            }
            switch outcome {
            case .completed: guard phase == .terminal, reason == .none, waitStatus == 0, target != nil else { throw CustodyRecordError.invalidRecord }
            case .commandFailed:
                guard phase == .terminal, let waitStatus, target != nil,
                      reason != .cancelled, reason != .timeout, reason != .bootChanged,
                      waitStatus != 0 || reason != .none else { throw CustodyRecordError.invalidRecord }
            case .admissionRefused: guard phase == .terminal, reason != .none, reason != .bootChanged, waitStatus != 0 else { throw CustodyRecordError.invalidRecord }
            case .cancelledDrained: guard phase == .terminal, reason == .cancelled else { throw CustodyRecordError.invalidRecord }
            case .timedOutDrained: guard phase == .terminal, reason == .timeout else { throw CustodyRecordError.invalidRecord }
            case .interruptedUnknown: guard phase == .recoveredAfterBoot, reason == .bootChanged, waitStatus == nil else { throw CustodyRecordError.invalidRecord }
            }
        } else if outcome != nil || reason != nil || waitStatus != nil { throw CustodyRecordError.invalidRecord }
    }
    var wire: PolicyWireValue { .object([
        "schema": .string("shadow-sync-custody/v1"), "binding": binding.wire,
        "command": .object(["kind": .string(kind.rawValue), "authority": .string(authority.rawValue),
            "input": inputSHA256.map(PolicyWireValue.string) ?? .null, "resources": .string(resourcesSHA256)]),
        "budget": budget.wire, "leases": .array(leases.map(\.wire)),
        "transition": .unsigned(ordinal), "phase": .string(phase.rawValue),
        "processes": .object(["custodian": custodian?.wire ?? .null, "target": target?.wire ?? .null]),
        "result": .object(["outcome": outcome.map { .string($0.rawValue) } ?? .null,
            "reason": reason.map { .string($0.rawValue) } ?? .null,
            "wait_status": waitStatus.map { .unsigned(UInt64($0)) } ?? .null]),
    ]) }
    func encode() throws -> Data { try validate(); return try CustodyWire.encode(wire, maximum: Self.maximumBytes) }
    static func decode(_ data: Data) throws -> Self {
        do {
            let v = try CustodyWire.decode(data, maximum: maximumBytes).object(keys: ["schema", "binding", "command", "budget", "leases", "transition", "phase", "processes", "result"])
            guard v["schema"] == .string("shadow-sync-custody/v1"), let phase = CustodyPhase(rawValue: try CustodyWire.text(v["phase"])) else { throw CustodyRecordError.invalidRecord }
            let c = try CustodyWire.required(v["command"]).object(keys: ["kind", "authority", "input", "resources"])
            guard let kind = CustodyCommandKind(rawValue: try CustodyWire.text(c["kind"])), let mode = CustodyAuthorityMode(rawValue: try CustodyWire.text(c["authority"])) else { throw CustodyRecordError.invalidRecord }
            let p = try CustodyWire.required(v["processes"]).object(keys: ["custodian", "target"])
            let r = try CustodyWire.required(v["result"]).object(keys: ["outcome", "reason", "wait_status"])
            let outcome = try CustodyWire.optionalText(r["outcome"]), reason = try CustodyWire.optionalText(r["reason"])
            let parsedOutcome = outcome.flatMap(CustodyOutcome.init(rawValue:)), parsedReason = reason.flatMap(CustodyReason.init(rawValue:))
            guard (outcome == nil) == (parsedOutcome == nil), (reason == nil) == (parsedReason == nil) else { throw CustodyRecordError.invalidRecord }
            let status: UInt32?
            if r["wait_status"] == .null { status = nil }
            else { guard let value = UInt32(exactly: try CustodyWire.uint(r["wait_status"])) else { throw CustodyRecordError.invalidRecord }; status = value }
            let result = Self(binding: try CustodyRecordBinding(wire: CustodyWire.required(v["binding"])), kind: kind, authority: mode,
                budget: try CustodyBudget(wire: CustodyWire.required(v["budget"])), input: try CustodyWire.optionalText(c["input"]),
                resources: try CustodyWire.text(c["resources"]), leases: try CustodyWire.array(v["leases"]).map(CustodyDescriptorClaim.init(wire:)),
                ordinal: try CustodyWire.uint(v["transition"]), phase: phase,
                custodian: p["custodian"] == .null ? nil : try CustodyProcessObservation(wire: CustodyWire.required(p["custodian"])),
                target: p["target"] == .null ? nil : try CustodyProcessObservation(wire: CustodyWire.required(p["target"])),
                outcome: parsedOutcome, reason: parsedReason, status: status)
            try result.validate(); return result
        } catch { throw CustodyRecordError.invalidRecord }
    }
}

struct CustodyCatalogEntry: Equatable, Sendable {
    let requestID: String, scopeID: String, bootID: String, releaseSHA256: String
    let kind: CustodyCommandKind
    let authority: CustodyAuthorityMode
    var filename: String { requestID + ".json" }
    init(_ journal: CustodyJournal) {
        requestID = journal.binding.requestID; scopeID = journal.binding.scopeID; bootID = journal.binding.bootID
        releaseSHA256 = journal.binding.releaseSHA256; kind = journal.kind; authority = journal.authority
    }
    var wire: PolicyWireValue { .object([
        "request": .string(requestID), "scope": .string(scopeID), "boot": .string(bootID), "release": .string(releaseSHA256),
        "kind": .string(kind.rawValue), "authority": .string(authority.rawValue), "journal": .string(filename),
    ]) }
    init(wire: PolicyWireValue) throws {
        let v = try wire.object(keys: ["request", "scope", "boot", "release", "kind", "authority", "journal"])
        requestID = try CustodyWire.text(v["request"]); scopeID = try CustodyWire.text(v["scope"])
        bootID = try CustodyWire.text(v["boot"]); releaseSHA256 = try CustodyWire.text(v["release"])
        guard let kind = CustodyCommandKind(rawValue: try CustodyWire.text(v["kind"])),
              let mode = CustodyAuthorityMode(rawValue: try CustodyWire.text(v["authority"])) else { throw CustodyRecordError.invalidRecord }
        self.kind = kind; authority = mode
        guard [requestID, scopeID, bootID].allSatisfy(RunIdentity.isValid), CustodyWire.hex(releaseSHA256, bytes: 32),
              v["journal"] == .string(filename), mode.permits(kind: kind) else { throw CustodyRecordError.invalidRecord }
    }
}

struct CustodyCatalog: Equatable, Sendable {
    static let maximumEntries = 128
    static let maximumBytes = 131_072
    let revision: UInt64
    let entries: [CustodyCatalogEntry]
    static var initialized: Self { Self(revision: 1, entries: []) }
    private init(revision: UInt64, entries: [CustodyCatalogEntry]) { self.revision = revision; self.entries = entries }
    func reserving(_ journal: CustodyJournal) throws -> Self {
        try journal.validate()
        guard journal.phase == .prepared, !entries.contains(where: { $0.requestID == journal.binding.requestID }) else { throw CustodyRecordError.conflict }
        guard entries.count < Self.maximumEntries, revision < UInt64.max else { throw CustodyRecordError.busy }
        return Self(revision: revision + 1, entries: (entries + [CustodyCatalogEntry(journal)]).sorted { $0.requestID < $1.requestID })
    }
    func retiring(_ journal: CustodyJournal) throws -> Self {
        try journal.validate()
        guard journal.phase.isTerminal, entries.contains(CustodyCatalogEntry(journal)), revision < UInt64.max else { throw CustodyRecordError.conflict }
        return Self(revision: revision + 1, entries: entries.filter { $0.requestID != journal.binding.requestID })
    }
    func encode() throws -> Data {
        guard revision > 0, entries.count <= Self.maximumEntries,
              entries.map(\.requestID) == entries.map(\.requestID).sorted(), Set(entries.map(\.requestID)).count == entries.count else { throw CustodyRecordError.invalidRecord }
        return try CustodyWire.encode(.object([
            "schema": .string("shadow-sync-custody-catalog/v1"), "initialized": .string("shadow-sync-custody-initialized/v1"),
            "revision": .unsigned(revision), "entries": .array(entries.map(\.wire)),
        ]), maximum: Self.maximumBytes)
    }
    static func decode(_ data: Data) throws -> Self {
        do {
            let v = try CustodyWire.decode(data, maximum: maximumBytes).object(keys: ["schema", "initialized", "revision", "entries"])
            guard v["schema"] == .string("shadow-sync-custody-catalog/v1"), v["initialized"] == .string("shadow-sync-custody-initialized/v1") else { throw CustodyRecordError.invalidRecord }
            let result = Self(revision: try CustodyWire.uint(v["revision"]), entries: try CustodyWire.array(v["entries"]).map(CustodyCatalogEntry.init(wire:)))
            guard try result.encode() == data else { throw CustodyRecordError.invalidRecord }; return result
        } catch { throw CustodyRecordError.invalidRecord }
    }
}
