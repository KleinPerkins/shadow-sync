#if SHADOW_SYNC_TESTING
import CryptoKit
import Foundation

public enum HostPolicyProjectionSelfTestRunner {
    private enum Failure: Error { case assertion(String) }
    private static let policy: HostPolicyBinding.Payload = {
        let revision = String(repeating: "a", count: 40), module = String(repeating: "b", count: 64)
        let contract = try! QualifiedAWAContract.decode(json([
            "schema": "shadow-sync-awa-contract/v1", "status": "qualified",
            "release_revision": revision, "module_sha256": module,
        ]))
        return try! HostPolicyBinding.decode(json([
            "schema": "shadow-sync-host-policy-binding/v1",
            "policy": ["path": "policy.yml", "sha256": String(repeating: "a", count: 64)],
            "projection": ["path": "projection.json", "sha256": String(repeating: "c", count: 64)],
            "awa": ["module_path": "runtime/policy.py", "module_sha256": module, "release_revision": revision],
        ]), contract: contract).policy
    }()

    public static func runAll(onPass: (String) -> Void) throws {
        let base = try RuntimeFixtureSession.withCaseValue("POLICY-PROJECTION-T01-complete-neutral-projection") {
            let base = fixture()
            let value = try decode(base)
            try require(value.rootComponents == ["workspace"] && value.shelves == [["products"], ["tools"], ["reference"]]
                && value.paths.readOnly == ["reference/*"] && value.paths.writable == ["."]
                && value.hookDispatcher == Data("#!/bin/sh\nexit 0\n".utf8) && value.awaEvidence == nil,
                "valid projection changed")
            return base
        }
        onPass("POLICY-PROJECTION-T01-complete-neutral-projection")
        let wire = try RuntimeFixtureSession.withCaseValue("POLICY-PROJECTION-T02-closed-shapes-schema-and-duplicates") {
            for path in [[], ["source_inputs"], ["source_inputs", "worktree_policy"], ["governed_root"], ["path_policy"], ["hooks"]] {
                for extra in [true, false] {
                    let bad = mutate(base, path: path) { object in
                        if extra { object["unknown"] = true } else { object.removeValue(forKey: object.keys.sorted()[0]) }
                    }
                    try refuse { _ = try decode(bad) }
                }
            }
            var future = base; future["schema"] = "shadow-sync-host-policy-projection/v2"
            try refuse { _ = try decode(future) }
            let wire = String(decoding: try json(base), as: UTF8.self)
            for bad in [wire.replacingOccurrences(of: "\"schema\":", with: "\"schema\":null,\"schema\":"),
                        wire.replacingOccurrences(of: "\"sha256\":", with: "\"sha256\":null,\"sha\\u003256\":")] {
                try refuse { _ = try HostPolicyProjection.decode(Data(bad.utf8), policy: policy) }
            }
            return wire
        }
        onPass("POLICY-PROJECTION-T02-closed-shapes-schema-and-duplicates")
        try RuntimeFixtureSession.withCase("POLICY-PROJECTION-T03-policy-and-dispatcher-integrity") {
            for change: (String, Any) in [("sha256", String(repeating: "b", count: 64)), ("path", "other.yml")] {
                try refuse { _ = try decode(mutate(base, path: ["source_inputs", "worktree_policy"]) { $0[change.0] = change.1 }) }
            }
            for (path, replacement): ([String], [String: Any]) in [
                (["hooks"], ["dispatcher_base64": Data("other".utf8).base64EncodedString()]),
                (["hooks"], ["dispatcher_base64": "not base64"]),
                (["source_inputs", "hook_dispatcher"], ["sha256": String(repeating: "c", count: 64)]),
                (["source_inputs", "host_overlay"], ["path": "policy.yml"]),
            ] {
                try refuse { _ = try decode(mutate(base, path: path) { $0.merge(replacement) { _, new in new } }) }
            }
        }
        onPass("POLICY-PROJECTION-T03-policy-and-dispatcher-integrity")
        try RuntimeFixtureSession.withCase("POLICY-PROJECTION-T04-root-and-shelf-safety") {
            for (key, bad): (String, Any) in [
                ("components", []), ("components", [".."]), ("components", ["a/b"]), ("components", ["a\\b"]),
                ("components", ["a\n"]), ("components", ["~"]), ("display_label", "/other"),
                ("repository_id", "invalid"), ("repository_id", "OWNER/REPO"),
            ] {
                try refuse { _ = try decode(mutate(base, path: ["governed_root"]) { $0[key] = bad }) }
            }
            for bad in [[], [[".hidden"]], [["products"], ["products"]], [["products"], ["products", "nested"]],
                        [[".."]], [["a", "b", "c", "d"]], Array(repeating: ["a"], count: 33)] {
                var changed = base; changed["shelves"] = bad
                try refuse { _ = try decode(changed) }
            }
        }
        onPass("POLICY-PROJECTION-T04-root-and-shelf-safety")
        try RuntimeFixtureSession.withCase("POLICY-PROJECTION-T05-path-restrictions-cannot-be-overridden") {
            for bad in ["../x", "/x", "a//b", "a/?", "**", "a/*/b", "a/[x]", "", ".hidden"] {
                try refuse { _ = try decode(mutate(base, path: ["path_policy"]) { $0["excluded"] = [bad] }) }
            }
            for bad in [["reference/item"], ["generated"], ["excluded/child"], ["*"]] {
                try refuse { _ = try decode(mutate(base, path: ["path_policy"]) { $0["writable"] = bad }) }
            }
            let rootException = mutate(base, path: ["path_policy"]) { $0["excluded"] = ["."] }
            _ = try decode(rootException)
            try refuse { _ = try decode(mutate(rootException, path: ["path_policy"]) { $0["read_only"] = ["."] }) }
        }
        onPass("POLICY-PROJECTION-T05-path-restrictions-cannot-be-overridden")
        try RuntimeFixtureSession.withCase("POLICY-PROJECTION-T06-managed-namespace-exclusion") {
            let location = (base["managed_locations"] as! [[String: Any]])[0]
            for override: [String: Any] in [["kind": "unknown"], ["minimum_depth": true], ["minimum_depth": 0],
                ["minimum_depth": 17], ["components": ["workspace"]], ["extra": true]] {
                var changed = base; changed["managed_locations"] = [location.merging(override) { _, new in new }]
                try refuse { _ = try decode(changed) }
            }
            for second in [location, location.merging(["kind": "awa"]) { _, new in new },
                           location.merging(["kind": "awa", "components": ["manager"]]) { _, new in new }] {
                var changed = base; changed["managed_locations"] = [location, second]
                try refuse { _ = try decode(changed) }
            }
        }
        onPass("POLICY-PROJECTION-T06-managed-namespace-exclusion")
        try RuntimeFixtureSession.withCase("POLICY-PROJECTION-T07-optional-evidence-is-closed-and-relative") {
            var evidence = base
            evidence["awa_evidence"] = ["adapter_path": "owner/adapter", "root_records_path": "owner/records", "lease_components": [".awa", "lease.json"]]
            try require(try decode(evidence).awaEvidence?.leaseComponents == [".awa", "lease.json"], "evidence changed")
            for (key, bad): (String, Any) in [("adapter_path", "../adapter"), ("root_records_path", "/records"),
                                             ("lease_components", [".."]), ("unknown", true)] {
                try refuse { _ = try decode(mutate(evidence, path: ["awa_evidence"]) { $0[key] = bad }) }
            }
        }
        onPass("POLICY-PROJECTION-T07-optional-evidence-is-closed-and-relative")
        try RuntimeFixtureSession.withCase("POLICY-PROJECTION-T08-repository-and-marker-identities") {
            for bad: Any in [["BAD/ID"], ["x/y", "x/y"], [true], "x/y", ["fixture-owner/root"]] {
                var changed = base; changed["permanent_no_touch_repository_ids"] = bad
                try refuse { _ = try decode(changed) }
            }
            for bad: Any in [[], ["a/b"], ["hook", "hook"], [1], ["../hook"]] {
                try refuse { _ = try decode(mutate(base, path: ["hooks"]) { $0["foreign_markers"] = bad }) }
            }
        }
        onPass("POLICY-PROJECTION-T08-repository-and-marker-identities")
        let maximum = try RuntimeFixtureSession.withCaseValue("POLICY-PROJECTION-T09-production-size-boundaries") {
            var maximum = fixture(dispatcher: Data(repeating: 65, count: 65_536))
            maximum = mutate(maximum, path: ["path_policy"]) { $0["excluded"] = (0..<256).map { "excluded\($0)" } }
            try require(try decode(maximum).hookDispatcher.count == 65_536, "maximum dispatcher refused")
            try refuse { _ = try decode(fixture(dispatcher: Data(repeating: 65, count: 65_537))) }
            try refuse { _ = try decode(fixture(dispatcher: Data([65, 0, 66]))) }
            try refuse { _ = try decode(mutate(maximum, path: ["path_policy"]) { $0["excluded"] = (0..<257).map { "excluded\($0)" } }) }
            for data in [Data(), Data([0xff]), Data(wire.utf8) + Data("{}".utf8), Data(repeating: 32, count: 1_048_577)] {
                try refuse { _ = try HostPolicyProjection.decode(data, policy: policy) }
            }
            return maximum
        }
        onPass("POLICY-PROJECTION-T09-production-size-boundaries")
        try RuntimeFixtureSession.withCase("POLICY-PROJECTION-T10-byte-identity-and-escaped-dispatcher") {
            var unicode = base; unicode["shelves"] = [["é"], ["e\u{301}"]]
            unicode = mutate(unicode, path: ["path_policy"]) { $0["excluded"] = ["é", "e\u{301}"] }
            _ = try decode(unicode)
            let changedLabel = mutate(base, path: ["governed_root"]) {
                $0["components"] = ["é"]; $0["display_label"] = "~/e\u{301}"
            }
            try refuse { _ = try decode(changedLabel) }
            let maximumWire = String(decoding: try json(maximum), as: UTF8.self)
            let encodedDispatcher = Data(repeating: 65, count: 65_536).base64EncodedString()
            let escapedDispatcher = encodedDispatcher.utf8.map { String(format: "\\u%04x", $0) }.joined()
            let escapedWire = maximumWire.replacingOccurrences(of: encodedDispatcher, with: escapedDispatcher)
            try require(try HostPolicyProjection.decode(Data(escapedWire.utf8), policy: policy).hookDispatcher.count == 65_536,
                        "escaping reduced dispatcher bound")
        }
        onPass("POLICY-PROJECTION-T10-byte-identity-and-escaped-dispatcher")
        try RuntimeFixtureSession.withCase("POLICY-PROJECTION-T11-byte-level-syntax-cannot-be-hidden") {
            for path in ["/\u{301}absolute", "a\\\u{301}b", "~\u{301}home", "a//\u{301}b"] {
                try refuse { _ = try decode(mutate(base, path: ["source_inputs", "host_overlay"]) { $0["path"] = path }) }
            }
            for component in ["a/\u{301}b", ".\u{301}hidden", "~\u{301}home"] {
                var bad = base; bad["shelves"] = [[component]]
                try refuse { _ = try decode(bad) }
            }
            for pattern in ["a/*\u{301}", "a/?\u{301}", "a/[\u{301}x]", "a/\\\u{301}b"] {
                try refuse { _ = try decode(mutate(base, path: ["path_policy"]) { $0["writable"] = [pattern] }) }
            }
        }
        onPass("POLICY-PROJECTION-T11-byte-level-syntax-cannot-be-hidden")
    }

