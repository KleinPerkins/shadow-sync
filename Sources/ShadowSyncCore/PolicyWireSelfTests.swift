#if SHADOW_SYNC_TESTING
import Foundation

public enum PolicyWireSelfTestRunner {
    private enum Failure: Error { case message(String) }
    private static let nonce = String(repeating: "a", count: 32)
    private static let binding = String(repeating: "b", count: 64)
    private static let policy = String(repeating: "c", count: 64)
    private static let module = String(repeating: "d", count: 64)
    private static func expectation(_ count: Int = 2) -> ExpectedPolicyResponse {
        ExpectedPolicyResponse(nonce: nonce, bindingSHA256: binding, policySHA256: policy,
                               moduleSHA256: module, candidateCount: count)
    }
    private static func fixture(_ count: Int = 2) -> [String: Any] {
        ["schema": "shadow-sync-policy-batch-response/v1", "nonce": nonce,
         "binding_sha256": binding, "policy_sha256": policy, "module_sha256": module,
         "results": (0..<count).map { ["index": $0, "matched": false, "kind": "none", "policy_valid": true] }]
    }
    private static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure.message(message) }
    }
    private static func reject(_ data: Data, expected: ExpectedPolicyResponse = expectation()) throws {
        do {
            _ = try PolicyResponseDecoder.decode(data, expected: expected)
            throw Failure.message("invalid response was accepted")
        } catch PolicyProtocolError.invalidResponse { }
    }
    private static func reject(_ object: [String: Any], expected: ExpectedPolicyResponse = expectation()) throws {
        try reject(encode(object), expected: expected)
    }
    private static func rows(_ object: [String: Any]) -> [[String: Any]] { object["results"] as! [[String: Any]] }

    public static func runAll(onPass: (String) -> Void) throws {
        func run(_ name: String, _ operation: () throws -> Void) throws {
            try RuntimeFixtureSession.withCase("POLICY-WIRE-" + name) { try operation() }
            onPass("POLICY-WIRE-" + name)
        }
        try run("exact-allow-and-deny") {
            var object = fixture(); var entries = rows(object)
            entries[1].updateValue(true, forKey: "matched")
            entries[1].updateValue("exact_root", forKey: "kind"); object["results"] = entries
            let result = try PolicyResponseDecoder.decode(encode(object), expected: expectation())
            try require(result.count == 2 && result[0].allowsCandidateAccess && !result[1].allowsCandidateAccess,
                        "exact allow/deny interpretation failed")
        }
        try run("digest-nonce-schema-binding") {
            for key in ["schema", "nonce", "binding_sha256", "policy_sha256", "module_sha256"] {
                var object = fixture(); object[key] = "changed"; try reject(object)
            }
        }
        try run("closed-root-and-row") {
            for key in fixture().keys { var object = fixture(); object.removeValue(forKey: key); try reject(object) }
            var object = fixture(); object["extra"] = true; try reject(object)
            for key in rows(fixture())[0].keys {
                object = fixture(); var entries = rows(object); entries[0].removeValue(forKey: key)
                object["results"] = entries; try reject(object)
            }
            object = fixture(); var entries = rows(object); entries[0]["extra"] = false
            object["results"] = entries; try reject(object)
        }
        try run("complete-ordered-indexes") {
            var object = fixture(); object["results"] = Array(rows(object).reversed()); try reject(object)
            object = fixture(); object["results"] = [rows(object)[0], rows(object)[0]]; try reject(object)
            object = fixture(); object["results"] = [rows(object)[0]]; try reject(object)
            object = fixture(); object["results"] = []; try reject(object)
            try reject(fixture(3))
        }
        try run("strict-boolean-and-integer-types") {
            for key in ["matched", "policy_valid"] {
                for value: Any in [0, 1, "true", NSNull()] {
                    var object = fixture(); var entries = rows(object); entries[0][key] = value
                    object["results"] = entries; try reject(object)
                }
            }
            for value: Any in [true, false, "0", -1, NSNull()] {
                var object = fixture(); var entries = rows(object); entries[0]["index"] = value
                object["results"] = entries; try reject(object)
            }
            let text = String(decoding: try encode(fixture()), as: UTF8.self)
            for number in ["0.0", "0e0", "+0", "00", "18446744073709551616"] {
                try reject(Data(text.replacingOccurrences(of: "\"index\":0", with: "\"index\":" + number).utf8))
            }
        }
        try run("consistent-decision-meaning") {
            for values: (String, Bool, Bool) in [("none", true, true), ("exact_root", false, true),
                ("managed_namespace", true, false), ("invalid_candidate", false, true), ("unknown", true, true)] {
                var object = fixture(); var entries = rows(object)
                entries[0].merge(["kind": values.0, "matched": values.1, "policy_valid": values.2]) { _, new in new }
                object["results"] = entries; try reject(object)
            }
            for kind in ["exact_root", "managed_namespace", "invalid_candidate"] {
                var object = fixture(); var entries = rows(object)
                entries[1].merge(["kind": kind, "matched": true]) { _, new in new }; object["results"] = entries
                let result = try PolicyResponseDecoder.decode(encode(object), expected: expectation())
                try require(!result[1].allowsCandidateAccess, "blocked kind gained access")
            }
        }
        try run("invalid-policy-rejects-whole-batch") {
            var object = fixture(); var entries = rows(object)
            entries[1].merge(["kind": "invalid_policy", "matched": true, "policy_valid": false]) { _, new in new }
            object["results"] = entries; try reject(object)
        }
        try run("duplicate-and-escaped-duplicate-keys") {
            let text = String(decoding: try encode(fixture()), as: UTF8.self)
            for key in ["nonce", #"\u006eonce"#] {
                try reject(Data(("{\"" + key + "\":\"" + nonce + "\"," + text.dropFirst()).utf8))
            }
            try reject(Data(text.replacingOccurrences(of: "\"index\":0", with: "\"index\":0,\"index\":0").utf8))
        }
        try run("malformed-and-contaminated-json") {
            let valid = try encode(fixture())
            for raw in [Data(), Data("{}".utf8), Data("null".utf8), Data("[]".utf8), Data([255]),
                        valid + Data("debug".utf8), valid + valid, Data("noise".utf8) + valid,
                        Data("{\"schema\":\"\\uD800\"}".utf8), Data("{\"schema\":NaN}".utf8)] {
                try reject(raw)
            }
            let result = try PolicyResponseDecoder.decode(Data(" \n\t".utf8) + valid + Data("\n".utf8), expected: expectation())
            try require(result.count == 2, "valid JSON whitespace failed")
        }
        try run("resource-bounds") {
            try reject(Data(repeating: 32, count: 65_537))
            try reject(fixture(65), expected: expectation(65))
            try reject(fixture(0), expected: expectation(0))
            let result = try PolicyResponseDecoder.decode(encode(fixture(64)), expected: expectation(64))
            try require(result.count == 64 && result.allSatisfy(\.allowsCandidateAccess), "maximum legal batch failed")
            try reject(Data((String(repeating: "[", count: 8) + "0" + String(repeating: "]", count: 8)).utf8))
        }
        try run("caller-expectation-is-closed") {
            let malformed = ExpectedPolicyResponse(nonce: "bad", bindingSHA256: binding, policySHA256: policy,
                                                    moduleSHA256: module, candidateCount: 2)
            try reject(fixture(), expected: malformed)
            let uppercase = ExpectedPolicyResponse(nonce: nonce, bindingSHA256: binding.uppercased(),
                                                    policySHA256: policy, moduleSHA256: module, candidateCount: 2)
            try reject(fixture(), expected: uppercase)
        }
        try run("request-preserves-exact-candidate-text") {
            let paths = ["/fixture/space and \"quote\"", "/fixture/é", "/fixture/🧪"]
            let data = try PolicyRequestEncoder.encode(candidates: paths, nonce: nonce, bindingSHA256: binding)
            let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            try require(Set(value.keys) == ["schema", "nonce", "binding_sha256", "candidates"], "open request shape")
            try require(value["schema"] as? String == "shadow-sync-policy-batch-request/v1"
                && value["nonce"] as? String == nonce && value["binding_sha256"] as? String == binding
                && value["candidates"] as? [String] == paths, "request changed candidate identity")
        }
        try run("request-refuses-whole-invalid-batch") {
            for paths in [[], ["/"], ["relative"], ["/a/.."], ["/a/./b"], ["//a"], ["/a/"],
                          ["/a\\b"], ["/a\n"], ["/a\0"], ["/a\u{7f}"], ["/a", "/a"],
                          ["/valid", "/invalid/../path"], (0..<65).map { "/fixture/\($0)" },
                          ["/" + String(repeating: "x", count: 4096)]] {
                var refused = false
                do { _ = try PolicyRequestEncoder.encode(candidates: paths, nonce: nonce, bindingSHA256: binding) }
                catch PolicyProtocolError.invalidRequest { refused = true }
                try require(refused, "unsafe request batch was encoded")
            }
        }
        try run("request-binds-nonce-and-size-budget") {
            for (n, b) in [("", binding), (nonce.uppercased(), binding), (nonce, "bad"), (nonce, binding.uppercased())] {
                var refused = false
                do { _ = try PolicyRequestEncoder.encode(candidates: ["/fixture/a"], nonce: n, bindingSHA256: b) }
                catch PolicyProtocolError.invalidRequest { refused = true }
                try require(refused, "bad request binding was accepted")
            }
            let legal = try PolicyRequestEncoder.encode(candidates: (0..<64).map { "/fixture/\($0)" },
                                                        nonce: nonce, bindingSHA256: binding)
            try require(legal.count < 262_144, "legal batch unexpectedly too large")
            var refused = false
            do {
                _ = try PolicyRequestEncoder.encode(candidates: (0..<64).map {
                    "/" + String(repeating: "\"", count: 4000) + String($0)
                }, nonce: nonce, bindingSHA256: binding)
            } catch PolicyProtocolError.invalidRequest { refused = true }
            try require(refused, "escaped wire payload exceeded the bound")
        }
        try run("request-uses-byte-path-syntax") {
            for path in ["/a\\\u{301}b", "/a//\u{301}b", "/a/../\u{301}b"] {
                var refused = false
                do { _ = try PolicyRequestEncoder.encode(candidates: [path], nonce: nonce, bindingSHA256: binding) }
                catch PolicyProtocolError.invalidRequest { refused = true }
                try require(refused, "combining mark hid invalid request syntax")
            }
            let paths = ["/\u{301}valid", "/fixture/é", "/fixture/e\u{301}"]
            let data = try PolicyRequestEncoder.encode(candidates: paths, nonce: nonce, bindingSHA256: binding)
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let actual = object["candidates"] as! [String]
            try require(actual.map { Array($0.utf8) } == paths.map { Array($0.utf8) }, "candidate bytes normalized")
        }
    }
}
#endif
