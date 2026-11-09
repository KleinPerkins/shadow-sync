import Darwin
import Foundation

/// Integrity data only. The caller supplies a live handle, frozen owner and
/// existing scope; the authenticated helper reclassifies these resources before
/// opening any repository path. Decoding this value creates no authority.
struct RepositoryGitCustodyInput: Codable {
    let schema: String
    let policyCommitment: String
    let policyAdmissionSHA256: String
    let snapshot: RepositoryExecutionSnapshot
    let transport: GitTransport
    let sshAgent: String?
    #if SHADOW_SYNC_TESTING
    var testingPausePhase: String? = nil
    #endif

    init(policy: HostPolicySnapshot, snapshot: RepositoryExecutionSnapshot,
         transport: GitTransport, sshAgent: String?) throws {
        schema = "shadow-sync-repository-git-custody/v1"
        policyCommitment = try policy.identityCommitment()
        policyAdmissionSHA256 = policy.admissionSHA256
        self.snapshot = snapshot; self.transport = transport; self.sshAgent = sshAgent
        try validate(account: policy.account)
    }
    func encode() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    static func decode(_ bytes: Data) throws -> Self {
        var parser = try PolicyWireParser(bytes, profile: .discoveryCustody)
        let wire = try parser.parse()
        guard try CustodyWire.encode(wire, maximum: 262_144) == bytes else { throw CustodyResourceError.invalidResource }
        let result = try JSONDecoder().decode(Self.self, from: bytes)
        guard try result.encode() == bytes else { throw CustodyResourceError.invalidResource }
        return result
    }
    func validate(account: EffectiveAccount) throws {
        let s = snapshot, c = s.configuration
        let prefix: String
        #if SHADOW_SYNC_TESTING
        prefix = "/private/tmp/shadow-sync-fixture-config."
        guard testingPausePhase == nil || ["system", "policy", "root", "origin", "transport", "command", "postflight"].contains(testingPausePhase!) else {
            throw CustodyResourceError.invalidResource
        }
        #else
        prefix = "/private/tmp/shadow-sync-config."
        #endif
        guard schema == "shadow-sync-repository-git-custody/v1",
              CustodyWire.hex(policyCommitment, bytes: 32), CustodyWire.hex(policyAdmissionSHA256, bytes: 32),
              s.accountUID == account.uid, s.accountHome == account.homeDirectory,
              s.accountUsername == account.username, s.repository.root.isDirectory,
              s.repository.root.owner == account.uid, s.repository.gitDirectory.isDirectory,
              s.repository.gitDirectory.owner == account.uid,
              c.frozenDirectoryPath.hasPrefix(prefix),
              !c.frozenDirectoryPath.dropFirst(prefix.count).isEmpty,
              !c.frozenDirectoryPath.dropFirst(prefix.count).contains("/"),
              c.frozenPath == c.frozenDirectoryPath + "/config",
              s.admission == nil || (s.admission?.transport == transport
                && s.admission?.frozenConfigSHA256 == c.frozenSHA256),
              sshAgent == nil || transport == .ssh else { throw CustodyResourceError.invalidResource }
        for path in resourcePaths + (sshAgent.map { [$0] } ?? []) {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.utf8.count <= 4096, parts.count > 1, parts.first == "",
                  parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".."
                    && !$0.utf8.contains(where: { $0 < 32 || $0 == 127 }) }) else { throw CustodyResourceError.invalidResource }
        }
    }
    var resourcePaths: [String] {
        let root = snapshot.rootPath, git = snapshot.repository.commonDirectoryPath
        return [root, root + "/.git", git, git + "/config", git + "/objects", git + "/config.worktree",
                git + "/commondir", git + "/refs/replace", git + "/info/grafts", git + "/objects/info/alternates",
                git + "/packed-refs", snapshot.configuration.frozenDirectoryPath, snapshot.configuration.frozenPath]
    }
    func environment(account: EffectiveAccount) throws -> [String: String] {
        let inherited = sshAgent.map { ["SSH_AUTH_SOCK": $0] } ?? [:]
        if let sshAgent {
            guard ValidatedSSHAgentEnvironment.socketPath(inherited: inherited, accountUID: account.uid) == sshAgent else {
                throw CustodyResourceError.invalidResource
            }
        }
        return ClosedGitEnvironment.make(account: account, transport: transport,
            frozenConfigPath: snapshot.configuration.frozenPath, inherited: inherited)
    }
    static func validateArguments(_ arguments: [String], snapshot: RepositoryExecutionSnapshot,
                                  mode: CustodyAuthorityMode) throws {
        // Preserve the existing exact allowlist, including its ff-only forms.
        // Legacy synthetic trampoline arguments are not real custodian commands.
        guard try !GitCommandPolicy.validate(arguments, expectedCommonDirectory: snapshot.repository.commonDirectoryPath,
            expectedWorktreePath: snapshot.rootPath), mode == .read || mode == .mutation else {
            throw CustodyResourceError.invalidResource
        }
        var command = Array(arguments.dropFirst(arguments.dropFirst().first == "--no-lazy-fetch" ? 2 : 1))
        if command.first?.hasPrefix("--git-dir=") == true { command.removeFirst() }
        guard let verb = command.first else { throw CustodyResourceError.invalidResource }
        let readOnly = ["remote", "config", "rev-parse", "for-each-ref", "symbolic-ref", "show-ref", "status", "ls-files",
            "cat-file", "show", "merge-base", "rev-list", "ls-remote"].contains(verb)
            || (verb == "worktree" && (command.dropFirst().first == "list" || command.contains("--dry-run")))
        guard readOnly || (mode == .mutation && snapshot.admission != nil) else { throw CustodyResourceError.invalidResource }

    }
}

