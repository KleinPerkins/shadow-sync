import Darwin
import Foundation

/// Closed retention integrity data. It is never a decoded run/lock authority.
/// Both actual source and destination descriptions are inherited separately.
struct RetentionArchiveInput: Codable {
    let schema: String
    let policyCommitment: String
    let policyAdmissionSHA256: String
    let source: RepositoryExecutionSnapshot
    let target: RepositoryExecutionSnapshot
    let worktreePath: String
    let worktreeIdentity: FileIdentity
    let slotPath: String
    let slotIdentity: FileIdentity
    let cwdPath: String
    let cwdIdentity: FileIdentity
    let revision: String
    let tip: String
    #if SHADOW_SYNC_TESTING
    var testingPauseBeforeResume: Bool = false
    var testingPauseAfterResume: Bool = false
    #endif

    func encode() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    static func decode(_ bytes: Data) throws -> Self {
        var parser = try PolicyWireParser(bytes, profile: .discoveryCustody)
        guard try CustodyWire.encode(parser.parse(), maximum: 262_144) == bytes else { throw CustodyResourceError.invalidResource }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard try value.encode() == bytes else { throw CustodyResourceError.invalidResource }
        return value
    }
    var restorePath: String { slotPath + "/.restore-proof/repository" }
    var resourcePaths: [String] {
        let git = source.repository.commonDirectoryPath
        return [source.rootPath, source.rootPath + "/.git", worktreePath, worktreePath + "/.git",
                git, git + "/config", git + "/objects", git + "/config.worktree", git + "/commondir",
                git + "/refs/replace", git + "/info/grafts", git + "/objects/info/alternates", git + "/packed-refs",
                target.repository.commonDirectoryPath, target.rootPath + "/.git",
                target.repository.commonDirectoryPath + "/worktrees",
                source.configuration.frozenDirectoryPath, source.configuration.frozenPath,
                slotPath, slotPath + "/branch.bundle", slotPath + "/.restore-proof", restorePath, restorePath + "/.git"]
    }
    func validate(account: EffectiveAccount, statePath: String, arguments: [String]) throws {
        try RetentionGitCommandPolicy.validate(arguments)
        guard schema == "shadow-sync-retention-archive-custody/v1",
              CustodyWire.hex(policyCommitment, bytes: 32), CustodyWire.hex(policyAdmissionSHA256, bytes: 32),
              source.accountUID == account.uid, source.accountHome == account.homeDirectory,
              source.accountUsername == account.username, source.repository.root.owner == account.uid,
              target.rootPath == worktreePath, target.repository.root == worktreeIdentity,
              target.configuration == source.configuration, target.accountUID == source.accountUID,
              target.repository.commonDirectoryPath == source.repository.commonDirectoryPath,
              source.repository.root.isDirectory, worktreeIdentity.owner == account.uid, worktreeIdentity.isDirectory,
              slotIdentity.owner == account.uid, slotIdentity.mode == S_IFDIR | 0o700,
              cwdIdentity.owner == account.uid, cwdIdentity.isDirectory,
              slotPath.hasPrefix(statePath + "/retention/.incomplete-ret-"),
              !slotPath.dropFirst((statePath + "/retention/").count).contains("/"),
              RetentionPath.isOID(tip), revision == tip || GitReferenceSyntax.isValidLocalBranchRef(revision),
              source.configuration.frozenPath == source.configuration.frozenDirectoryPath + "/config" else {
            throw CustodyResourceError.invalidResource
        }
        for path in resourcePaths {
            let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.utf8.count <= 4096, pieces.count > 1, pieces.first == "",
                  pieces.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".."
                    && !$0.utf8.contains(where: { $0 < 32 || $0 == 127 }) }) else { throw CustodyResourceError.invalidResource }
        }
        let bundle = slotPath + "/branch.bundle", git = source.repository.commonDirectoryPath
        let status = ["status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignored=matching"]
        let allowed: [([String], String)] = [
            (["-C", worktreePath] + status, worktreePath),
            (["--git-dir", git, "bundle", "create", bundle, revision], source.rootPath),
            (["--git-dir", git, "bundle", "verify", bundle], source.rootPath),
            (["clone", "--no-hardlinks", bundle, restorePath], slotPath + "/.restore-proof"),
            (["-C", restorePath, "checkout", "--detach", tip], restorePath),
            (["-C", restorePath, "rev-parse", "--verify", tip + "^{commit}"], restorePath),
            (["-C", restorePath, "fsck", "--connectivity-only", "--no-dangling"], restorePath),
            (["-C", restorePath] + status, restorePath),
        ]
        guard allowed.contains(where: { $0.0 == arguments && $0.1 == cwdPath }) else { throw CustodyResourceError.invalidResource }
    }
    func environment(account: EffectiveAccount) -> [String: String] {
        // Git opens this immutable identity-checked file afresh on every read.
        // /dev/fd aliases share cursors on Darwin and cannot replay includes.
        ClosedProcessRunner.environment(account: account, frozenConfigPath: source.configuration.frozenPath)
    }
}

