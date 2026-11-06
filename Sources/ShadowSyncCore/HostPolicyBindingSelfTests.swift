#if SHADOW_SYNC_TESTING
import Foundation

public enum HostPolicyBindingSelfTestRunner {
    private enum Failure: Error { case assertion(String) }

    public static func runAll(onPass: (String) -> Void) throws {
        let (revision, module, contractObject, binding, contract) = try RuntimeFixtureSession.withCaseValue("POLICY-BINDING-T01-qualified-contract-and-binding") {
            let revision = String(repeating: "a", count: 40)
            let module = String(repeating: "b", count: 64)
            let contractObject: [String: Any] = [
                "schema": "shadow-sync-awa-contract/v1", "status": "qualified",
                "release_revision": revision, "module_sha256": module,
            ]
            let binding: [String: Any] = [
                "schema": "shadow-sync-host-policy-binding/v1",
                "policy": ["path": "configuration/policy.yml", "sha256": String(repeating: "c", count: 64)],
                "projection": ["path": "configuration/projection.json", "sha256": String(repeating: "d", count: 64)],
                "awa": ["module_path": "runtime/engine/policy.py", "module_sha256": module,
                        "release_revision": revision],
            ]
            let contract = try QualifiedAWAContract.decode(json(contractObject))
            let decoded = try HostPolicyBinding.decode(json(binding), contract: contract)
            try require(decoded.policy.relativePath == "configuration/policy.yml"
                && decoded.projection.relativePath == "configuration/projection.json"
                && decoded.module.relativePath == "runtime/engine/policy.py"
                && decoded.module.sha256 == module && decoded.releaseRevision == revision,
                "valid binding changed")
            return (revision, module, contractObject, binding, contract)
        }
        onPass("POLICY-BINDING-T01-qualified-contract-and-binding")
        try RuntimeFixtureSession.withCase("POLICY-BINDING-T02-pending-and-malformed-contracts") {
            for (key, bad) in [
                ("status", "pending_release" as Any), ("status", "unknown"),
                ("status", true), ("release_revision", NSNull()),
                ("release_revision", String(repeating: "0", count: 40)),
                ("release_revision", revision.uppercased()), ("release_revision", revision + "a"),
                ("module_sha256", String(repeating: "0", count: 64)),
                ("module_sha256", "bad"), ("schema", "shadow-sync-awa-contract/v2"),
            ] {
                var badContract = contractObject; badContract[key] = bad
                try refuse { _ = try QualifiedAWAContract.decode(json(badContract)) }
            }
        }
        onPass("POLICY-BINDING-T02-pending-and-malformed-contracts")
        let original = try RuntimeFixtureSession.withCaseValue("POLICY-BINDING-T03-duplicate-and-escaped-keys") {
            let original = String(decoding: try json(binding), as: UTF8.self)
            for wire in [
                original.replacingOccurrences(of: "\"schema\":", with: "\"schema\":null,\"schema\":"),
                original.replacingOccurrences(of: "\"path\":", with: "\"path\":null,\"path\":"),
                original.replacingOccurrences(of: "\"sha256\":", with: "\"sha256\":null,\"sha\\u003256\":"),
            ] {
                try refuse { _ = try HostPolicyBinding.decode(Data(wire.utf8), contract: contract) }
            }
            let originalContract = String(decoding: try json(contractObject), as: UTF8.self)
            let duplicateContract = originalContract.replacingOccurrences(of: "\"status\":", with: "\"status\":null,\"status\":")
            try refuse { _ = try QualifiedAWAContract.decode(Data(duplicateContract.utf8)) }
            return original
        }
        onPass("POLICY-BINDING-T03-duplicate-and-escaped-keys")
        try RuntimeFixtureSession.withCase("POLICY-BINDING-T04-closed-shapes-and-exact-types") {
            for key in ["schema", "policy", "projection", "awa"] {
                var missing = binding; missing.removeValue(forKey: key)
                try refuse { _ = try HostPolicyBinding.decode(json(missing), contract: contract) }
                for wrong: Any in [NSNull(), true, 0, [], "text"] {
                    var mutated = binding; mutated[key] = wrong
                    try refuse { _ = try HostPolicyBinding.decode(json(mutated), contract: contract) }
                }
            }
            var extra = binding; extra["future"] = true
            try refuse { _ = try HostPolicyBinding.decode(json(extra), contract: contract) }
            for key in ["policy", "projection", "awa"] {
                var nested = binding[key] as! [String: Any]; nested["future"] = true
                var mutated = binding; mutated[key] = nested
                try refuse { _ = try HostPolicyBinding.decode(json(mutated), contract: contract) }
            }
        }
        onPass("POLICY-BINDING-T04-closed-shapes-and-exact-types")
        try RuntimeFixtureSession.withCase("POLICY-BINDING-T05-lexical-path-refusals") {
            for path in ["", "/absolute", "a//b", "a/", ".", "..", "a/./b", "a/../b",
                         "a\\b", "a\0b", "a\nb", "a\u{7f}b", String(repeating: "x", count: 4097),
                         Array(repeating: "x", count: 65).joined(separator: "/")] {
                for key in ["policy", "projection", "awa"] {
                    var nested = binding[key] as! [String: Any]
                    nested[key == "awa" ? "module_path" : "path"] = path
                    var mutated = binding; mutated[key] = nested
                    try refuse { _ = try HostPolicyBinding.decode(json(mutated), contract: contract) }
                }
            }
        }
        onPass("POLICY-BINDING-T05-lexical-path-refusals")
        try RuntimeFixtureSession.withCase("POLICY-BINDING-T06-pin-drift-and-distinct-payloads") {
            for (key, value) in [("release_revision", String(repeating: "e", count: 40)),
                                 ("module_sha256", String(repeating: "e", count: 64)),
                                 ("module_path", "configuration/policy.yml")] {
                var awa = binding["awa"] as! [String: Any]; awa[key] = value
                var mutated = binding; mutated["awa"] = awa
                try refuse { _ = try HostPolicyBinding.decode(json(mutated), contract: contract) }
            }
            var samePayload = binding; samePayload["projection"] = binding["policy"]
            try refuse { _ = try HostPolicyBinding.decode(json(samePayload), contract: contract) }
            for digest: Any in [true, NSNull(), 1, "", String(repeating: "0", count: 64), String(repeating: "F", count: 64)] {
                var item = binding["policy"] as! [String: Any]; item["sha256"] = digest
                var mutated = binding; mutated["policy"] = item
                try refuse { _ = try HostPolicyBinding.decode(json(mutated), contract: contract) }
            }
        }
        onPass("POLICY-BINDING-T06-pin-drift-and-distinct-payloads")
        try RuntimeFixtureSession.withCase("POLICY-BINDING-T07-wire-and-resource-bounds") {
            for data in [Data(), Data([0xff]), Data(original.utf8) + Data("{}".utf8),
                         Data(repeating: 32, count: 65_537), Data("{\"schema\":NaN}".utf8),
                         Data("[]".utf8), Data("null".utf8)] {
                try refuse { _ = try HostPolicyBinding.decode(data, contract: contract) }
            }
            try refuse { _ = try QualifiedAWAContract.decode(Data(repeating: 32, count: 16_385)) }
        }
        onPass("POLICY-BINDING-T07-wire-and-resource-bounds")
        try RuntimeFixtureSession.withCase("POLICY-BINDING-T08-neutral-refusal") {
            try require(String(describing: HostPolicyBindingError.unavailable)
                == "Repository policy configuration is unavailable.", "diagnostic leaked data")
        }
        onPass("POLICY-BINDING-T08-neutral-refusal")
        try RuntimeFixtureSession.withCase("POLICY-BINDING-T09-configuration-escaping-and-wire-isolation") {
            // Configuration has decoded-field bounds; JSON escaping must not shrink
            // those bounds, while the smaller child-response protocol stays bounded.
            let longestPath = String(repeating: "x", count: 4096)
            var longBinding = binding
            longBinding["policy"] = ["path": longestPath, "sha256": String(repeating: "c", count: 64)]
            let longWire = String(decoding: try json(longBinding), as: UTF8.self)
            for encoded in [longWire, longWire.replacingOccurrences(of: longestPath, with: String(repeating: "\\u0078", count: 4096))] {
                try require(try HostPolicyBinding.decode(Data(encoded.utf8), contract: contract).policy.relativePath == longestPath,
                            "escaped configuration path bound changed")
            }
            for wire in ["[" + Array(repeating: "0", count: 65).joined(separator: ",") + "]",
                         "\"" + String(repeating: "x", count: 4097) + "\""] {
                do {
                    var parser = try PolicyWireParser(Data(wire.utf8))
                    _ = try parser.parse()
                    throw Failure.assertion("configuration profile relaxed child wire bounds")
                } catch PolicyProtocolError.invalidResponse {}
            }
        }
        onPass("POLICY-BINDING-T09-configuration-escaping-and-wire-isolation")
        try RuntimeFixtureSession.withCase("POLICY-BINDING-T10-byte-delimited-path-syntax") {
            for path in ["/\u{301}absolute", "a\\\u{301}b", "a//\u{301}b"] {
                var bad = binding
                bad["policy"] = ["path": path, "sha256": String(repeating: "c", count: 64)]
                try refuse { _ = try HostPolicyBinding.decode(json(bad), contract: contract) }
            }
            var unicode = binding
            unicode["policy"] = ["path": "a/\u{301}b", "sha256": String(repeating: "c", count: 64)]
            try require(try HostPolicyBinding.decode(json(unicode), contract: contract).policy.relativePath.utf8.elementsEqual("a/\u{301}b".utf8),
                        "valid path byte identity changed")
            unicode["policy"] = ["path": "é", "sha256": String(repeating: "c", count: 64)]
            unicode["projection"] = ["path": "e\u{301}", "sha256": String(repeating: "d", count: 64)]
            _ = try HostPolicyBinding.decode(json(unicode), contract: contract)
        }
        onPass("POLICY-BINDING-T10-byte-delimited-path-syntax")
    }

    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.assertion(message) }
    }

    private static func refuse(_ operation: () throws -> Void) throws {
        do { try operation(); throw Failure.assertion("invalid binding accepted") }
        catch HostPolicyBindingError.unavailable {}
    }
}
#endif