    private static func fixture(dispatcher: Data = Data("#!/bin/sh\nexit 0\n".utf8)) -> [String: Any] {
        let digest = SHA256.hash(data: dispatcher).map { String(format: "%02x", $0) }.joined()
        return [
            "schema": "shadow-sync-host-policy-projection/v1",
            "source_inputs": ["worktree_policy": ["path": policy.relativePath, "sha256": policy.sha256],
                "host_overlay": ["path": "owner/overlay.json", "sha256": String(repeating: "1", count: 64)],
                "hook_dispatcher": ["path": "owner/dispatcher", "sha256": digest]],
            "governed_root": ["components": ["workspace"], "display_label": "~/workspace", "repository_id": "fixture-owner/root"],
            "shelves": [["products"], ["tools"], ["reference"]],
            "path_policy": ["excluded": ["excluded"], "read_only": ["reference/*"], "artifacts": ["generated"], "writable": ["."]],
            "permanent_no_touch_repository_ids": ["fixture-owner/protected"],
            "managed_locations": [["kind": "codex", "components": ["manager", "worktrees"], "minimum_depth": 2]],
            "hooks": ["foreign_markers": ["fixture-hook"], "dispatcher_base64": dispatcher.base64EncodedString(), "dispatcher_sha256": digest],
            "awa_evidence": NSNull(),
        ]
    }
    private static func mutate(_ input: [String: Any], path: [String], change: (inout [String: Any]) -> Void) -> [String: Any] {
        var result = input
        if let first = path.first { result[first] = mutate(result[first] as! [String: Any], path: Array(path.dropFirst()), change: change) }
        else { change(&result) }
        return result
    }
    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func decode(_ object: [String: Any]) throws -> HostPolicyProjection { try HostPolicyProjection.decode(json(object), policy: policy) }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure.assertion(message) } }
    private static func refuse(_ operation: () throws -> Void) throws {
        do { try operation(); throw Failure.assertion("invalid projection accepted") }
        catch HostPolicyBindingError.unavailable {}
    }
}
#endif
