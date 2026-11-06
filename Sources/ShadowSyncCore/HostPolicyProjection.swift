import CryptoKit
import Foundation

/// Closed dev-owned host data. This type does not discover repositories or
/// implement AWA's hard-no-touch matcher. All paths remain lexical data.
struct HostPolicyProjection: Equatable, Sendable {
    struct Source: Equatable, Sendable { let relativePath: String; let sha256: String }
    struct Paths: Equatable, Sendable {
        let excluded: [String], readOnly: [String], artifacts: [String], writable: [String]
    }
    struct ManagedLocation: Equatable, Sendable {
        let kind: String, components: [String], minimumDepth: Int
    }
    struct AWAEvidence: Equatable, Sendable {
        let adapterPath: String, rootRecordsPath: String, leaseComponents: [String]
    }

    let sourceInputs: [String: Source]
    let rootComponents: [String]
    let rootDisplayLabel: String
    let rootRepositoryID: String
    let shelves: [[String]]
    let paths: Paths
    let permanentNoTouchRepositoryIDs: [String]
    let managedLocations: [ManagedLocation]
    let foreignHookMarkers: [String]
    let hookDispatcher: Data
    let awaEvidence: AWAEvidence?

    static func decode(_ data: Data, policy: HostPolicyBinding.Payload) throws -> Self {
        do {
            var parser = try PolicyWireParser(data, profile: .configuration)
            let root = try parser.parse().object(keys: [
                "schema", "source_inputs", "governed_root", "shelves", "path_policy",
                "permanent_no_touch_repository_ids", "managed_locations", "hooks", "awa_evidence",
            ])
            try check(root["schema"] == .string("shadow-sync-host-policy-projection/v1"))
            let sources = try required(root, "source_inputs").object(keys: [
                "worktree_policy", "host_overlay", "hook_dispatcher",
            ])
            var sourceInputs: [String: Source] = [:]
            for (key, value) in sources {
                let item = try value.object(keys: ["path", "sha256"])
                let path = try string(required(item, "path")), digest = try string(required(item, "sha256"))
                try relative(path); try check(path.utf8.first != 126 && hex(digest, count: 64))
                sourceInputs[key] = Source(relativePath: path, sha256: digest)
            }
            try unique(sourceInputs.values.map(\.relativePath))
            try check(sourceInputs["worktree_policy"].map {
                bytesEqual($0.relativePath, policy.relativePath) && $0.sha256 == policy.sha256
            } == true)
            let governed = try required(root, "governed_root").object(keys: [
                "components", "display_label", "repository_id",
            ])
            let rootParts = try components(required(governed, "components"))
            let display = try string(required(governed, "display_label"))
            let repositoryID = try string(required(governed, "repository_id"))
            try check(bytesEqual(display, "~/" + rootParts.joined(separator: "/"))); try repository(repositoryID)
            let shelves = try array(required(root, "shelves"), maximum: 32, nonempty: true).map {
                try components($0, maximum: 3, hidden: false)
            }
            try disjoint(shelves)

            let rawPaths = try required(root, "path_policy").object(keys: [
                "excluded", "read_only", "artifacts", "writable",
            ])
            var patterns: [String: [String]] = [:]
            for (key, raw) in rawPaths {
                let values = try array(raw).map(string)
                try unique(values)
                for pattern in values where pattern != "." {
                    let concrete = pattern.utf8.suffix(2).elementsEqual([47, 42]) && key != "writable"
                        ? String(decoding: pattern.utf8.dropLast(2), as: UTF8.self) : pattern
                    try check(!concrete.utf8.contains(where: { [42, 63, 91, 93].contains($0) }))
                    _ = try pathComponents(concrete, hidden: false)
                }
                patterns[key] = values
            }
            let excluded = patterns["excluded"]!, readOnly = patterns["read_only"]!
            let artifacts = patterns["artifacts"]!, writable = patterns["writable"]!
            for selected in writable {
                for restricted in excluded + readOnly + artifacts {
                    if selected == "." && restricted == "." && excluded.contains(".")
                        && !(readOnly + artifacts).contains(".") { continue }
                    let prefix = restricted.utf8.suffix(2).elementsEqual([47, 42])
                        ? String(decoding: restricted.utf8.dropLast(2), as: UTF8.self) : restricted
                    try check(!bytesEqual(selected, prefix) && !selected.utf8.starts(with: (prefix + "/").utf8))
                }
            }
            let ids = try array(required(root, "permanent_no_touch_repository_ids")).map(string)
            for id in ids { try repository(id) }
            try unique(ids); try check(!ids.contains(repositoryID))
            let locations = try array(required(root, "managed_locations"), maximum: 16).map { raw in
                let item = try raw.object(keys: ["kind", "components", "minimum_depth"])
                let kind = try string(required(item, "kind"))
                guard ["cursor", "codex", "awa"].contains(kind),
                      case let .unsigned(depth) = item["minimum_depth"], (1...16).contains(depth) else {
                    throw HostPolicyBindingError.unavailable
                }
                return ManagedLocation(kind: kind, components: try components(required(item, "components")),
                                       minimumDepth: Int(depth))
            }
            try unique(locations.map(\.kind)); try disjoint([rootParts] + locations.map(\.components))

            let hooks = try required(root, "hooks").object(keys: [
                "foreign_markers", "dispatcher_base64", "dispatcher_sha256",
            ])
            let markers = try array(required(hooks, "foreign_markers"), maximum: 32, nonempty: true).map(string)
            for marker in markers {
                try check((1...64).contains(marker.utf8.count) && identifier(marker, extras: "_-"))
            }
            try unique(markers)
            let encoded = try string(required(hooks, "dispatcher_base64"))
            guard encoded.utf8.count <= 90_000, let dispatcher = Data(base64Encoded: encoded),
                  (1...65_536).contains(dispatcher.count), !dispatcher.contains(0),
                  dispatcher.base64EncodedString() == encoded else { throw HostPolicyBindingError.unavailable }
            let digest = SHA256.hash(data: dispatcher).map { String(format: "%02x", $0) }.joined()
            try check(hooks["dispatcher_sha256"] == .string(digest)
                && sourceInputs["hook_dispatcher"]?.sha256 == digest)
            let evidence: AWAEvidence?
            let rawEvidence = try required(root, "awa_evidence")
            if rawEvidence == .null { evidence = nil }
            else {
                let item = try rawEvidence.object(keys: ["adapter_path", "root_records_path", "lease_components"])
                let adapter = try string(required(item, "adapter_path"))
                let records = try string(required(item, "root_records_path"))
                _ = try pathComponents(adapter); _ = try pathComponents(records)
                evidence = AWAEvidence(adapterPath: adapter, rootRecordsPath: records,
                    leaseComponents: try components(required(item, "lease_components"), maximum: 4))
            }
            return Self(sourceInputs: sourceInputs, rootComponents: rootParts, rootDisplayLabel: display,
                rootRepositoryID: repositoryID, shelves: shelves,
                paths: Paths(excluded: excluded, readOnly: readOnly, artifacts: artifacts, writable: writable),
                permanentNoTouchRepositoryIDs: ids, managedLocations: locations, foreignHookMarkers: markers,
                hookDispatcher: dispatcher, awaEvidence: evidence)
        } catch { throw HostPolicyBindingError.unavailable }
    }

