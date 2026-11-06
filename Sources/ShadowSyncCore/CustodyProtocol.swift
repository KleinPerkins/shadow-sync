import Foundation

// Parsing proves a closed representation, never executable, descriptor or lease authority.
// Command adapters and the custody context must authenticate these claims before use.
enum CustodyProtocolError: Error { case invalidMessage, invalidBudget, invalidSequence }

enum CustodyCommandKind: String, CaseIterable, Sendable {
    case repositoryGit = "repository-git", discoveryGit = "discovery-git"
    case systemGitConfig = "system-git-config", githubReadOnly = "github-read-only"
    case policyClassify = "policy-classify", retentionArchive = "retention-archive"
    case awaRemoval = "awa-removal", launchctlRead = "launchctl-read"
    case launchctlMutation = "launchctl-mutation", signatureCheck = "signature-check"

    // An upper ceiling only. The adapter supplies its existing, usually smaller limit.
    var maximumWorkSeconds: TimeInterval {
        switch self {
        case .repositoryGit, .retentionArchive, .awaRemoval: 120
        case .discoveryGit, .githubReadOnly: 15
        case .systemGitConfig: 5
        case .policyClassify: 2
        case .launchctlRead, .launchctlMutation, .signatureCheck: 10
        }
    }
}

enum CustodyAuthorityMode: String, Sendable {
    case read, mutation, lifecycleMutation = "lifecycle-mutation"
    case observation
    var needsOperation: Bool { self != .observation }
}

struct CustodyBinding: Equatable, Sendable {
    let requestID: String
    let scopeID: String
    let nonce: String
    let callerGeneration: String
    let trustedUID: UInt32
    let bootID: String
    let releaseSHA256: String

    func validate() throws {
        guard [requestID, scopeID, callerGeneration, bootID].allSatisfy(RunIdentity.isValid),
              CustodyWire.hex(nonce, bytes: 16), CustodyWire.hex(releaseSHA256, bytes: 32) else {
            throw CustodyProtocolError.invalidMessage
        }
    }

    fileprivate var wire: PolicyWireValue { .object([
        "request": .string(requestID), "scope": .string(scopeID), "nonce": .string(nonce),
        "generation": .string(callerGeneration), "uid": .unsigned(UInt64(trustedUID)),
        "boot": .string(bootID), "release": .string(releaseSHA256),
    ]) }

    // Closed decoding is shared with the inherited-resource verifier; it grants no authority.
    init(wire: PolicyWireValue) throws {
        let v = try wire.object(keys: ["request", "scope", "nonce", "generation", "uid", "boot", "release"])
        guard let uid = UInt32(exactly: try CustodyWire.uint(v["uid"])) else {
            throw CustodyProtocolError.invalidMessage
        }
        self.init(requestID: try CustodyWire.text(v["request"]), scopeID: try CustodyWire.text(v["scope"]),
                  nonce: try CustodyWire.text(v["nonce"]), callerGeneration: try CustodyWire.text(v["generation"]),
                  trustedUID: uid, bootID: try CustodyWire.text(v["boot"]),
                  releaseSHA256: try CustodyWire.text(v["release"]))
        try validate()
    }

    init(requestID: String, scopeID: String, nonce: String, callerGeneration: String,
         trustedUID: UInt32, bootID: String, releaseSHA256: String) {
        self.requestID = requestID; self.scopeID = scopeID; self.nonce = nonce
        self.callerGeneration = callerGeneration; self.trustedUID = trustedUID
        self.bootID = bootID; self.releaseSHA256 = releaseSHA256
    }
}

/// Absolute uptime nanoseconds in one verified boot. Nested preflights reuse this
/// value; receipt expiry returns pending and does not authorize dropping custody.
struct CustodyBudget: Equatable, Sendable {
    let issued: UInt64
    let work: UInt64
    let term: UInt64
    let kill: UInt64
    let receipt: UInt64

