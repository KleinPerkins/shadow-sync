import Foundation

/// Discovery's sealed integrity claims before configuration capture. This value
/// grants no access, publisher, process or cleanup authority. The helper must
/// classify every resource before opening it and create its own frozen snapshot.
struct DiscoveryCustodyIntent: Codable {
    let schema: String
    let policyCommitment: String
    let policyAdmissionSHA256: String
    let repositoryID: String
    let repositoryPath: String
    let rawOrigin: String
    let rootIdentity: FileIdentity
    let gitDirectoryIdentity: RepositoryDirectoryIdentity
    let configIdentity: RepositoryMetadataFileIdentity
    let hookAdmissionSHA256: String?

    init(policy: RepositoryDiscoveryCommandPolicy, candidate: RepositoryCandidate) throws {
        try policy.requireCandidate(candidate)
        guard let git = candidate.gitDirectoryIdentity,
              let common = candidate.commonDirectoryIdentity, git == common,
              let config = candidate.configIdentity,
              candidate.rootIdentity == RepositoryDirectoryIdentity(policy.selected.repositoryIdentity),
              let policyDigest = candidate.policyAdmissionSHA256 else {
            throw CustodyResourceError.invalidResource
        }
        schema = "shadow-sync-discovery-custody/v2"
        policyCommitment = policy.identityCommitment
        policyAdmissionSHA256 = policyDigest
        repositoryID = candidate.id
        repositoryPath = candidate.path
        rawOrigin = candidate.rawOrigin
        rootIdentity = policy.selected.repositoryIdentity
        gitDirectoryIdentity = git
        configIdentity = config
        hookAdmissionSHA256 = candidate.hookAdmissionSHA256
        try validate(account: policy.account)
        try policy.validate()
    }

    func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decode(_ bytes: Data) throws -> Self {
        var parser = try PolicyWireParser(bytes, profile: .discoveryCustody)
        let wire = try parser.parse()
        guard try CustodyWire.encode(wire, maximum: 262_144) == bytes else {
            throw CustodyResourceError.invalidResource
        }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        // Typed canonical re-encoding rejects unknown fields, including the v1
        // frozen snapshot, rather than letting JSONDecoder silently ignore them.
        guard value.schema == "shadow-sync-discovery-custody/v2",
              try value.encode() == bytes else { throw CustodyResourceError.invalidResource }
        return value
    }

    /// Lexical and representation checks only. Account and current policy are
    /// obtained from authenticated helper state, never from this request.
    func validate(account: EffectiveAccount) throws {
        guard schema == "shadow-sync-discovery-custody/v2",
              CustodyWire.hex(policyCommitment, bytes: 32),
              CustodyWire.hex(policyAdmissionSHA256, bytes: 32),
              hookAdmissionSHA256 == nil || CustodyWire.hex(hookAdmissionSHA256!, bytes: 32),
              repositoryPath.utf8.starts(with: (account.homeDirectory + "/").utf8),
              repositoryID.utf8.count <= 256, rawOrigin.utf8.count <= 4096,
              let origin = GitHubIdentity.parse(rawOrigin),
              repositoryID.lowercased() == origin.canonicalName,
              rootIdentity.isDirectory, rootIdentity.owner == account.uid,
              configIdentity.identity.isRegular, configIdentity.identity.owner == account.uid,
              configIdentity.identity.linkCount == 1,
              configIdentity.size >= 0, configIdentity.size <= 1_048_576 else {
            throw CustodyResourceError.invalidResource
        }
        for path in repositoryMetadataPaths {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.utf8.count <= 4096, components.count > 1, components.first == "",
                  components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".."
                      && !$0.utf8.contains(where: { $0 < 32 || $0 == 127 }) }) else {
                throw CustodyResourceError.invalidResource
            }
        }
    }

    /// Primary-checkout metadata only. User/system sources and the helper's
    /// deterministic scratch destination are independently derived and admitted.
    var repositoryMetadataPaths: [String] {
        Self.repositoryMetadataPaths(repositoryPath: repositoryPath)
    }
    static func repositoryMetadataPaths(repositoryPath: String) -> [String] {
        let git = repositoryPath + "/.git"
        return [repositoryPath, git, git + "/config", git + "/objects",
                git + "/config.worktree", git + "/commondir", git + "/refs/replace",
                git + "/info/grafts", git + "/objects/info/alternates", git + "/packed-refs"]
    }
}