/// Early policy/graph admission precedes source, slot and frozen-file access.
/// The actual Body 3 context is borrowed; this never acquires an operation lock.
final class RetentionArchiveAdmission {
    let context: CommandCustodyContext
    let policy: PolicyCommandAuthority
    let systemGraph: QualifiedCommandGraph, archiveGraph: QualifiedCommandGraph
    let account: EffectiveAccount
    init(context: CommandCustodyContext, helper: CustodyHelperExecutable, account: EffectiveAccount,
         publisher: PublisherPolicyResources, cancellation: CancellationToken) throws {
        self.context = context; self.account = account
        try context.validatePhaseAdmission(account: account)
        let snapshot = try HostPolicySnapshot.load(account: account, contract: QualifiedAWAContract.decode(publisher.contract))
        policy = try PolicyCommandAuthority(snapshot: snapshot, publisher: publisher, helper: helper, cancellation: cancellation)
        systemGraph = try QualifiedCommandGraph.forHelper(kind: .systemGitConfig, helper: helper)
        archiveGraph = try QualifiedCommandGraph.forHelper(kind: .retentionArchive, helper: helper)
        try revalidate()
    }
    func revalidate() throws {
        try context.validatePhaseAdmission(account: account)
        try policy.revalidate(); try systemGraph.revalidate(); try archiveGraph.revalidate()
    }
    func classify(paths: [String], scratch: Int32, cancellation: CancellationToken,
                  budget: CustodyBudget) throws {
        try budget.validate(kind: .retentionArchive, permittedWorkSeconds: 120, now: DispatchTime.now().uptimeNanoseconds)
        try revalidate()
        let transport = PolicyHelperTransport(snapshot: policy.snapshot, publisher: policy.publisher, context: context)
        for batch in try ConfigurationPolicyPlan(retentionPaths: paths).batches {
            let decisions = try transport.classify(candidates: batch, scratchDescriptor: scratch, timeout: 2,
                absoluteDeadline: budget.work, enclosingBudget: budget, cancellation: cancellation)
            guard decisions.count == batch.count, decisions.allSatisfy(\.allowsCandidateAccess) else { throw PolicyHelperError.unavailable }
            try revalidate()
        }
    }
}