    static func make(kind: CustodyCommandKind, workSeconds: TimeInterval,
                     termSeconds: TimeInterval = 2, killSeconds: TimeInterval = 2,
                     receiptSeconds: TimeInterval = 1,
                     now: UInt64 = DispatchTime.now().uptimeNanoseconds) throws -> Self {
        guard workSeconds.isFinite, workSeconds > 0, workSeconds <= kind.maximumWorkSeconds else {
            throw CustodyProtocolError.invalidBudget
        }
        let workDuration = try duration(workSeconds)
        guard workDuration > 0 else { throw CustodyProtocolError.invalidBudget }
        let work = try add(now, workDuration)
        let term = try add(work, cleanupDuration(termSeconds, maximum: 2))
        let kill = try add(term, cleanupDuration(killSeconds, maximum: 2))
        return Self(issued: now, work: work, term: term, kill: kill,
                    receipt: try add(kill, cleanupDuration(receiptSeconds, maximum: 1)))
    }

    func validate(kind: CustodyCommandKind, permittedWorkSeconds: TimeInterval,
                  permittedTermSeconds: TimeInterval = 2, permittedKillSeconds: TimeInterval = 2,
                  permittedReceiptSeconds: TimeInterval = 1, now: UInt64) throws {
        guard permittedWorkSeconds.isFinite, permittedWorkSeconds > 0,
              permittedWorkSeconds <= kind.maximumWorkSeconds,
              issued <= now, now < work, issued < work, work <= term, term <= kill, kill <= receipt,
              work - issued <= (try Self.duration(permittedWorkSeconds)),
              term - work <= (try Self.cleanupDuration(permittedTermSeconds, maximum: 2)),
              kill - term <= (try Self.cleanupDuration(permittedKillSeconds, maximum: 2)),
              receipt - kill <= (try Self.cleanupDuration(permittedReceiptSeconds, maximum: 1)) else {
            throw CustodyProtocolError.invalidBudget
        }
    }

    /// Early cancellation clips all subsequent deadlines. Repeated calls never extend them.
    func draining(at now: UInt64) throws -> Self {
        guard now >= issued else { throw CustodyProtocolError.invalidBudget }
        let w = min(work, now)
        let t = min(term, try Self.add(w, term - work))
        let k = min(kill, try Self.add(t, kill - term))
        return Self(issued: issued, work: w, term: t, kill: k,
                    receipt: min(receipt, try Self.add(k, receipt - kill)))
    }

    /// A serial preflight is part of the original discovery transaction, not a
    /// new command timeout. Preserve every outer deadline, including shortened
    /// cleanup windows. The stage starts now so a late preflight may use the
    /// remaining work time, but never time beyond the original transaction.
    /// This value conveys timing only; it does not authorize a helper or child.
    func discoveryPreflight(_ stage: DiscoveryGitCommand.Preflight,
                            command: DiscoveryGitCommand,
                            now: UInt64 = DispatchTime.now().uptimeNanoseconds) throws -> Self {
        try validate(kind: .discoveryGit, permittedWorkSeconds: command.workSeconds, now: now)
        let ceiling = try Self.make(kind: stage.kind, workSeconds: stage.workSeconds, now: now)
        let boundedWork = min(work, ceiling.work)
        // Clip the intervals as well as the endpoints. Otherwise an early
        // two-second preflight could regain two seconds of cleanup even when
        // its enclosing transaction explicitly permits none. These validated
        // nanosecond differences are already scaled; do not scale them again.
        let boundedTerm = min(term, try Self.add(boundedWork,
            min(term - work, ceiling.term - ceiling.work)))
        let boundedKill = min(kill, try Self.add(boundedTerm,
            min(kill - term, ceiling.kill - ceiling.term)))
        let boundedReceipt = min(receipt, try Self.add(boundedKill,
            min(receipt - kill, ceiling.receipt - ceiling.kill)))
        let bounded = Self(issued: now, work: boundedWork, term: boundedTerm,
                           kill: boundedKill, receipt: boundedReceipt)
        try bounded.validate(kind: stage.kind, permittedWorkSeconds: stage.workSeconds, now: now)
        return bounded
    }

