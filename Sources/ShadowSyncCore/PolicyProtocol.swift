import Foundation

enum PolicyProtocolError: Error { case invalidResponse, invalidRequest }

struct PolicyDecision: Equatable, Sendable {
    enum Kind: String, Sendable {
        case none, exactRoot = "exact_root", managedNamespace = "managed_namespace"
        case invalidCandidate = "invalid_candidate", invalidPolicy = "invalid_policy"
    }
    let matched: Bool
    let kind: Kind
    let policyValid: Bool
    var allowsCandidateAccess: Bool { !matched && kind == .none && policyValid }
    fileprivate init(matched: Bool, kind: Kind, policyValid: Bool) {
        self.matched = matched; self.kind = kind; self.policyValid = policyValid
    }
}

struct ExpectedPolicyResponse: Sendable {
    let nonce: String
    let bindingSHA256: String
    let policySHA256: String
    let moduleSHA256: String
    let candidateCount: Int
}

enum PolicyResponseDecoder {
    static func decode(_ data: Data, expected: ExpectedPolicyResponse) throws -> [PolicyDecision] {
        func rejectUnless(_ condition: Bool) throws {
            guard condition else { throw PolicyProtocolError.invalidResponse }
        }
        func hex(_ value: String, count: Int) -> Bool {
            value.utf8.count == count && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
        }
        try rejectUnless(hex(expected.nonce, count: 32)
            && [expected.bindingSHA256, expected.policySHA256, expected.moduleSHA256].allSatisfy {
                hex($0, count: 64)
            } && (1...64).contains(expected.candidateCount))
        var parser = try PolicyWireParser(data)
        let root = try parser.parse().object(keys: [
            "schema", "nonce", "binding_sha256", "policy_sha256", "module_sha256", "results",
        ])
        for (key, expectedText) in [
            ("schema", "shadow-sync-policy-batch-response/v1"), ("nonce", expected.nonce),
            ("binding_sha256", expected.bindingSHA256), ("policy_sha256", expected.policySHA256),
            ("module_sha256", expected.moduleSHA256),
        ] {
            try rejectUnless(root[key] == .string(expectedText))
        }
        guard case let .array(rows) = root["results"] else { throw PolicyProtocolError.invalidResponse }
        try rejectUnless(rows.count == expected.candidateCount)
        var decisions: [PolicyDecision] = []
        for (index, raw) in rows.enumerated() {
            let row = try raw.object(keys: ["index", "matched", "kind", "policy_valid"])
            guard row["index"] == .unsigned(UInt64(index)),
                  case let .boolean(matched) = row["matched"],
                  case let .boolean(policyValid) = row["policy_valid"],
                  case let .string(kindString) = row["kind"],
                  let kind = PolicyDecision.Kind(rawValue: kindString) else {
                throw PolicyProtocolError.invalidResponse
            }
            let permittedShape: (Bool, Bool)
            switch kind {
            case .none: permittedShape = (false, true)
            case .exactRoot, .managedNamespace, .invalidCandidate: permittedShape = (true, true)
            case .invalidPolicy: permittedShape = (true, false)
            }
            try rejectUnless(matched == permittedShape.0 && policyValid == permittedShape.1)
            decisions.append(PolicyDecision(matched: matched, kind: kind, policyValid: policyValid))
        }
        // A globally invalid policy cannot yield a partially usable catalog.
        try rejectUnless(decisions.allSatisfy(\.policyValid))
        return decisions
    }
}

indirect enum PolicyWireValue: Equatable {
    case object([String: PolicyWireValue]), array([PolicyWireValue]), string(String)
    case boolean(Bool), unsigned(UInt64), null

    func object(keys: Set<String>) throws -> [String: PolicyWireValue] {
        guard case let .object(value) = self, Set(value.keys) == keys else {
            throw PolicyProtocolError.invalidResponse
        }
        return value
    }
}

/// Closed wire grammar: JSON objects/arrays/strings/booleans/null and unsigned
/// integer indexes. Reject duplicate keys before Foundation can discard them.
struct PolicyWireParser {
    enum Profile { case wire, configuration, bundleLayout, discoveryCustody }
    private let bytes: [UInt8]
    private let maximumStringBytes: Int
    private let maximumArrayCount: Int
    private let maximumObjectCount: Int
    private let maximumDepth: Int
    private var offset = 0