/// Strong resource owners live with the prepared command until registry retirement.
final class RetentionArchiveCommandAuthority {
    let admission: RetentionArchiveAdmission
    private(set) var input: RetentionArchiveInput
    #if SHADOW_SYNC_TESTING
    func testingPauseAtAdmission(afterResume: Bool = false) {
        input.testingPauseBeforeResume = !afterResume; input.testingPauseAfterResume = afterResume
    }
    #endif
    private var retainedPrimary: RepositoryHandle?, retainedWorktree: RepositoryHandle?
    private var retainedFrozen: FrozenGitConfiguration?
    var primary: RepositoryHandle { retainedPrimary! }
    var worktree: RepositoryHandle { retainedWorktree! }
    var frozen: FrozenGitConfiguration { retainedFrozen! }
    let destination: OwnedFileDescriptor
    let arguments: [String]
    let statePath: String
    init(admission: RetentionArchiveAdmission, primary: RepositoryHandle, worktree: RepositoryHandle,
         frozen: FrozenGitConfiguration, destination: Int32, slotPath: String, cwd: Int32,
         arguments: [String], revision: String, tip: String, statePath: String) throws {
        self.admission = admission; self.retainedPrimary = primary; self.retainedWorktree = worktree; self.retainedFrozen = frozen
        self.arguments = arguments; self.statePath = statePath
        self.destination = OwnedFileDescriptor(try Self.copy(destination))
        let cwdPath: String
        if arguments.first == "-C" { cwdPath = arguments[1] }
        else if arguments.first == "clone" { cwdPath = slotPath + "/.restore-proof" }
        else { cwdPath = primary.worktreePath }
        input = RetentionArchiveInput(schema: "shadow-sync-retention-archive-custody/v1",
            policyCommitment: try admission.policy.snapshot.identityCommitment(),
            policyAdmissionSHA256: admission.policy.snapshot.admissionSHA256,
            source: try primary.executionSnapshot(account: admission.account, frozenConfiguration: frozen, admission: nil),
            target: try worktree.executionSnapshot(account: admission.account, frozenConfiguration: frozen, admission: nil),
            worktreePath: worktree.worktreePath, worktreeIdentity: try Self.identity(worktree.worktreeDescriptor),
            slotPath: slotPath, slotIdentity: try Self.identity(destination), cwdPath: cwdPath,
            cwdIdentity: try Self.identity(cwd), revision: revision, tip: tip)
        try revalidate()
    }
    func retire() { destination.closeNow(); retainedPrimary = nil; retainedWorktree = nil; retainedFrozen = nil }
    static func copy(_ fd: Int32) throws -> Int32 {
        let value = fcntl(fd, F_DUPFD_CLOEXEC, 201)
        guard value >= 0 else { throw CustodyResourceError.systemCall(errno) }; return value
    }
    static func identity(_ fd: Int32) throws -> FileIdentity {
        var s = stat(); guard fstat(fd, &s) == 0 else { throw CustodyResourceError.systemCall(errno) }; return FileIdentity(s)
    }
    static func validateDirectory(path: String, identity: FileIdentity, retained: Int32? = nil) throws {
        try RepositoryRootPathIdentity.withVerifiedDirectory(path: path, expected: RepositoryDirectoryIdentity(identity)) { named in
            guard try Self.identity(named.descriptor).matchesStableNode(identity),
                  try retained.map({ try Self.identity($0).matchesStableNode(identity) }) ?? true else {
                throw CustodyResourceError.invalidResource
            }
        }
    }
    func revalidate() throws {
        guard retainedPrimary != nil, retainedWorktree != nil, retainedFrozen != nil else { throw CustodyResourceError.closed }
        try admission.revalidate(); try input.validate(account: admission.account, statePath: statePath, arguments: arguments)
        guard primary.candidate.policyAdmissionSHA256 == input.policyAdmissionSHA256,
              try admission.policy.snapshot.identityCommitment() == input.policyCommitment else { throw CustodyResourceError.invalidResource }
        try primary.validateExecutionSnapshot(input.source, account: admission.account,
            requirePackedIdentity: true, frozenConfiguration: frozen)
        try worktree.validateExecutionSnapshot(input.target, account: admission.account,
            requirePackedIdentity: true, frozenConfiguration: frozen)
        try Self.validateDirectory(path: input.slotPath, identity: input.slotIdentity, retained: destination.value)
        try Self.validateDirectory(path: input.cwdPath, identity: input.cwdIdentity)
    }
}