    private static func cleanupDuration(_ seconds: TimeInterval, maximum: TimeInterval) throws -> UInt64 {
        guard seconds.isFinite, seconds >= 0, seconds <= maximum else { throw CustodyProtocolError.invalidBudget }
        return try duration(seconds)
    }
    private static func duration(_ seconds: TimeInterval) throws -> UInt64 {
        let ns = ChildProcessBudget.seconds(seconds) * 1_000_000_000
        guard ns.isFinite, ns >= 0, ns < Double(UInt64.max) else { throw CustodyProtocolError.invalidBudget }
        return UInt64(ns)
    }
    private static func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw CustodyProtocolError.invalidBudget }
        return value
    }

    var wire: PolicyWireValue { .object([
        "issued": .unsigned(issued), "work": .unsigned(work), "term": .unsigned(term),
        "kill": .unsigned(kill), "receipt": .unsigned(receipt),
    ]) }
    init(wire: PolicyWireValue) throws {
        let v = try wire.object(keys: ["issued", "work", "term", "kill", "receipt"])
        self.init(issued: try CustodyWire.uint(v["issued"]), work: try CustodyWire.uint(v["work"]),
                  term: try CustodyWire.uint(v["term"]), kill: try CustodyWire.uint(v["kill"]),
                  receipt: try CustodyWire.uint(v["receipt"]))
    }
    private init(issued: UInt64, work: UInt64, term: UInt64, kill: UInt64, receipt: UInt64) {
        self.issued = issued; self.work = work; self.term = term; self.kill = kill; self.receipt = receipt
    }
}

struct CustodyDescriptorClaim: Equatable, Sendable {
    enum Role: String, CaseIterable, Sendable {
        case request, control, status, state, namespace, gitDirectory = "git-directory"
        case gitFile = "git-file", lifecycle, operation, run, input, code, workingDirectory = "working-directory"
        case traceOutput = "trace-output"
        var number: UInt64 {
            switch self {
            case .request: 190; case .control: 191; case .status: 192; case .state: 193
            case .namespace: 194; case .gitDirectory: 195; case .gitFile: 196
            case .lifecycle: 197; case .operation: 198; case .run: 199
            case .input: 8; case .code: 9; case .workingDirectory: 200; case .traceOutput: 7
            }
        }
    }
    enum Access: String, Sendable { case read, write, readWrite = "read-write" }
    let role: Role
    let device: UInt64
    let inode: UInt64
    let uid: UInt32
    let mode: UInt32
    let links: UInt64
    let access: Access

    var wire: PolicyWireValue { .object([
        "role": .string(role.rawValue), "fd": .unsigned(role.number), "device": .unsigned(device),
        "inode": .unsigned(inode), "uid": .unsigned(UInt64(uid)), "mode": .unsigned(UInt64(mode)),
        "links": .unsigned(links), "access": .string(access.rawValue),
    ]) }
    init(wire: PolicyWireValue) throws {
        let v = try wire.object(keys: ["role", "fd", "device", "inode", "uid", "mode", "links", "access"])
        guard let role = Role(rawValue: try CustodyWire.text(v["role"])),
              try CustodyWire.uint(v["fd"]) == role.number,
              let access = Access(rawValue: try CustodyWire.text(v["access"])),
              let uid = UInt32(exactly: try CustodyWire.uint(v["uid"])),
              let mode = UInt32(exactly: try CustodyWire.uint(v["mode"])), mode <= 0xffff else {
            throw CustodyProtocolError.invalidMessage
        }
        self.init(role: role, device: try CustodyWire.uint(v["device"]), inode: try CustodyWire.uint(v["inode"]),
                  uid: uid, mode: mode, links: try CustodyWire.uint(v["links"]), access: access)
    }
    init(role: Role, device: UInt64, inode: UInt64, uid: UInt32, mode: UInt32, links: UInt64, access: Access) {
        self.role = role; self.device = device; self.inode = inode; self.uid = uid
        self.mode = mode; self.links = links; self.access = access
    }
}

/// This deliberately has no executable field and no execute method. Arguments and
/// environment remain untrusted until a qualified command-kind adapter accepts them.
struct UnvalidatedCustodyRequest: Equatable, Sendable {
    let binding: CustodyBinding
    let kind: CustodyCommandKind
    let authority: CustodyAuthorityMode
    let arguments: [String]
    let environment: [String: String]
    let budget: CustodyBudget
    let stdoutLimit: UInt64
    let stderrLimit: UInt64
    let inputSHA256: String?
    let resourcesSHA256: String
    let descriptors: [CustodyDescriptorClaim]

    // Discovery alone owns a third stream. Its fixed bound is part of the
    // closed adapter, never a caller-selected diagnostic capability.
    var traceLimit: UInt64 {
        descriptors.contains(where: { $0.role == .traceOutput })
            ? UInt64(DiscoveryGitCommand.traceLimit) : 0
    }