    private static func check(_ condition: Bool) throws {
        if !condition { throw HostPolicyBindingError.unavailable }
    }
    private static func required(_ value: [String: PolicyWireValue], _ key: String) throws -> PolicyWireValue {
        guard let result = value[key] else { throw HostPolicyBindingError.unavailable }; return result
    }
    private static func string(_ value: PolicyWireValue) throws -> String {
        guard case let .string(result) = value else { throw HostPolicyBindingError.unavailable }; return result
    }
    private static func array(_ value: PolicyWireValue, maximum: Int = 256, nonempty: Bool = false) throws -> [PolicyWireValue] {
        guard case let .array(result) = value, result.count <= maximum, !nonempty || !result.isEmpty else {
            throw HostPolicyBindingError.unavailable
        }; return result
    }
    // Python's policy contract compares code points, without Unicode canonical
    // normalization. Swift String equality would silently equate distinct bytes.
    private static func bytesEqual(_ left: String, _ right: String) -> Bool { left.utf8.elementsEqual(right.utf8) }
    private static func unique(_ values: [String]) throws { try check(Set(values.map { Array($0.utf8) }).count == values.count) }
    private static func relative(_ value: String) throws {
        try check(!value.isEmpty && value.utf8.count <= 4096 && !value.utf8.contains(92)
            && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
            && value.utf8.split(separator: 47, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." })
    }
    private static func pathComponents(_ value: String, hidden: Bool = true) throws -> [String] {
        try relative(value)
        return try components(.array(value.utf8.split(separator: 47).map {
            .string(String(decoding: $0, as: UTF8.self))
        }), hidden: hidden)
    }
    private static func components(_ value: PolicyWireValue, maximum: Int = 16, hidden: Bool = true) throws -> [String] {
        let result = try array(value, maximum: maximum, nonempty: true).map(string)
        try check(result.allSatisfy { !$0.utf8.contains(47) && $0.utf8.first != 126 && (hidden || $0.utf8.first != 46) })
        try relative(result.joined(separator: "/")); return result
    }
    private static func disjoint(_ values: [[String]]) throws {
        let bytePaths = values.map { $0.map { Array($0.utf8) } }
        for (index, value) in bytePaths.enumerated() {
            try check(!bytePaths[..<index].contains { value.starts(with: $0) || $0.starts(with: value) })
        }
    }
    private static func hex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func identifier(_ value: String, extras: String) -> Bool {
        func alphanumeric(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (97...122).contains(byte) }
        guard let first = value.utf8.first, alphanumeric(first) else { return false }
        return value.utf8.allSatisfy { alphanumeric($0) || extras.utf8.contains($0) }
    }
    private static func repository(_ value: String) throws {
        let parts = value.utf8.split(separator: 47, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        try check(value.utf8.count <= 200 && parts.count == 2)
        try check(identifier(parts[0], extras: "-") && identifier(parts[1], extras: "._-"))
    }
}