/// The authenticated helper repeats policy admission before any named candidate
/// access. Inherited descriptions alone never grant policy or run authority.
final class InheritedRetentionArchiveResources {
    let input: RetentionArchiveInput
    let policy: PolicyCommandAuthority
    let systemGraph: QualifiedCommandGraph, archiveGraph: QualifiedCommandGraph
    private let account: EffectiveAccount
    private let source: OwnedFileDescriptor, target: OwnedFileDescriptor, destination: OwnedFileDescriptor
    private let directory: OwnedFileDescriptor, file: OwnedFileDescriptor
    private var preflight: GitConfigurationPreflight?
    private(set) var frozen: CustodyInheritedFrozenConfiguration?
    private(set) var cwd: OwnedFileDescriptor?
    init(bytes: Data, request: UnvalidatedCustodyRequest, policy: PolicyCommandAuthority,
         helper: CustodyHelperExecutable, account: EffectiveAccount, statePath: String, parent: ProcessIdentity,
         source: OwnedFileDescriptor, target: OwnedFileDescriptor, destination: OwnedFileDescriptor,
         directory: OwnedFileDescriptor, file: OwnedFileDescriptor) throws {
        input = try RetentionArchiveInput.decode(bytes)
        self.policy = policy; self.account = account; self.source = source; self.target = target; self.destination = destination
        self.directory = directory; self.file = file
        try input.validate(account: account, statePath: statePath, arguments: request.arguments)
        guard request.kind == .retentionArchive, request.authority == .mutation,
              input.source.configuration.frozenOwnerPID == parent.processID,
              request.traceLimit == 0, request.stdoutLimit == 16_777_216, request.stderrLimit == 16_777_216,
              request.environment == input.environment(account: account) else { throw CustodyResourceError.invalidResource }
        systemGraph = try QualifiedCommandGraph.forHelper(kind: .systemGitConfig, helper: helper)
        archiveGraph = try QualifiedCommandGraph.forHelper(kind: .retentionArchive, helper: helper)
        try revalidate()
    }
    func revalidate() throws {
        try policy.revalidate(); try systemGraph.revalidate(); try archiveGraph.revalidate()
        guard try policy.snapshot.identityCommitment() == input.policyCommitment,
              policy.snapshot.admissionSHA256 == input.policyAdmissionSHA256 else { throw CustodyResourceError.invalidResource }
        if let preflight, let frozen, let cwd {
            try frozen.revalidate()
            try RepositoryHandle.validateExecutionSnapshot(input.source, account: account,
                configurationPreflight: preflight, rootDescriptor: source.value)
            try RepositoryHandle.validateExecutionSnapshot(input.target, account: account,
                configurationPreflight: preflight, rootDescriptor: target.value)
            try RetentionArchiveCommandAuthority.validateDirectory(path: input.worktreePath, identity: input.worktreeIdentity, retained: target.value)
            try RetentionArchiveCommandAuthority.validateDirectory(path: input.slotPath, identity: input.slotIdentity, retained: destination.value)
            try RetentionArchiveCommandAuthority.validateDirectory(path: input.cwdPath, identity: input.cwdIdentity, retained: cwd.value)
        }
    }
    func admit(preflight: GitConfigurationPreflight) throws {
        guard cwd == nil, frozen == nil, self.preflight == nil else { throw CustodyResourceError.invalidResource }
        try revalidate(); try preflight.validate(input.source, account: account)
        try RetentionArchiveCommandAuthority.validateDirectory(path: input.source.rootPath,
            identity: input.source.repository.root, retained: source.value)
        try RetentionArchiveCommandAuthority.validateDirectory(path: input.slotPath, identity: input.slotIdentity, retained: destination.value)
        let cwd = try RepositoryRootPathIdentity.withVerifiedDirectory(path: input.cwdPath,
            expected: RepositoryDirectoryIdentity(input.cwdIdentity)) { named in
                OwnedFileDescriptor(try RetentionArchiveCommandAuthority.copy(named.descriptor))
            }
        frozen = try CustodyInheritedFrozenConfiguration(snapshot: input.source.configuration, directory: directory, file: file)
        self.cwd = cwd; self.preflight = preflight
        try revalidate()
    }
}