    func encode() throws -> Data {
        try validateShape()
        return try CustodyWire.encode(wire, maximum: 1_048_576)
    }

    static func decode(_ data: Data, expected: CustodyBinding, permittedWorkSeconds: TimeInterval,
                       permittedTermSeconds: TimeInterval = 2, permittedKillSeconds: TimeInterval = 2,
                       permittedReceiptSeconds: TimeInterval = 1,
                       now: UInt64 = DispatchTime.now().uptimeNanoseconds) throws -> Self {
        do {
            try expected.validate()
            let v = try CustodyWire.decode(data, maximum: 1_048_576).object(keys: [
                "schema", "binding", "command", "budget", "limits", "descriptors",
            ])
            guard v["schema"] == .string("shadow-sync-custody-request/v1") else { throw CustodyProtocolError.invalidMessage }
            let binding = try CustodyBinding(wire: CustodyWire.required(v["binding"]))
            guard binding == expected else { throw CustodyProtocolError.invalidMessage }
            let c = try CustodyWire.required(v["command"]).object(keys: [
                "kind", "authority", "arguments", "environment", "input", "resources",
            ])
            guard let kind = CustodyCommandKind(rawValue: try CustodyWire.text(c["kind"])),
                  let authority = CustodyAuthorityMode(rawValue: try CustodyWire.text(c["authority"])) else {
                throw CustodyProtocolError.invalidMessage
            }
            let arguments = try CustodyWire.array(c["arguments"]).map { try CustodyWire.text($0) }
            var environment: [String: String] = [:]
            var keys: [String] = []
            for row in try CustodyWire.array(c["environment"]) {
                let e = try row.object(keys: ["key", "value"])
                let key = try CustodyWire.text(e["key"])
                guard environment[key] == nil else { throw CustodyProtocolError.invalidMessage }
                keys.append(key); environment[key] = try CustodyWire.text(e["value"])
            }
            guard keys == keys.sorted(by: CustodyWire.less) else { throw CustodyProtocolError.invalidMessage }
            let limits = try CustodyWire.required(v["limits"]).object(keys: ["stdout", "stderr"])
            let request = Self(binding: binding, kind: kind, authority: authority, arguments: arguments,
                environment: environment, budget: try CustodyBudget(wire: CustodyWire.required(v["budget"])),
                stdoutLimit: try CustodyWire.uint(limits["stdout"]), stderrLimit: try CustodyWire.uint(limits["stderr"]),
                inputSHA256: try CustodyWire.optionalText(c["input"]), resourcesSHA256: try CustodyWire.text(c["resources"]),
                descriptors: try CustodyWire.array(v["descriptors"]).map { try CustodyDescriptorClaim(wire: $0) })
            try request.validateShape()
            try request.budget.validate(kind: kind, permittedWorkSeconds: permittedWorkSeconds,
                permittedTermSeconds: permittedTermSeconds, permittedKillSeconds: permittedKillSeconds,
                permittedReceiptSeconds: permittedReceiptSeconds, now: now)
            return request
        } catch { throw CustodyProtocolError.invalidMessage }
    }

    private func validateShape() throws {
        try binding.validate()
        let roles = descriptors.map(\.role)
        let required: Set<CustodyDescriptorClaim.Role> = [.request, .control, .status, .state, .namespace, .lifecycle, .workingDirectory]
        guard arguments.count <= 256, arguments.allSatisfy({ CustodyWire.string($0, maximum: 65_536) }),
              environment.count <= 128, environment.allSatisfy({ key, value in
                  !key.isEmpty && key.utf8.count <= 128 && key.utf8.allSatisfy {
                      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
                  } && CustodyWire.string(value, maximum: 65_536)
              }), stdoutLimit > 0, stderrLimit > 0, stdoutLimit <= 33_554_432, stderrLimit <= 33_554_432,
              inputSHA256 == nil || CustodyWire.hex(inputSHA256!, bytes: 32),
              CustodyWire.hex(resourcesSHA256, bytes: 32),
              Set(roles).count == roles.count, required.isSubset(of: Set(roles)),
              roles.map(\.number) == roles.map(\.number).sorted(),
              Set(roles).contains(.operation) == authority.needsOperation,
              !roles.contains(.run) || authority == .mutation,
              authority != .observation || [.launchctlRead, .signatureCheck].contains(kind),
              kind != .launchctlMutation || authority == .lifecycleMutation,
              !roles.contains(.traceOutput) || kind == .discoveryGit,
              descriptors.allSatisfy({ $0.mode <= 0xffff }) else { throw CustodyProtocolError.invalidMessage }
        // File types, ownership, ACLs, link policy, standard streams, exact allowed
        // roles and per-kind limits are authenticated by the adapter, not this parser.
    }