/// Retains the caller's real resource owners through registry retirement, so a
/// bounded pending return cannot run the frozen owner's destructor underneath a
/// still admitted Git child. No operation lock is reacquired here.
final class RepositoryGitCommandAuthority {
    private(set) var input: RepositoryGitCustodyInput
    let policy: PolicyCommandAuthority
    let systemGraph: QualifiedCommandGraph, gitGraph: QualifiedCommandGraph
    #if SHADOW_SYNC_TESTING
    func testingPause(at phase: String?) throws { input.testingPausePhase = phase; try input.validate(account: policy.snapshot.account) }
    #endif
    private let handle: RepositoryHandle
    private let frozen: FrozenGitConfiguration
    private let arguments: [String]
    private let mode: CustodyAuthorityMode
    init(handle: RepositoryHandle, frozen: FrozenGitConfiguration, snapshot: RepositoryExecutionSnapshot,
         arguments: [String], mode: CustodyAuthorityMode, account: EffectiveAccount,
         helper: CustodyHelperExecutable, publisher: PublisherPolicyResources, cancellation: CancellationToken) throws {
        self.handle = handle; self.frozen = frozen; self.arguments = arguments; self.mode = mode
        let current = try HostPolicySnapshot.load(account: account, contract: QualifiedAWAContract.decode(publisher.contract))
        policy = try PolicyCommandAuthority(snapshot: current, publisher: publisher, helper: helper, cancellation: cancellation)
        input = try RepositoryGitCustodyInput(policy: current, snapshot: snapshot,
            transport: snapshot.admission?.transport ?? handle.githubIdentity.transport,
            sshAgent: (snapshot.admission?.transport ?? handle.githubIdentity.transport) == .ssh
                ? ValidatedSSHAgentEnvironment.socketPath(inherited: ProcessInfo.processInfo.environment, accountUID: account.uid) : nil)
        systemGraph = try QualifiedCommandGraph.forHelper(kind: .systemGitConfig, helper: helper)
        gitGraph = try QualifiedCommandGraph.forHelper(kind: .repositoryGit, helper: helper)
        try revalidate()
    }
    func revalidate() throws {
        try policy.revalidate(); try systemGraph.revalidate(); try gitGraph.revalidate()
        guard input.snapshot.rootPath == handle.candidate.path, input.snapshot.configuration == frozen.snapshot,
              try policy.snapshot.identityCommitment() == input.policyCommitment,
              policy.snapshot.admissionSHA256 == input.policyAdmissionSHA256,
              handle.candidate.policyAdmissionSHA256 == input.policyAdmissionSHA256 else { throw CustodyResourceError.invalidResource }
        try RepositoryGitCustodyInput.validateArguments(arguments, snapshot: input.snapshot, mode: mode)
        try handle.validateExecutionSnapshot(input.snapshot, account: policy.snapshot.account,
            requirePackedIdentity: true, frozenConfiguration: frozen)
    }
}