#if SHADOW_SYNC_TESTING
/// Fixed isolated workload, not a production input extension. No random, shell,
/// hook, filter, artificial child or FIFO is used to stretch the real command.
enum TestingRetentionPayload {
    static let count = 128
    static let bytesPerFile = 262_144
    static let initialBytes = 32 * 1_024 * 1_024
    static let maximumFiles = 256
    static let scratchLimit = 1_024 * 1_024 * 1_024
    static let manifestName = ".retention-witness-manifest.json"
    struct Entry: Codable, Equatable { let name: String; let size: Int; let sha256: String }
    static func name(_ index: Int) -> String { String(format: "retention-payload-%03d.bin", index) }
    static func bytes(_ index: Int) -> Data {
        precondition((0..<count).contains(index) && count <= maximumFiles && count * bytesPerFile == initialBytes)
        // Counter-based SplitMix64; fixed seed and little-endian byte order make
        // every bounded byte reproducible independently of machine randomness.
        var state = UInt64(index) &+ 0x6a09e667f3bcc909
        var result = Data(capacity: bytesPerFile)
        for _ in 0..<(bytesPerFile / 8) {
            state &+= 0x9e3779b97f4a7c15
            var z = state; z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb; z ^= z >> 31
            for shift in stride(from: 0, to: 64, by: 8) { result.append(UInt8(truncatingIfNeeded: z >> shift)) }
        }
        return result
    }
    static func encode(_ manifest: [Entry]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }
    static func validate(_ manifest: [Entry]) throws {
        guard count <= maximumFiles, initialBytes <= 32 * 1_024 * 1_024,
              manifest.count == count, manifest.enumerated().allSatisfy({
                  $0.element.name == name($0.offset) && $0.element.size == bytesPerFile
                      && CustodyWire.hex($0.element.sha256, bytes: 32)
              }), manifest.reduce(0, { $0 + $1.size }) == initialBytes else { throw CustodyResourceError.invalidResource }
    }
}

/// This file is fixture evidence, never a custody receipt or admission authority.
struct TestingRetentionEOFWitness: Codable {
    static let filename = "retention-worker-eof-witness.json"
    static let temporary = "retention-worker-eof-witness.new"
    static let maximumBytes = 8_192
    let schema: String
    let request: String
    let requestSHA256: String
    let inputSHA256: String
    let manifestSHA256: String
    let releaseSHA256: String
    let budget: [UInt64]
    let eofUptime: UInt64
    let observedUptime: UInt64
    let worker: ProcessIdentity
    let helper: ProcessIdentity
    let graph: TestingRetentionLiveGraph
    let slot: FileIdentity
    let control: FileIdentity
    let output: Output
    struct Output: Codable {
        let phase: String
        let node: FileIdentity
        let size: Int64
        let finalAbsent: Bool
        let missingPayload: String?
        let observedPayloadSize: Int64?
        let expectedPayloadSize: Int?
    }
    func encode() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(self)
        guard bytes.count <= Self.maximumBytes else { throw CustodyResourceError.limit }; return bytes
    }
    /// Metadata validation is deliberately independent of current process liveness:
    /// validation runs after drainage, when those original identities must be gone.
    func validate() throws {
        guard schema == "shadow-sync-retention-true-eof-witness/v1", RunIdentity.isValid(request),
              [requestSHA256, inputSHA256, manifestSHA256, releaseSHA256].allSatisfy({ CustodyWire.hex($0, bytes: 32) }),
              budget.count == 5, budget[0] <= eofUptime, eofUptime <= observedUptime, observedUptime < budget[2],
              budget[0] < budget[1], budget[1] <= budget[2], budget[2] <= budget[3], budget[3] <= budget[4],
              helper.processID != worker.processID, graph.original.processID != helper.processID,
              graph.original.processID == graph.original.processGroupID,
              graph.image.processID == graph.original.processID, graph.image.processGroupID == graph.original.processGroupID,
              graph.image.startSeconds == graph.original.startSeconds, graph.image.startMicroseconds == graph.original.startMicroseconds,
              graph.image.userID == worker.userID, helper.userID == worker.userID,
              graph.original.generation == worker.generation, graph.image.generation == worker.generation,
              graph.completeGroupCount > 1, graph.completeGroupCount <= OwnedProcessGroupSnapshot.maximumPIDs,
              graph.descendants.count == 1, (1...16).contains(graph.ancestry.count),
              graph.descendants.first == graph.ancestry.first,
              graph.ancestry.last?.parent == graph.original.processID,
              Set(graph.ancestry.map { $0.identity.processID }).count == graph.ancestry.count,
              graph.ancestry.allSatisfy({ $0.identity.processID != graph.original.processID
                  && $0.identity.processGroupID == graph.original.processID && $0.identity.userID == worker.userID
                  && $0.identity.generation == worker.generation }),
              slot.isDirectory, slot.owner == worker.userID,
              mode_t(control.mode) & S_IFMT == S_IFIFO, control.linkCount == 0, control.owner == worker.userID,
              output.node.isRegular,
              output.node.owner == worker.userID, output.node.linkCount == 1, output.size > 0 else {
            throw CustodyResourceError.invalidResource
        }
        for i in 0..<(graph.ancestry.count - 1) {
            guard graph.ancestry[i].parent == graph.ancestry[i + 1].identity.processID else { throw CustodyResourceError.invalidResource }
        }
        switch output.phase {
        case "bundle-unpublished-intermediate":
            guard output.finalAbsent, output.missingPayload == nil, output.observedPayloadSize == nil,
                  output.expectedPayloadSize == nil else { throw CustodyResourceError.invalidResource }
        case "clone-incomplete-checkout":
            guard !output.finalAbsent, let path = output.missingPayload,
                  (0..<TestingRetentionPayload.count).contains(where: { TestingRetentionPayload.name($0) == path }),
                  output.expectedPayloadSize == TestingRetentionPayload.bytesPerFile,
                  let size = output.observedPayloadSize, size >= -1, size < Int64(TestingRetentionPayload.bytesPerFile) else {
                throw CustodyResourceError.invalidResource
            }
        default: throw CustodyResourceError.invalidResource
        }
    }
}