    private var wire: PolicyWireValue { .object([
        "schema": .string("shadow-sync-custody-request/v1"), "binding": binding.wire,
        "command": .object(["kind": .string(kind.rawValue), "authority": .string(authority.rawValue),
            "arguments": .array(arguments.map(PolicyWireValue.string)),
            "environment": .array(environment.keys.sorted(by: CustodyWire.less).map {
                .object(["key": .string($0), "value": .string(environment[$0]!)])
            }), "input": inputSHA256.map(PolicyWireValue.string) ?? .null, "resources": .string(resourcesSHA256)]),
        "budget": budget.wire, "limits": .object(["stdout": .unsigned(stdoutLimit), "stderr": .unsigned(stderrLimit)]),
        "descriptors": .array(descriptors.map(\.wire)),
    ]) }
}

struct CustodyMessage: Equatable, Sendable {
    enum Channel: String, Sendable { case control, status }
    enum Event: String, Sendable { case admit, cancel, ready, pending = "cleanup-pending", terminal }
    enum Outcome: String, Sendable {
        case completed, failed = "command-failed", refused = "admission-refused"
        case cancelled = "cancelled-drained", timedOut = "timed-out-drained"
    }
    let binding: CustodyBinding
    let sequence: UInt64
    let event: Event
    let outcome: Outcome?
    let waitStatus: UInt32?
    let receiptSHA256: String?

    var channel: Channel { [.admit, .cancel].contains(event) ? .control : .status }

    func encode() throws -> Data {
        try validate()
        return try CustodyWire.encode(.object([
            "schema": .string("shadow-sync-custody-\(channel.rawValue)/v1"), "binding": binding.wire,
            "sequence": .unsigned(sequence), "event": .string(event.rawValue),
            "outcome": outcome.map { .string($0.rawValue) } ?? .null,
            "wait_status": waitStatus.map { .unsigned(UInt64($0)) } ?? .null,
            "receipt": receiptSHA256.map(PolicyWireValue.string) ?? .null,
        ]), maximum: 16_384)
    }

    static func decode(_ data: Data, expected: CustodyBinding, channel: Channel) throws -> Self {
        do {
            try expected.validate()
            let v = try CustodyWire.decode(data, maximum: 16_384).object(keys: [
                "schema", "binding", "sequence", "event", "outcome", "wait_status", "receipt",
            ])
            guard v["schema"] == .string("shadow-sync-custody-\(channel.rawValue)/v1"),
                  let event = Event(rawValue: try CustodyWire.text(v["event"])) else { throw CustodyProtocolError.invalidMessage }
            let binding = try CustodyBinding(wire: CustodyWire.required(v["binding"]))
            guard binding == expected else { throw CustodyProtocolError.invalidMessage }
            let outcomeText = try CustodyWire.optionalText(v["outcome"])
            let outcome = outcomeText.flatMap(Outcome.init(rawValue:))
            guard outcomeText == nil || outcome != nil else { throw CustodyProtocolError.invalidMessage }
            let status: UInt32?
            if v["wait_status"] == .null { status = nil }
            else {
                guard let n = UInt32(exactly: try CustodyWire.uint(v["wait_status"])) else { throw CustodyProtocolError.invalidMessage }
                status = n
            }
            let message = Self(binding: binding, sequence: try CustodyWire.uint(v["sequence"]), event: event,
                outcome: outcome, waitStatus: status, receiptSHA256: try CustodyWire.optionalText(v["receipt"]))
            guard message.channel == channel else { throw CustodyProtocolError.invalidMessage }
            try message.validate()
            return message
        } catch { throw CustodyProtocolError.invalidMessage }
    }

