import Foundation

enum HostPolicyBindingError: Error, CustomStringConvertible {
    case unavailable
    var description: String { "Repository policy configuration is unavailable." }
}

/// A decoded pin is not publisher verification. The authority factory must
/// obtain these bytes from a verified, sealed application resource.
struct QualifiedAWAContract: Equatable, Sendable {
    let releaseRevision: String
    let moduleSHA256: String

    private init(releaseRevision: String, moduleSHA256: String) {
        self.releaseRevision = releaseRevision; self.moduleSHA256 = moduleSHA256
    }

    static func decode(_ data: Data) throws -> Self {
        do {
            guard data.count <= 16_384 else { throw HostPolicyBindingError.unavailable }
            var parser = try PolicyWireParser(data, profile: .configuration)
            let value = try parser.parse().object(keys: [
                "schema", "status", "release_revision", "module_sha256",
            ])
            guard value["schema"] == .string("shadow-sync-awa-contract/v1"),
                  value["status"] == .string("qualified"),
                  case let .string(revision) = value["release_revision"],
                  case let .string(module) = value["module_sha256"],
                  BindingGrammar.digest(revision, length: 40),
                  BindingGrammar.digest(module, length: 64) else {
                throw HostPolicyBindingError.unavailable
            }
            return Self(releaseRevision: revision, moduleSHA256: module)
        } catch { throw HostPolicyBindingError.unavailable }
    }
}

/// Pure decoding of the dev-owned binding. Paths remain lexical home-relative
/// data; decoding performs no filesystem access, home lookup, or classification.
struct HostPolicyBinding: Equatable, Sendable {
    struct Payload: Equatable, Sendable {
        let relativePath: String
        let sha256: String
        fileprivate init(relativePath: String, sha256: String) {
            self.relativePath = relativePath; self.sha256 = sha256
        }
    }

    let policy: Payload
    let projection: Payload
    let module: Payload
    let releaseRevision: String

    private init(policy: Payload, projection: Payload, module: Payload, releaseRevision: String) {
        self.policy = policy; self.projection = projection
        self.module = module; self.releaseRevision = releaseRevision
    }

    static func decode(_ data: Data, contract: QualifiedAWAContract) throws -> Self {
        do {
            guard data.count <= 65_536 else { throw HostPolicyBindingError.unavailable }
            var parser = try PolicyWireParser(data, profile: .configuration)
            let root = try parser.parse().object(keys: ["schema", "policy", "projection", "awa"])
            guard root["schema"] == .string("shadow-sync-host-policy-binding/v1"),
                  let policyRaw = root["policy"], let projectionRaw = root["projection"],
                  let moduleRaw = root["awa"] else { throw HostPolicyBindingError.unavailable }
            func payload(_ raw: PolicyWireValue) throws -> Payload {
                let value = try raw.object(keys: ["path", "sha256"])
                guard case let .string(path) = value["path"],
                      case let .string(sha256) = value["sha256"],
                      BindingGrammar.relativePath(path), BindingGrammar.digest(sha256, length: 64)
                else { throw HostPolicyBindingError.unavailable }
                return Payload(relativePath: path, sha256: sha256)
            }
            let policy = try payload(policyRaw), projection = try payload(projectionRaw)
            let awa = try moduleRaw.object(keys: ["module_path", "module_sha256", "release_revision"])
            guard case let .string(modulePath) = awa["module_path"],
                  awa["module_sha256"] == .string(contract.moduleSHA256),
                  awa["release_revision"] == .string(contract.releaseRevision),
                  BindingGrammar.relativePath(modulePath),
                  Set([policy.relativePath, projection.relativePath, modulePath].map { Array($0.utf8) }).count == 3 else {
                throw HostPolicyBindingError.unavailable
            }
            return Self(policy: policy, projection: projection,
                module: Payload(relativePath: modulePath, sha256: contract.moduleSHA256),
                releaseRevision: contract.releaseRevision)
        } catch { throw HostPolicyBindingError.unavailable }
    }
}

private enum BindingGrammar {
    static func digest(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value != String(repeating: "0", count: length)
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func relativePath(_ value: String) -> Bool {
        let parts = value.utf8.split(separator: 47, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        return !value.isEmpty && value.utf8.count <= 4096 && (1...64).contains(parts.count)
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            && !value.utf8.contains(92)
            && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }
}