extension InheritedRetentionArchiveResources {
    /// Single best-effort observation only. Errors are intentionally caught at the
    /// EOF seam so cancellation and normal owned drainage always continue.
    func testingPublishEOF(request: UnvalidatedCustodyRequest, worker: ProcessIdentity,
        helper: ProcessIdentity, owner: OwnedDirectChild, controlFD: Int32, eofUptime: UInt64, before deadline: UInt64) throws {
        guard input.testingPauseAfterResume, !input.testingPauseBeforeResume,
              request.kind == .retentionArchive, request.inputSHA256 == CustodyRecordBinding.digest(try input.encode()),
              request.binding.callerGeneration == worker.generation,
              request.binding.callerGeneration == helper.generation else { throw CustodyResourceError.invalidResource }
        let restore = request.arguments.first == "clone"
        let expectedArguments = restore
            ? ["clone", "--no-hardlinks", input.slotPath + "/branch.bundle", input.restorePath]
            : ["--git-dir", input.source.repository.commonDirectoryPath, "bundle", "create", input.slotPath + "/branch.bundle", input.revision]
        guard request.arguments == expectedArguments else { throw CustodyResourceError.invalidResource }
        let control = try RetentionArchiveCommandAuthority.identity(controlFD)
        guard let claim = request.descriptors.first(where: { $0.role == .control }),
              control.device == claim.device, control.inode == claim.inode, control.owner == claim.uid,
              UInt32(control.mode) == claim.mode, UInt64(control.linkCount) == claim.links,
              fcntl(controlFD, F_GETFL) & O_ACCMODE == O_RDONLY,
              fcntl(controlFD, F_GETFL) & O_NONBLOCK != 0 else { throw CustodyResourceError.invalidResource }
        try RetentionArchiveCommandAuthority.validateDirectory(path: input.slotPath, identity: input.slotIdentity, retained: destination.value)
        guard try RetentionArchiveCommandAuthority.identity(source.value).matchesStableNode(input.source.repository.root) else {
            throw CustodyResourceError.invalidResource
        }
        let manifest = try Self.testingRead(source.value, TestingRetentionPayload.manifestName, maximum: 65_536)
        let entries = try JSONDecoder().decode([TestingRetentionPayload.Entry].self, from: manifest)
        try TestingRetentionPayload.validate(entries)
        guard try TestingRetentionPayload.encode(entries) == manifest else { throw CustodyResourceError.invalidResource }
        let observation = try owner.testingRetentionLiveWindow(before: deadline) {
            try Self.testingOutput(slot: self.destination.value, restore: request.arguments.first == "clone", manifest: entries)
        }
        let witness = TestingRetentionEOFWitness(schema: "shadow-sync-retention-true-eof-witness/v1",
            request: request.binding.requestID, requestSHA256: CustodyRecordBinding.digest(try request.encode()),
            inputSHA256: CustodyRecordBinding.digest(try input.encode()), manifestSHA256: CustodyRecordBinding.digest(manifest),
            releaseSHA256: request.binding.releaseSHA256,
            budget: [request.budget.issued, request.budget.work, request.budget.term, request.budget.kill, request.budget.receipt],
            eofUptime: eofUptime, observedUptime: DispatchTime.now().uptimeNanoseconds,
            worker: worker, helper: helper, graph: observation.0, slot: input.slotIdentity, control: control, output: observation.1)
        try witness.validate()
        let bytes = try witness.encode()
        guard try Self.testingRead(source.value, TestingRetentionPayload.manifestName, maximum: 65_536) == manifest,
              try RetentionArchiveCommandAuthority.identity(source.value).matchesStableNode(input.source.repository.root) else {
            throw CustodyResourceError.invalidResource
        }
        try RetentionArchiveCommandAuthority.validateDirectory(path: input.slotPath, identity: input.slotIdentity, retained: destination.value)
        try Self.testingPublish(destination.value, bytes: bytes, before: deadline)
    }
    static func testingAbsent(_ parent: Int32, _ name: String) throws -> Bool {
        var st = stat(); errno = 0
        if fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW) == 0 { return false }
        guard errno == ENOENT else { throw CustodyResourceError.invalidResource }; return true
    }
    static func testingNode(_ parent: Int32, _ name: String, directory: Bool = false) throws -> OwnedFileDescriptor {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw CustodyResourceError.invalidResource }
        let owner = OwnedFileDescriptor(fd)
        var st = stat(), named = stat()
        guard fstat(fd, &st) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity(st) == FileIdentity(named), st.st_uid == geteuid(),
              st.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), directory || st.st_nlink == 1 else { throw CustodyResourceError.invalidResource }
        _ = try PolicyAuthorityFile.safeACL(fd)
        return owner
    }
    static func testingRead(_ parent: Int32, _ name: String, maximum: Int, expected: FileIdentity? = nil) throws -> Data {
        let fd = try testingNode(parent, name); var before = stat(), after = stat(), named = stat()
        guard fstat(fd.value, &before) == 0, before.st_size > 0, before.st_size <= maximum,
              expected.map({ $0 == FileIdentity(before) }) ?? true else { throw CustodyResourceError.limit }
        var bytes = Data(count: Int(before.st_size))
        let n = bytes.withUnsafeMutableBytes { pread(fd.value, $0.baseAddress, $0.count, 0) }
        guard n == bytes.count, fstat(fd.value, &after) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity(before) == FileIdentity(after), FileIdentity(after) == FileIdentity(named),
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw CustodyResourceError.invalidResource }
        return bytes
    }
    static func testingOutput(slot: Int32, restore: Bool, manifest: [TestingRetentionPayload.Entry]) throws -> TestingRetentionEOFWitness.Output {
        try TestingRetentionPayload.validate(manifest)
        if !restore {
            guard try testingAbsent(slot, "branch.bundle") else { throw CustodyResourceError.invalidResource }
            let file = try testingNode(slot, "branch.bundle.lock")
            var first = stat(), last = stat(), named = stat()
            guard fstat(file.value, &first) == 0, first.st_size > 0,
                  fstatat(slot, "branch.bundle.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
                  FileIdentity(first) == FileIdentity(named), fstat(file.value, &last) == 0,
                  FileIdentity(last) == FileIdentity(first), last.st_size >= first.st_size,
                  try testingAbsent(slot, "branch.bundle") else { throw CustodyResourceError.invalidResource }
            // Unpublished nonempty intermediate only; no bytewise-truncation claim.
            return .init(phase: "bundle-unpublished-intermediate", node: FileIdentity(last), size: last.st_size,
                finalAbsent: true, missingPayload: nil, observedPayloadSize: nil, expectedPayloadSize: nil)
        }
        let proof = try testingNode(slot, ".restore-proof", directory: true)
        let repository = try testingNode(proof.value, "repository", directory: true)
        let git = try testingNode(repository.value, ".git", directory: true)
        let config = try testingNode(git.value, "config")
        let content = try testingRead(git.value, "config", maximum: 65_536,
            expected: RetentionArchiveCommandAuthority.identity(config.value))
        guard String(decoding: content, as: UTF8.self).contains("[core]") else { throw CustodyResourceError.invalidResource }
        var output = stat(); guard fstat(config.value, &output) == 0, output.st_size > 0 else { throw CustodyResourceError.invalidResource }
        var incomplete: (String, Int64, Int)?
        for entry in manifest {
            var named = stat(); errno = 0
            if fstatat(repository.value, entry.name, &named, AT_SYMLINK_NOFOLLOW) < 0 {
                guard errno == ENOENT else { throw CustodyResourceError.invalidResource }
                incomplete = (entry.name, -1, entry.size); break
            }
            let payload = try testingNode(repository.value, entry.name)
            var retained = stat()
            guard fstat(payload.value, &retained) == 0, FileIdentity(retained) == FileIdentity(named), retained.st_size >= 0 else {
                throw CustodyResourceError.invalidResource
            }
            if retained.st_size < entry.size { incomplete = (entry.name, retained.st_size, entry.size); break }
        }
        guard let incomplete else { throw CustodyResourceError.invalidResource }
        // Revalidate every parent and the actual tool-created content inode.
        for (parent, name, fd) in [(slot, ".restore-proof", proof.value), (proof.value, "repository", repository.value),
                                  (repository.value, ".git", git.value), (git.value, "config", config.value)] {
            var named = stat(), held = stat()
            guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0, fstat(fd, &held) == 0,
                  FileIdentity(named) == FileIdentity(held) else { throw CustodyResourceError.invalidResource }
        }
        return .init(phase: "clone-incomplete-checkout", node: FileIdentity(output), size: output.st_size,
            finalAbsent: false, missingPayload: incomplete.0, observedPayloadSize: incomplete.1, expectedPayloadSize: incomplete.2)
    }
    private static func testingPublish(_ directory: Int32, bytes: Data, before deadline: UInt64) throws {
        guard bytes.count <= TestingRetentionEOFWitness.maximumBytes, DispatchTime.now().uptimeNanoseconds < deadline,
              try testingAbsent(directory, TestingRetentionEOFWitness.filename),
              try testingAbsent(directory, TestingRetentionEOFWitness.temporary) else { throw CustodyResourceError.invalidResource }
        let fd = openat(directory, TestingRetentionEOFWitness.temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CustodyResourceError.invalidResource }; defer { close(fd) }
        var initial = stat(); guard fstat(fd, &initial) == 0, initial.st_mode == S_IFREG | 0o600,
            initial.st_uid == geteuid(), initial.st_nlink == 1 else { throw CustodyResourceError.invalidResource }
        var offset = 0
        while offset < bytes.count {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw CustodyResourceError.limit }
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw CustodyResourceError.invalidResource }; offset += n
        }
        var named = stat(), held = stat()
        guard fsync(fd) == 0, fstat(fd, &held) == 0, FileIdentity(initial) == FileIdentity(held), held.st_size == bytes.count,
              fstatat(directory, TestingRetentionEOFWitness.temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity(named) == FileIdentity(held),
              renameatx_np(directory, TestingRetentionEOFWitness.temporary, directory, TestingRetentionEOFWitness.filename, UInt32(RENAME_EXCL)) == 0,
              fsync(directory) == 0,
              fstatat(directory, TestingRetentionEOFWitness.filename, &named, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity(named) == FileIdentity(held) else { throw CustodyResourceError.invalidResource }
    }
}
#endif