    private func validate() throws {
        try binding.validate()
        guard sequence < UInt64.max else { throw CustodyProtocolError.invalidMessage }
        if event == .terminal {
            guard let outcome, let digest = receiptSHA256, CustodyWire.hex(digest, bytes: 32),
                  (outcome != .completed || waitStatus == 0),
                  (outcome != .failed || waitStatus != nil),
                  (outcome != .refused || waitStatus != 0),
                  waitStatus.map({ $0 <= 0xffff && ($0 & 0x7f) < 0x7f }) ?? true else { throw CustodyProtocolError.invalidMessage }
        } else if outcome != nil || waitStatus != nil || receiptSHA256 != nil { throw CustodyProtocolError.invalidMessage }
    }
}

/// Four-byte big-endian size. At most one bounded frame is retained; EOF with a
/// partial frame poisons the stream. Callers bound each read and drain frames serially.
struct CustodyFrameDecoder {
    private var bytes = Data()
    private var length: Int?
    private var closed = false

    static func frame(_ message: Data) throws -> Data {
        guard !message.isEmpty, message.count <= 16_384 else { throw CustodyProtocolError.invalidMessage }
        let n = UInt32(message.count)
        return Data([UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]) + message
    }

    mutating func append(_ chunk: Data) throws -> [Data] {
        guard !closed, chunk.count <= 16_388 else { closed = true; throw CustodyProtocolError.invalidMessage }
        var frames: [Data] = []
        for byte in chunk {
            bytes.append(byte)
            if length == nil && bytes.count == 4 {
                let n = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard n > 0, n <= 16_384 else { closed = true; bytes.removeAll(); throw CustodyProtocolError.invalidMessage }
                length = Int(n); bytes.removeAll(keepingCapacity: true)
            } else if let length, bytes.count == length {
                frames.append(bytes); bytes = Data(); self.length = nil
            }
        }
        return frames
    }

    mutating func finish() throws {
        let complete = !closed && bytes.isEmpty && length == nil
        closed = true; bytes.removeAll()
        guard complete else { throw CustodyProtocolError.invalidMessage }
    }
}

/// Value-state checker, confined to the custodian event loop. It grants no signal
/// capability and cannot replace scope revalidation or durable journal transitions.
struct CustodyAdmissionState {
    enum Phase: Equatable { case preparing, ready, admitted, draining, terminal }
    private(set) var phase: Phase = .preparing
    private(set) var admitted = false
    private var nextControl: UInt64 = 0
    private var nextStatus: UInt64 = 0
    let binding: CustodyBinding
    private(set) var budget: CustodyBudget

    init(binding: CustodyBinding, budget: CustodyBudget) throws {
        try binding.validate(); self.binding = binding; self.budget = budget
    }

    mutating func closeAdmission(now: UInt64) throws {
        guard phase != .terminal else { throw CustodyProtocolError.invalidSequence }
        phase = .draining
        budget = try budget.draining(at: now)
    }

    mutating func accept(_ message: CustodyMessage, now: UInt64) throws {
        do {
            _ = try message.encode()
            guard message.binding == binding, phase != .terminal, now >= budget.issued else { throw CustodyProtocolError.invalidSequence }
            let control = message.channel == .control
            guard message.sequence == (control ? nextControl : nextStatus) else { throw CustodyProtocolError.invalidSequence }
            if now >= budget.work && phase != .draining { try closeAdmission(now: now) }
            switch message.event {
            case .ready:
                // Cancellation may beat the helper's initial ready bytes. Accept
                // that one observation without reopening target admission.
                guard phase == .preparing || (phase == .draining && !admitted && nextStatus == 0) else {
                    throw CustodyProtocolError.invalidSequence
                }
                if phase == .preparing { phase = .ready }
            case .admit:
                guard phase == .ready, !admitted else { throw CustodyProtocolError.invalidSequence }
                admitted = true; phase = .admitted
            case .cancel: try closeAdmission(now: now)
            case .pending:
                // The helper may discover a fault before the caller does. This
                // notification closes admission; it can never reopen it.
                try closeAdmission(now: now)
            case .terminal:
                switch message.outcome! {
                case .completed:
                    // Work may have finished before cancellation/deadline while
                    // durable receipt delivery finishes afterward. This accepts
                    // only protocol shape; actual retirement still verifies the
                    // helper-owned terminal journal and exact reap evidence.
                    guard admitted && (phase == .admitted || phase == .draining) else { throw CustodyProtocolError.invalidSequence }
                case .failed:
                    guard admitted && (phase == .admitted || phase == .draining) else { throw CustodyProtocolError.invalidSequence }
                case .refused:
                    // Admission authorizes suspended construction, not target
                    // execution. Its last validation may still refuse/drain.
                    guard phase != .terminal else { throw CustodyProtocolError.invalidSequence }
                case .cancelled:
                    guard phase == .draining else { throw CustodyProtocolError.invalidSequence }
                case .timedOut:
                    // A serial preflight can exhaust its smaller work ceiling
                    // before the caller's overall deadline. This accepts only
                    // the status shape; retirement still requires the matching
                    // durable helper journal, exact reap and complete streams.
                    guard admitted && (phase == .admitted || phase == .draining) else {
                        throw CustodyProtocolError.invalidSequence
                    }
                }
                phase = .terminal
            }
            if control { nextControl += 1 } else { nextStatus += 1 }
        } catch {
            if phase != .terminal { phase = .draining; budget = (try? budget.draining(at: now)) ?? budget }
            throw CustodyProtocolError.invalidSequence
        }
    }