/// This object is created only by the authenticated inherited entrypoint. Its
/// constructor does lexical checks and publisher checks; repository/resource
/// pathname access waits for the actual serial policy batch retirement.
final class InheritedRepositoryGitResources {
    let input: RepositoryGitCustodyInput
    let policy: PolicyCommandAuthority
    let systemGraph: QualifiedCommandGraph, gitGraph: QualifiedCommandGraph
    let arguments: [String]
    private let account: EffectiveAccount
    private let directory: OwnedFileDescriptor, file: OwnedFileDescriptor
    private var preflight: GitConfigurationPreflight?
    private(set) var root: OwnedFileDescriptor?
    private(set) var frozen: CustodyInheritedFrozenConfiguration?
    private var branchConfiguration: Data?
    private(set) var postflightComplete = false

    init(bytes: Data, request: UnvalidatedCustodyRequest, policy: PolicyCommandAuthority,
         helper: CustodyHelperExecutable, account: EffectiveAccount, parent: ProcessIdentity,
         directory: OwnedFileDescriptor, file: OwnedFileDescriptor) throws {
        input = try RepositoryGitCustodyInput.decode(bytes)
        self.policy = policy; self.account = account; self.directory = directory; self.file = file
        arguments = request.arguments
        try input.validate(account: account)
        guard request.kind == .repositoryGit, input.snapshot.configuration.frozenOwnerPID == parent.processID,
              request.traceLimit == 0, request.stdoutLimit <= DescriptorProcessRunner.completeRepositoryOutputLimit,
              request.stderrLimit <= DescriptorProcessRunner.completeRepositoryOutputLimit else {
            throw CustodyResourceError.invalidResource
        }
        try RepositoryGitCustodyInput.validateArguments(arguments, snapshot: input.snapshot, mode: request.authority)
        systemGraph = try QualifiedCommandGraph.forHelper(kind: .systemGitConfig, helper: helper)
        gitGraph = try QualifiedCommandGraph.forHelper(kind: .repositoryGit, helper: helper)
        try revalidate()
    }
    func revalidate() throws {
        try policy.revalidate(); try systemGraph.revalidate(); try gitGraph.revalidate()
        guard try policy.snapshot.identityCommitment() == input.policyCommitment,
              policy.snapshot.admissionSHA256 == input.policyAdmissionSHA256 else { throw CustodyResourceError.invalidResource }
        try frozen?.revalidate()
    }
    func admit(preflight: GitConfigurationPreflight) throws {
        guard root == nil, frozen == nil, self.preflight == nil else { throw CustodyResourceError.invalidResource }
        try revalidate(); try preflight.validate(input.snapshot, account: account)
        let held = try RepositoryRootPathIdentity.withVerifiedDirectory(path: input.snapshot.rootPath,
            expected: RepositoryDirectoryIdentity(input.snapshot.repository.root)) { named in
                let fd = fcntl(named.descriptor, F_DUPFD_CLOEXEC, 201)
                guard fd >= 0 else { throw CustodyResourceError.systemCall(errno) }
                return OwnedFileDescriptor(fd)
            }
        let frozen = try CustodyInheritedFrozenConfiguration(snapshot: input.snapshot.configuration, directory: directory, file: file)
        self.root = held; self.frozen = frozen; self.preflight = preflight
        try validateBeforeTarget()
        if GitCommandPolicy.ordinaryBranchDeletionName(arguments, expectedWorktreePath: input.snapshot.rootPath) != nil {
            branchConfiguration = try RepositoryHandle.captureRepositoryConfiguration(input.snapshot)
        }
    }
    func validateBeforeTarget() throws {
        guard !postflightComplete, let root, let preflight, frozen != nil else { throw CustodyResourceError.invalidResource }
        try revalidate()
        try RepositoryRootPathIdentity.withVerifiedDirectory(path: input.snapshot.rootPath,
            expected: RepositoryDirectoryIdentity(input.snapshot.repository.root)) { named in
                try GitChildRootIdentity.validate(expectedDescriptor: named.descriptor, currentDescriptor: root.value,
                    snapshotRoot: input.snapshot.repository.root)
            }
        try RepositoryHandle.validateExecutionSnapshot(input.snapshot, account: account,
            configurationPreflight: preflight, rootDescriptor: root.value)
    }
    var probeCount: Int { input.snapshot.admission == nil ? 0 : 3 }
    func probeArguments(_ index: Int) throws -> [String] {
        guard (0..<probeCount).contains(index) else { throw CustodyResourceError.invalidResource }
        return ["--no-replace-objects", "--no-lazy-fetch"] + [
            ["rev-parse", "--show-toplevel"], ["remote", "get-url", "--all", "origin"],
            EffectiveTransportConfiguration.queryArguments][index]
    }
    func validateProbe(_ index: Int, waitStatus: Int32, stdout: Data, stderr: Data) throws {
        guard let admission = input.snapshot.admission, stderr.isEmpty, waitStatus & 0x7f == 0 else {
            throw CustodyResourceError.invalidResource
        }
        let status = (waitStatus >> 8) & 0xff
        switch index {
        case 0:
            guard status == 0, RepositoryRootPathIdentity.matches(path: String(decoding: stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines), expected: input.snapshot.repository.root) else {
                throw CustodyResourceError.invalidResource
            }
        case 1:
            guard status == 0, String(decoding: stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init) == [admission.effectiveURL],
                  GitHubIdentity.parse(admission.effectiveURL)?.transport == admission.transport else { throw GitSafetyError.originChanged }
        case 2:
            try EffectiveTransportConfiguration.validate(status: status, output: stdout,
                transport: admission.transport, operation: "Git child transport config probe")
        default: throw CustodyResourceError.invalidResource
        }
        try validateBeforeTarget()
    }
    func postflight(waitStatus: Int32) throws {
        guard !postflightComplete, let root, let preflight else { throw CustodyResourceError.invalidResource }
        try revalidate()
        let snapshot = input.snapshot
        if let branch = GitCommandPolicy.ordinaryBranchDeletionName(arguments, expectedWorktreePath: snapshot.rootPath),
           let branchConfiguration {
            try RepositoryHandle.validateBranchDeletionSnapshot(snapshot, account: account, branchName: branch,
                configurationBefore: branchConfiguration, commandSucceeded: waitStatus == 0, configurationPreflight: preflight)
        } else if GitCommandPolicy.isWorktreeRemoval(arguments, expectedCommonDirectory: snapshot.repository.commonDirectoryPath,
                                                   expectedWorktreePath: snapshot.rootPath) {
            try RepositoryHandle.validateCommonExecutionSnapshot(snapshot, account: account,
                configurationPreflight: preflight, requirePackedIdentity: false)
        } else {
            try RepositoryHandle.validateExecutionSnapshot(snapshot, account: account, configurationPreflight: preflight,
                rootDescriptor: root.value, requirePackedIdentity: false,
                requireWorktreeMarkerIdentity: !GitCommandPolicy.isMovedWorktreeRepair(arguments,
                    expectedCommonDirectory: snapshot.repository.commonDirectoryPath, expectedWorktreePath: snapshot.rootPath))
        }
        try revalidate(); postflightComplete = true
    }
}