    init(_ data: Data, profile: Profile = .wire) throws {
        let maximumBytes = profile == .wire ? 65_536 : profile == .discoveryCustody ? 262_144 : 1_048_576
        guard !data.isEmpty, data.count <= maximumBytes, String(data: data, encoding: .utf8) != nil else {
            throw PolicyProtocolError.invalidResponse
        }
        bytes = Array(data)
        // Configuration fields enforce decoded bounds. Escaping a valid large
        // dispatcher must not reduce its permitted length; the document is capped.
        maximumStringBytes = profile == .wire ? 4096 : profile == .discoveryCustody ? 16_384 : 1_048_576
        maximumArrayCount = profile == .wire || profile == .discoveryCustody ? 64 : 256
        maximumObjectCount = profile == .bundleLayout ? 4096 : 16
        // Discovery's snapshot/configuration/contributors/file/identity leaf is
        // one level deeper. Existing policy/configuration grammar stays at six.
        maximumDepth = profile == .discoveryCustody ? 7 : 6
    }

    mutating func parse() throws -> PolicyWireValue {
        let value = try readValue(depth: 0)
        whitespace()
        guard offset == bytes.count else { throw PolicyProtocolError.invalidResponse }
        return value
    }

    private mutating func whitespace() {
        while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        whitespace()
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1; return true
    }

    private mutating func readValue(depth: Int) throws -> PolicyWireValue {
        whitespace()
        guard depth <= maximumDepth, offset < bytes.count else { throw PolicyProtocolError.invalidResponse }
        switch bytes[offset] {
        case 123:
            offset += 1
            var result: [String: PolicyWireValue] = [:]
            if take(125) { return .object(result) }
            while true {
                let key = try string()
                guard result[key] == nil, result.count < maximumObjectCount, take(58) else {
                    throw PolicyProtocolError.invalidResponse
                }
                result[key] = try readValue(depth: depth + 1)
                if take(125) { return .object(result) }
                guard take(44) else { throw PolicyProtocolError.invalidResponse }
            }
        case 91:
            offset += 1
            var result: [PolicyWireValue] = []
            if take(93) { return .array(result) }
            while true {
                guard result.count < maximumArrayCount else { throw PolicyProtocolError.invalidResponse }
                result.append(try readValue(depth: depth + 1))
                if take(93) { return .array(result) }
                guard take(44) else { throw PolicyProtocolError.invalidResponse }
            }
        case 34: return .string(try string())
        case 116: try literal("true"); return .boolean(true)
        case 102: try literal("false"); return .boolean(false)
        case 110: try literal("null"); return .null
        case 48...57:
            let start = offset
            while offset < bytes.count && (48...57).contains(bytes[offset]) { offset += 1 }
            guard offset - start <= 20, offset - start == 1 || bytes[start] != 48,
                  let value = UInt64(String(decoding: bytes[start..<offset], as: UTF8.self)) else {
                throw PolicyProtocolError.invalidResponse
            }
            return .unsigned(value)
        default: throw PolicyProtocolError.invalidResponse
        }
    }

    private mutating func literal(_ value: String) throws {
        let expected = Array(value.utf8)
        guard bytes.count - offset >= expected.count,
              Array(bytes[offset..<(offset + expected.count)]) == expected else {
            throw PolicyProtocolError.invalidResponse
        }
        offset += expected.count
    }

    private mutating func string() throws -> String {
        whitespace()
        let start = offset
        guard take(34) else { throw PolicyProtocolError.invalidResponse }
        while offset < bytes.count && offset - start <= maximumStringBytes {
            let byte = bytes[offset]; offset += 1
            if byte == 34 {
                do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) }
                catch { throw PolicyProtocolError.invalidResponse }
            }
            if byte == 92 {
                guard offset < bytes.count else { throw PolicyProtocolError.invalidResponse }
                offset += 1
            } else if byte < 32 { throw PolicyProtocolError.invalidResponse }
        }
        throw PolicyProtocolError.invalidResponse
    }
}

/// Validate the complete batch before creating input storage or accessing policy files.
enum PolicyRequestEncoder {
    static func encode(candidates: [String], nonce: String, bindingSHA256: String) throws -> Data {
        func hex(_ value: String, length: Int) -> Bool {
            value.utf8.count == length && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
        }
        guard (1...64).contains(candidates.count), Set(candidates.map { Array($0.utf8) }).count == candidates.count,
              hex(nonce, length: 32), hex(bindingSHA256, length: 64),
              candidates.allSatisfy(validCandidate) else {
            throw PolicyProtocolError.invalidRequest
        }
        let result = try JSONSerialization.data(withJSONObject: [
            "schema": "shadow-sync-policy-batch-request/v1", "nonce": nonce,
            "binding_sha256": bindingSHA256, "candidates": candidates,
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        guard result.count <= 262_144 else { throw PolicyProtocolError.invalidRequest }
        return result
    }

    private static func validCandidate(_ value: String) -> Bool {
        guard value.utf8.first == 47, value.utf8.count > 1, value.utf8.count <= 4096,
              !value.utf8.contains(92),
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return false
        }
        return value.utf8.dropFirst().split(separator: 47, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