    // Invoke only in the serialized final transition after durable executing state,
    // all ready control/EOF bytes and fresh scope/resource/publisher validation.
    mutating func permitsResume(now: UInt64) throws -> Bool {
        guard now >= budget.issued else { try closeAdmission(now: budget.issued); return false }
        if now >= budget.work && phase != .terminal { try closeAdmission(now: now) }
        return phase == .admitted && now < budget.work
    }
}

enum CustodyWire {
    static func required(_ v: PolicyWireValue?) throws -> PolicyWireValue {
        guard let v else { throw CustodyProtocolError.invalidMessage }; return v
    }
    static func text(_ v: PolicyWireValue?) throws -> String {
        guard case let .string(s) = v else { throw CustodyProtocolError.invalidMessage }; return s
    }
    static func optionalText(_ v: PolicyWireValue?) throws -> String? { v == .null ? nil : try text(v) }
    static func uint(_ v: PolicyWireValue?) throws -> UInt64 {
        guard case let .unsigned(n) = v else { throw CustodyProtocolError.invalidMessage }; return n
    }
    static func array(_ v: PolicyWireValue?) throws -> [PolicyWireValue] {
        guard case let .array(a) = v else { throw CustodyProtocolError.invalidMessage }; return a
    }
    static func string(_ s: String, maximum: Int) -> Bool { s.utf8.count <= maximum && !s.utf8.contains(0) }
    static func hex(_ s: String, bytes: Int) -> Bool {
        s.utf8.count == bytes * 2 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func less(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }
    static func decode(_ data: Data, maximum: Int) throws -> PolicyWireValue {
        guard data.count <= maximum else { throw CustodyProtocolError.invalidMessage }
        var parser = try PolicyWireParser(data, profile: .configuration)
        let value = try parser.parse()
        guard try encode(value, maximum: maximum) == data else { throw CustodyProtocolError.invalidMessage }
        return value
    }
    static func encode(_ value: PolicyWireValue, maximum: Int) throws -> Data {
        var result = Data()
        func put(_ s: String) throws {
            guard s.utf8.count <= maximum - result.count else { throw CustodyProtocolError.invalidMessage }
            result.append(contentsOf: s.utf8)
        }
        func render(_ v: PolicyWireValue) throws {
            switch v {
            case let .object(o):
                try put("{")
                for (i, key) in o.keys.sorted(by: less).enumerated() {
                    if i > 0 { try put(",") }; try render(.string(key)); try put(":"); try render(o[key]!)
                }
                try put("}")
            case let .array(a):
                try put("["); for (i, v) in a.enumerated() { if i > 0 { try put(",") }; try render(v) }; try put("]")
            case let .string(s):
                try put("\"")
                for scalar in s.unicodeScalars {
                    switch scalar.value {
                    case 34: try put("\\\""); case 92: try put("\\\\")
                    case 0..<32: try put(String(format: "\\u%04x", scalar.value))
                    default: try put(String(scalar))
                    }
                }
                try put("\"")
            case let .unsigned(n): try put(String(n))
            case let .boolean(b): try put(b ? "true" : "false")
            case .null: try put("null")
            }
        }
        try render(value)
        return result
    }
}
