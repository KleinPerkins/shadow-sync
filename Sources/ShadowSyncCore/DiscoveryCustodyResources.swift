import Darwin
import Foundation

/// Sealed request data, not policy or process authority. Both sides validate the
/// same closed primary-checkout shape. Linked-worktree commands require their
/// own admitted resources; a path in this document cannot opt into that route.
#if SHADOW_SYNC_TESTING
struct DiscoveryCustodyInput: Codable {
    let schema: String
    let policyCommitment: String
    let snapshot: RepositoryExecutionSnapshot

    init(policyCommitment: String, snapshot: RepositoryExecutionSnapshot) {
        schema = "shadow-sync-discovery-custody/v1"
        self.policyCommitment = policyCommitment; self.snapshot = snapshot
    }
    func encode() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    static func decode(_ bytes: Data) throws -> Self {
        var parser = try PolicyWireParser(bytes, profile: .discoveryCustody)
        let wire = try parser.parse()
        guard try CustodyWire.encode(wire, maximum: 262_144) == bytes else {
            throw CustodyResourceError.invalidResource
        }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard try value.encode() == bytes else { throw CustodyResourceError.invalidResource }
        return value
    }
    func validate(account: EffectiveAccount, parent: pid_t) throws {
        let s = snapshot, config = s.configuration
        guard schema == "shadow-sync-discovery-custody/v1", CustodyWire.hex(policyCommitment, bytes: 32),
              s.accountUID == account.uid, s.accountUsername.utf8.elementsEqual(account.username.utf8),
              s.accountHome.utf8.elementsEqual(account.homeDirectory.utf8),
              s.rootPath.utf8.starts(with: (account.homeDirectory + "/").utf8),
              s.repository.commonDirectoryPath.utf8.elementsEqual((s.rootPath + "/.git").utf8),
              s.repository.root.isDirectory, s.repository.root.owner == account.uid,
              s.repository.worktreeMarker.isDirectory,
              s.repository.worktreeMarker.matchesStableNode(s.repository.gitDirectory),
              config.frozenOwnerPID == parent, parent > 1,
              config.frozenDirectoryPath.hasPrefix("/private/tmp/shadow-sync-config."),
              config.frozenDirectoryPath.utf8.count > "/private/tmp/shadow-sync-config.".utf8.count,
              !String(config.frozenDirectoryPath.dropFirst("/private/tmp/shadow-sync-config.".count)).contains("/"),
              config.frozenPath.utf8.elementsEqual((config.frozenDirectoryPath + "/config").utf8) else {
            throw CustodyResourceError.invalidResource
        }
        for path in resourcePaths {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.utf8.count <= 4096, parts.count > 1, parts.first == "",
                  parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".."
                    && !$0.utf8.contains(where: { $0 < 32 || $0 == 127 }) }) else {
                throw CustodyResourceError.invalidResource
            }
        }
    }
    /// The validator's exact metadata surfaces plus the already-held private
    /// frozen resource. Ancestor expansion happens before any pathname access.
    var resourcePaths: [String] {
        let root = snapshot.rootPath, git = snapshot.repository.commonDirectoryPath
        return [root, root + "/.git", git + "/config", git + "/objects", git + "/config.worktree",
                git + "/commondir", git + "/refs/replace", git + "/info/grafts",
                git + "/objects/info/alternates", git + "/packed-refs",
                snapshot.configuration.frozenDirectoryPath, snapshot.configuration.frozenPath]
    }
}

#endif

/// The caller's live policy capability is retained separately from sealed data.
/// Unknown release graphs refuse before a registry reservation or helper spawn.
final class DiscoveryCommandAuthority {
    let input: DiscoveryCustodyIntent
    let policy: PolicyCommandAuthority
    let systemGraph: QualifiedCommandGraph, gitGraph: QualifiedCommandGraph
    private let commandPolicy: RepositoryDiscoveryCommandPolicy
    init(commandPolicy: RepositoryDiscoveryCommandPolicy, candidate: RepositoryCandidate,
         publisher: PublisherPolicyResources, helper: CustodyHelperExecutable,
         cancellation: CancellationToken) throws {
        self.commandPolicy = commandPolicy
        input = try DiscoveryCustodyIntent(policy: commandPolicy, candidate: candidate)
        policy = try PolicyCommandAuthority(snapshot: commandPolicy.currentSnapshot(), publisher: publisher,
                                            helper: helper, cancellation: cancellation)
        systemGraph = try QualifiedCommandGraph.forHelper(kind: .systemGitConfig, helper: helper)
        gitGraph = try QualifiedCommandGraph.forHelper(kind: .discoveryGit, helper: helper)
        try revalidate()
    }
    func revalidate() throws {
        try commandPolicy.validate(); try policy.revalidate()
        try systemGraph.revalidate(); try gitGraph.revalidate()
        guard try policy.snapshot.identityCommitment() == input.policyCommitment else {
            throw CustodyResourceError.invalidResource
        }
        try commandPolicy.validate()
    }
}