/// Observations identify this retained command only, never a process to signal.
/// Admission is synchronous and may refuse before any helper is spawned. A
/// retirement observation is emitted once, only after actual resource retirement.
enum RepositoryGitCommandError: Error { case unavailable }

public struct RepositoryCommandObservation: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case admission, retired }
    public let requestID: String
    public let phase: Phase
}

final class RepositoryCommandObserver: @unchecked Sendable {
    private let requestID: String
    private var callback: (@Sendable (RepositoryCommandObservation) -> Bool)?
    private let lock = NSLock()
    private var admitted = false, retired = false
    init(requestID: String, callback: @escaping @Sendable (RepositoryCommandObservation) -> Bool) {
        self.requestID = requestID; self.callback = callback
    }
    func admit() -> Bool {
        lock.lock()
        guard !admitted, !retired, let callback else { lock.unlock(); return false }
        admitted = true; lock.unlock()
        return callback(RepositoryCommandObservation(requestID: requestID, phase: .admission))
    }
    func retire() -> Bool {
        lock.lock()
        guard admitted, !retired, let callback else { lock.unlock(); return false }
        retired = true; self.callback = nil; lock.unlock()
        return callback(RepositoryCommandObservation(requestID: requestID, phase: .retired))
    }
}

extension DescriptorProcessRunner {
    func runRepository(arguments: [String], context: CommandCustodyContext, handle: RepositoryHandle,
                       frozen: FrozenGitConfiguration, snapshot: RepositoryExecutionSnapshot,
                       timeout: TimeInterval, cancellation: CancellationToken) throws -> ProcessResult {
        try context.validatePhaseAdmission()
        let budget = try CustodyBudget.make(kind: .repositoryGit, workSeconds: timeout)
        let command = try context.prepareRepositoryGit(arguments: arguments, handle: handle, frozen: frozen,
            snapshot: snapshot, budget: budget, outputLimit: outputLimit, cancellation: cancellation)
        audit?.record(CommandInvocation(executable: Self.gitPath, arguments: arguments,
            environmentKeys: command.resources.request.environment.keys.sorted()))
        let lifecycle = repositoryObserver.map {
            RepositoryCommandObserver(requestID: command.resources.request.binding.requestID, callback: $0)
        }
        let retained = try RetainedCleanupRegistry.shared.start(command, repositoryObserver: lifecycle)
        let observer = cancellation.observeCustodyCancellation(retained)
        defer { cancellation.removeCustodyCancellation(observer) }
        let result = retained.wait()
        if result.phase == .cleanupPending {
            #if SHADOW_SYNC_TESTING
            DiscoveryFixtureDiagnostic.recordRepositoryResult(result)
            #endif
            context.recordCleanupPending(); cancellation.closeFutureChildAdmissions()
            throw SelectedRepositoryScopeError.cleanupPending
        }
        guard result.phase == .finished,
              result.reason == nil || [CustodyReason.none, .cancelled, .timeout, .outputLimit].contains(result.reason!),
              let journal = result.journal, journal.phase == .terminal,
              journal.kind == .repositoryGit, let reason = journal.reason,
              [CustodyReason.none, .cancelled, .timeout, .outputLimit].contains(reason),
              let raw = journal.waitStatus else {
            #if SHADOW_SYNC_TESTING
            DiscoveryFixtureDiagnostic.recordRepositoryResult(result)
            #endif
            throw RepositoryGitCommandError.unavailable
        }
        try context.validatePhaseAdmission()
        let status = raw & 0x7f == 0 ? Int32((raw >> 8) & 0xff) : 128 + Int32(raw & 0x7f)
        return ProcessResult(status: status, stdout: result.stdout, stderr: result.stderr,
            stdoutTruncated: reason == .outputLimit, stderrTruncated: reason == .outputLimit, outputByteLimit: outputLimit,
            timedOut: reason == .timeout, cancelled: reason == .cancelled,
            terminationRequested: reason != .none,
            processID: pid_t(journal.target?.pid ?? 0))
    }
}