/// Reconstructed inside the authenticated helper, using current publisher/host
/// resources. No repository pathname is opened until all serial policy batches
/// have been accepted by the custodian after actual child reaping and stream EOF.
final class InheritedDiscoveryResources {
    let input: DiscoveryCustodyIntent
    let command: DiscoveryGitCommand
    let policy: PolicyCommandAuthority
    let systemGraph: QualifiedCommandGraph, gitGraph: QualifiedCommandGraph
    private let account: EffectiveAccount
    private var preflight: GitConfigurationPreflight?
    private(set) var root: OwnedFileDescriptor?
    private(set) var frozen: DiscoveryFrozenResource?
    private var snapshot: RepositoryExecutionSnapshot?
    private var repository: RepositoryHandle?

    init(input: Data, request: UnvalidatedCustodyRequest, policy: PolicyCommandAuthority,
         helper: CustodyHelperExecutable, account: EffectiveAccount, parent: pid_t) throws {
        self.input = try DiscoveryCustodyIntent.decode(input)
        self.policy = policy; self.account = account
        try self.input.validate(account: account)
        command = try DiscoveryGitCommand(arguments: request.arguments,
            captureTransportConfiguration: request.traceLimit > 0,
            // This is the closed adapter ceiling, not a new deadline. The
            // original absolute request budget remains unchanged (also when a
            // fixture scales it); never reinterpret its ns as logical seconds.
            timeoutSeconds: DiscoveryGitCommand.maximumWorkSeconds)
        guard request.kind == .discoveryGit, request.authority == .read || request.authority == .mutation,
              request.stdoutLimit == DiscoveryGitCommand.stdoutLimit,
              request.stderrLimit == DiscoveryGitCommand.stderrLimit,
              request.traceLimit == (command.capturesTransportConfiguration ? UInt64(DiscoveryGitCommand.traceLimit) : 0),
              request.environment == ClosedProcessRunner.environment(account: account) else {
            throw CustodyResourceError.invalidResource
        }
        // Current host policy, not a saved selection, binds the permitted root.
        let prefix = account.homeDirectory + "/" + policy.snapshot.projection.rootComponents.joined(separator: "/")
        guard self.input.repositoryPath.utf8.elementsEqual(prefix.utf8)
                || self.input.repositoryPath.utf8.starts(with: (prefix + "/").utf8) else {
            throw CustodyResourceError.invalidResource
        }
        systemGraph = try QualifiedCommandGraph.forHelper(kind: .systemGitConfig, helper: helper)
        gitGraph = try QualifiedCommandGraph.forHelper(kind: .discoveryGit, helper: helper)
        try revalidate()
    }
    func revalidate() throws {
        try policy.revalidate(); try systemGraph.revalidate(); try gitGraph.revalidate()
        guard try policy.snapshot.identityCommitment() == input.policyCommitment,
              policy.snapshot.admissionSHA256 == input.policyAdmissionSHA256 else {
            throw CustodyResourceError.invalidResource
        }
        if let root, let preflight, let frozen, let snapshot, let repository {
            try repository.revalidate()
            try RepositoryRootPathIdentity.withVerifiedDirectory(path: input.repositoryPath,
                expected: RepositoryDirectoryIdentity(input.rootIdentity)) { named in
                var a = stat(), b = stat()
                guard fstat(named.descriptor, &a) == 0, fstat(root.value, &b) == 0,
                      FileIdentity(a).matchesStableNode(FileIdentity(b)) else { throw CustodyResourceError.invalidResource }
            }
            try RepositoryHandle.validateExecutionSnapshot(snapshot, account: account,
                configurationPreflight: preflight, rootDescriptor: root.value)
            try frozen.revalidate()
        }
        try policy.revalidate()
    }
    /// Only the serial helper calls this after every policy batch has retired.
    /// Its admission closure checks control, the live phase and the original
    /// absolute deadline around capture, creation and execution-snapshot work.
    func admit(preflight: GitConfigurationPreflight, journal: CustodyHelperJournal,
               admission: @escaping () throws -> Void) throws {
        guard root == nil, frozen == nil, self.preflight == nil else { throw CustodyResourceError.invalidResource }
        try revalidate(); try admission()
        _ = try preflight.admissionPaths(account: account)
        let candidate = RepositoryCandidate(id: input.repositoryID, displayName: "Local repository",
            path: input.repositoryPath, rawOrigin: input.rawOrigin,
            rootIdentity: RepositoryDirectoryIdentity(input.rootIdentity),
            gitDirectoryIdentity: input.gitDirectoryIdentity, commonDirectoryIdentity: input.gitDirectoryIdentity,
            configIdentity: input.configIdentity, policyAdmissionSHA256: input.policyAdmissionSHA256,
            hookAdmissionSHA256: input.hookAdmissionSHA256)
        let repository = try RepositoryHandle.open(candidate)
        try admission(); try repository.revalidate()
        let captured = try repository.captureConfiguration(account: account, configurationPreflight: preflight)
        try admission(); try repository.revalidate()
        let frozen = try journal.prepareDiscoveryResource(captured, admission: admission)
        guard let configuration = frozen.snapshot else { throw CustodyResourceError.invalidResource }
        try admission()
        let snapshot = try repository.executionSnapshot(account: account, configuration: configuration,
                                                        admission: nil, configurationPreflight: preflight)
        let raw = fcntl(repository.worktreeDescriptor, F_DUPFD_CLOEXEC, 201)
        guard raw >= 0 else { throw CustodyResourceError.systemCall(errno) }
        self.root = OwnedFileDescriptor(raw); self.repository = repository
        self.preflight = preflight; self.snapshot = snapshot; self.frozen = frozen
        try admission(); try revalidate()
    }
}
