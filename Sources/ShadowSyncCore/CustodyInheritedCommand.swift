import Darwin
import Foundation
import Security

/// Authenticated resources of this actual helper process. Only the closed
/// inherited entrypoint constructs this object; decoded claims are not authority.
final class CustodyInheritedCommand {
    #if SHADOW_SYNC_TESTING
    // One scalar in the disposable helper process, reset by its fixed entrypoint.
    // It is only a failure-location observation, never resource or run authority.
    enum TestingConstructionStage: Int32 {
        case helper = 81, descriptors = 84, request = 85, roles = 86, input = 87
        case claims = 88, streams = 89, parent = 90, account = 91, publisher = 92
        case retention = 93, retentionDecode = 94, retentionShape = 95
        case retentionRequest = 96, retentionGraphs = 97, retentionPolicy = 98
        case resourcePostflight = 99, parentPostflight = 100
        case retentionSource = 101, retentionDestination = 102, retentionWorktree = 103
        case inheritedRetirement = 104
    }
    private final class TestingConstructionObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var stage = TestingConstructionStage.helper
        func record(_ value: TestingConstructionStage) {
            lock.lock(); defer { lock.unlock() }; stage = value
        }
        var failureCode: Int32 {
            lock.lock(); defer { lock.unlock() }; return stage.rawValue
        }
    }
    private static let testingConstructionObservation = TestingConstructionObservation()
    static func testingRecordConstructionStage(_ stage: TestingConstructionStage) {
        testingConstructionObservation.record(stage)
    }
    static var testingConstructionFailureCode: Int32 {
        testingConstructionObservation.failureCode
    }
    #endif
    #if SHADOW_SYNC_TESTING
    private(set) var testingPolicyTiming: TestingPolicyHelperTiming?
    #endif
    let request: UnvalidatedCustodyRequest
    let helper: CustodyHelperExecutable
    let identity: ProcessIdentity
    let parent: ProcessIdentity
    let account: EffectiveAccount
    let policy: PolicyCommandAuthority?
    let discovery: InheritedDiscoveryResources?
    let retention: InheritedRetentionArchiveResources?
    let repository: InheritedRepositoryGitResources?
    let installation: InstallationCommandBinding?
    private var installationStore: CustodyCatalogStore?
    private var stagedCandidate: InstallationStagedCandidateAuthority?
    private(set) var lifecycle: LifecycleLaunchAuthority?
    var lifecycleCommand: LifecycleLaunchCommand? {
        #if SHADOW_SYNC_TESTING
        if let fixtureMode { return LifecycleLaunchCommand.fixture(mode: fixtureMode, account: account) }
        #endif
        return lifecycle?.command
    }

    private(set) var frozenConfiguration: CustodyInheritedFrozenConfiguration?
    let statePath: String
    let descriptors: [CustodyDescriptorClaim.Role: OwnedFileDescriptor]
    let output: OwnedFileDescriptor, error: OwnedFileDescriptor
    private let sealedBytes: Data
    private let sealedInput: Data?, sealedCode: Data?
    private let snapshots: [CustodyDescriptorClaim.Role: Snapshot]
    #if SHADOW_SYNC_TESTING
    let fixtureMode: String?
    let testingDiscovery: Bool
    #endif

    private struct Snapshot: Equatable {
        let identity: FileIdentity
        let access: Int32
        let acl: String?
        static func capture(_ fd: Int32, role: CustodyDescriptorClaim.Role, uid: uid_t) throws -> Self {
            var s = stat(); let flags = fcntl(fd, F_GETFL), descriptorFlags = fcntl(fd, F_GETFD)
            guard fstat(fd, &s) == 0, flags >= 0, descriptorFlags >= 0, descriptorFlags & FD_CLOEXEC != 0 else { throw CustodyResourceError.invalidResource }
            let type = s.st_mode & S_IFMT, access = flags & O_ACCMODE
            switch role {
            case .request, .input, .code:
                let maximum: Int64 = role == .request ? 1_048_576 : 262_144
                guard type == S_IFREG, s.st_mode == S_IFREG | 0o400, s.st_nlink == 0,
                      s.st_uid == uid, access == O_RDONLY, s.st_size > 0, s.st_size <= maximum else { throw CustodyResourceError.invalidResource }
            case .control, .status, .traceOutput:
                guard type == S_IFIFO, s.st_uid == uid, s.st_nlink == 0, flags & O_NONBLOCK != 0,
                      access == (role == .control ? O_RDONLY : O_WRONLY) else { throw CustodyResourceError.invalidResource }
            case .workingDirectory:
                var root = stat()
                guard type == S_IFDIR, access == O_RDONLY, lstat("/", &root) == 0,
                      s.st_dev == root.st_dev, s.st_ino == root.st_ino, s.st_uid == 0 else { throw CustodyResourceError.invalidResource }
            case .retentionSource, .retentionDestination, .retentionWorktree:
                guard type == S_IFDIR, s.st_uid == uid, access == O_RDONLY,
                      role != .retentionDestination || s.st_mode == S_IFDIR | 0o700 else { throw CustodyResourceError.invalidResource }
            case .gitDirectory, .gitFile:
                guard type == (role == .gitFile ? S_IFREG : S_IFDIR),
                      s.st_mode == (role == .gitFile ? S_IFREG | 0o600 : S_IFDIR | 0o700),
                      s.st_uid == uid, role != .gitFile || s.st_nlink == 1,
                      s.st_flags & UInt32(UF_IMMUTABLE) != 0,
                      access == (role == .gitFile ? O_RDWR : O_RDONLY) else { throw CustodyResourceError.invalidResource }
            case .state:
                guard type == S_IFDIR, s.st_mode == S_IFDIR | 0o700, s.st_uid == uid, access == O_RDONLY else { throw CustodyResourceError.invalidResource }
            case .namespace, .lifecycle, .operation, .run:
                guard type == S_IFREG, s.st_mode == S_IFREG | 0o600, s.st_nlink == 1, s.st_uid == uid,
                      access == O_RDONLY || access == O_RDWR else { throw CustodyResourceError.invalidResource }
            default: throw CustodyResourceError.invalidResource
            }
            return Self(identity: FileIdentity(s), access: access,
                        acl: type == S_IFIFO ? nil : try PolicyAuthorityFile.safeACL(fd))
        }
        func claim(_ role: CustodyDescriptorClaim.Role) -> CustodyDescriptorClaim {
            CustodyDescriptorClaim(role: role, device: identity.device, inode: identity.inode,
                uid: identity.owner, mode: UInt32(identity.mode), links: UInt64(identity.linkCount),
                access: access == O_RDONLY ? .read : (access == O_RDWR ? .readWrite : .write))
        }
        func matches(_ other: Self) -> Bool {
            identity.matchesStableNode(other.identity) && (identity.isDirectory || identity.linkCount == other.identity.linkCount)
                && access == other.access && acl == other.acl
        }
    }
    private init(helper: CustodyHelperExecutable, fixture: Bool, discoveryFixture: Bool = false) throws {
        #if SHADOW_SYNC_TESTING
        testingDiscovery = discoveryFixture
        #else
        guard !discoveryFixture else { throw CustodyResourceError.invalidResource }
        #endif
        let usesRealWire = !fixture || discoveryFixture
        // Validate the original inherited set before creating any copies. Runtime
        // framework descriptors are not silently accepted as authority.
        #if SHADOW_SYNC_TESTING
        Self.testingRecordConstructionStage(.descriptors)
        #endif
        let actual = try Self.openDescriptors()
        let permitted: Set<Int32> = [0,1,2,7,8,9,10,11,12,190,191,192,193,194,195,196,197,198,199,200]
        guard actual.isSubset(of: permitted), Set([0,1,2,190,191,192,193,194,197,200]).isSubset(of: actual) else {
            throw CustodyResourceError.invalidResource
        }
        for fd in actual { guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw CustodyResourceError.invalidResource } }
        var nullInfo = stat(), observedNull = stat()
        guard fstat(0, &nullInfo) == 0, lstat("/dev/null", &observedNull) == 0,
              nullInfo.st_dev == observedNull.st_dev, nullInfo.st_ino == observedNull.st_ino,
              fcntl(0, F_GETFL) & O_ACCMODE == O_RDONLY else { throw CustodyResourceError.invalidResource }
        #if SHADOW_SYNC_TESTING
        Self.testingRecordConstructionStage(.request)
        #endif
        let raw = try Self.readSealed(190)
        let object = try CustodyWire.decode(raw, maximum: 1_048_576).object(keys: ["schema","binding","command","budget","limits","descriptors"])
        let binding = try CustodyBinding(wire: CustodyWire.required(object["binding"]))
        guard binding.trustedUID == geteuid(), binding.bootID == (try CustodyBootIdentity.current()),
              binding.releaseSHA256 == helper.releaseSHA256 else { throw CustodyRecordError.fenced }
        let command = try CustodyWire.required(object["command"]).object(keys: [
            "kind", "authority", "arguments", "environment", "input", "resources",
        ])
        guard let kind = CustodyCommandKind(rawValue: try CustodyWire.text(command["kind"])) else {
            throw CustodyProtocolError.invalidMessage
        }
        // The decoder also validates the adapter's ceiling itself. A generic
        // ten-second ceiling is invalid for the two-second policy contract.
        let request = try UnvalidatedCustodyRequest.decode(raw, expected: binding,
            permittedWorkSeconds: [.repositoryGit, .retentionArchive].contains(kind) ? kind.maximumWorkSeconds : (kind == .discoveryGit ? DiscoveryGitCommand.maximumWorkSeconds : min(10, kind.maximumWorkSeconds)))
        #if SHADOW_SYNC_TESTING
        Self.testingRecordConstructionStage(.roles)
        #endif
        let hasFrozenConfiguration = request.descriptors.contains { $0.role == .gitFile }
        let installationInput = request.authority.isInstallationStaged
            || (request.authority == .lifecycleMutation && request.kind == .launchctlRead && request.inputSHA256 != nil)
        // Coordinator roles cannot borrow repository authority. Mutation needs
        // actual lifecycle leases and the independently validated closed adapter.
        if helper.isLifecycleCoordinator {
            guard (request.authority == .observation && [.launchctlRead, .signatureCheck].contains(request.kind))
                || ((request.authority == .lifecycleMutation || request.authority.isInstallationStaged) && [.launchctlRead, .signatureCheck, .launchctlMutation].contains(request.kind)) else {
                throw CustodyResourceError.invalidResource
            }
        }
        if discoveryFixture {
            guard fixture, (hasFrozenConfiguration == ([.repositoryGit, .retentionArchive].contains(request.kind))),
                  [.repositoryGit, .retentionArchive, .policyClassify, .discoveryGit, .systemGitConfig].contains(request.kind) else {
                throw CustodyResourceError.invalidResource
            }
        }
        // Production discovery v2 carries only sealed intent. Frozen resources
        // are created by this helper after policy; inherited 195/196 refuse.
        var permittedKind = [.repositoryGit, .launchctlRead, .launchctlMutation, .signatureCheck, .policyClassify, .systemGitConfig].contains(request.kind)
            || (request.kind == .discoveryGit && !hasFrozenConfiguration)
            || (request.kind == .retentionArchive && hasFrozenConfiguration && request.authority == .mutation)
        #if SHADOW_SYNC_TESTING
        if fixture, !discoveryFixture, request.kind == .discoveryGit, request.traceLimit > 0 || hasFrozenConfiguration || request.arguments.first?.hasPrefix("serial-") == true { permittedKind = true }
        if fixture, request.kind == .policyClassify { permittedKind = true }
        #endif
        guard permittedKind, (request.inputSHA256 != nil) == (request.kind == .policyClassify
                || hasFrozenConfiguration || installationInput || (usesRealWire && request.kind == .discoveryGit)),
              !hasFrozenConfiguration || [.repositoryGit, .retentionArchive, .discoveryGit].contains(request.kind),
              ![.repositoryGit, .retentionArchive].contains(request.kind) || hasFrozenConfiguration,
              request.stdoutLimit <= ([.repositoryGit, .retentionArchive].contains(request.kind) ? UInt64(DescriptorProcessRunner.completeRepositoryOutputLimit) : (request.kind == .discoveryGit ? UInt64(DiscoveryGitCommand.stdoutLimit) : UInt64(LifecycleCommandRunner.outputLimit))),
              request.stderrLimit <= ([.repositoryGit, .retentionArchive].contains(request.kind) ? UInt64(DescriptorProcessRunner.completeRepositoryOutputLimit) : (request.kind == .discoveryGit ? UInt64(DiscoveryGitCommand.stderrLimit) : UInt64(LifecycleCommandRunner.outputLimit))) else {
            throw CustodyResourceError.invalidResource
        }
        var roles: Set<CustodyDescriptorClaim.Role> = [.request,.control,.status,.state,.namespace,.lifecycle,.workingDirectory]
        if request.authority.needsOperation { roles.insert(.operation) }
        if request.authority == .mutation { roles.insert(.run) }
        if request.traceLimit > 0 { roles.insert(.traceOutput) }
        if request.kind == .policyClassify { roles.formUnion([.input, .code]) }
        if usesRealWire, request.kind == .discoveryGit { roles.insert(.input) }
        if installationInput { roles.insert(.input) }
        if hasFrozenConfiguration { roles.formUnion([.input, .gitDirectory, .gitFile]) }
        if request.kind == .retentionArchive { roles.formUnion([.retentionSource, .retentionDestination, .retentionWorktree]) }
        guard Set(request.descriptors.map(\.role)) == roles,
              actual == Set(roles.map { Int32($0.number) }).union([0,1,2]) else {
            throw CustodyResourceError.invalidResource
        }
        // Content hashes are derived from actual inherited, unlinked read-only
        // resources. Decoded metadata alone cannot authenticate input or code.
        #if SHADOW_SYNC_TESTING
        Self.testingRecordConstructionStage(.input)
        #endif
        sealedInput = request.inputSHA256 != nil ? try Self.readSealed(8, role: .input) : nil
        sealedCode = request.kind == .policyClassify ? try Self.readSealed(9, role: .code) : nil
        if installationInput {
            guard let sealedInput else { throw CustodyRecordError.fenced }
            installation = try InstallationCommandBinding.decode(sealedInput)
        } else { installation = nil }
        let inputHash = sealedInput.map(CustodyRecordBinding.digest), codeHash = sealedCode.map(CustodyRecordBinding.digest)
        guard request.inputSHA256 == inputHash,
              try CustodyRequestResources.resourceDigest(request.descriptors, input: inputHash, code: codeHash) == request.resourcesSHA256 else {
            throw CustodyResourceError.invalidResource
        }
        #if SHADOW_SYNC_TESTING
        Self.testingRecordConstructionStage(.claims)
        #endif
        var owned: [CustodyDescriptorClaim.Role: OwnedFileDescriptor] = [:], snapshots: [CustodyDescriptorClaim.Role: Snapshot] = [:]
        for claim in request.descriptors {
            #if SHADOW_SYNC_TESTING
            switch claim.role {
            case .retentionSource: Self.testingRecordConstructionStage(.retentionSource)
            case .retentionDestination: Self.testingRecordConstructionStage(.retentionDestination)
            case .retentionWorktree: Self.testingRecordConstructionStage(.retentionWorktree)
            default: Self.testingRecordConstructionStage(.claims)
            }
            #endif
            let fd = Int32(claim.role.number), snapshot = try Snapshot.capture(fd, role: claim.role, uid: geteuid())
            guard snapshot.claim(claim.role) == claim else { throw CustodyResourceError.invalidResource }
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 201); guard copy >= 0 else { throw CustodyResourceError.invalidResource }
            owned[claim.role] = OwnedFileDescriptor(copy); snapshots[claim.role] = snapshot
        }
        func outputCopy(_ fd: Int32) throws -> OwnedFileDescriptor {
            var s = stat(); let flags = fcntl(fd, F_GETFL)
            guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFIFO, s.st_nlink == 0, s.st_uid == geteuid(),
                  flags >= 0, flags & O_ACCMODE == O_WRONLY, flags & O_NONBLOCK != 0,
                  fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw CustodyResourceError.invalidResource }
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 201); guard copy >= 0 else { throw CustodyResourceError.invalidResource }
            return OwnedFileDescriptor(copy)
        }
        #if SHADOW_SYNC_TESTING
        Self.testingRecordConstructionStage(.streams)
        #endif
        output = try outputCopy(1); error = try outputCopy(2)
        if let trace = owned[.traceOutput], fcntl(trace.value, F_SETNOSIGPIPE, 1) != 0 { throw CustodyResourceError.invalidResource }
        guard let status = owned[.status], fcntl(status.value, F_SETNOSIGPIPE, 1) == 0 else { throw CustodyResourceError.invalidResource }
        #if SHADOW_SYNC_TESTING
        Self.testingRecordConstructionStage(.parent)
        #endif
        let parentID = getppid(); guard parentID > 1 else { throw CustodyRecordError.fenced }
        parent = try helper.authenticateParent(parentID, generation: binding.callerGeneration)
        identity = try ProcessIdentity.capture(processID: getpid(), generation: binding.callerGeneration, expectedExecutablePath: helper.path)
        guard identity.processGroupID == getpid(), identity.userID == binding.trustedUID else { throw CustodyRecordError.fenced }
        self.helper = helper; self.request = request; descriptors = owned; self.snapshots = snapshots; sealedBytes = raw
        #if SHADOW_SYNC_TESTING
        Self.testingRecordConstructionStage(.account)
        #endif
        #if SHADOW_SYNC_TESTING
        if fixture {
            guard let home = request.environment["HOME"] else { throw CustodyResourceError.invalidResource }
            account = try EffectiveAccount.isolated(homeDirectory: home)
            let root = URL(fileURLWithPath: home).deletingLastPathComponent().path
            statePath = try StateLocation.isolated(root: root).path
            if discoveryFixture {
                if request.kind == .systemGitConfig { try helper.bindTestingDiscoveryResources(home: account.homeDirectory) }
                fixtureMode = nil
            } else if request.authority.isInstallationStaged, request.kind == .launchctlMutation {
                // Exact staged wire intent uses the existing fixed three-child
                // fixture adapter. No request may select a host executable or
                // skip the inherited installation/candidate checks below.
                let command = try LifecycleLaunchCommand(arguments: request.arguments, account: account)
                guard let installation else { throw CustodyRecordError.fenced }
                try installation.validateStagedOperation(mode: request.authority, operation: command.operation)
                // Closed disposable fixture scenarios reuse the existing real
                // three-child adapter; request arguments remain canonical.
                let outcomePath = home + "/.staged-reconciliation-outcome"
                var outcomeInfo = stat()
                if lstat(outcomePath, &outcomeInfo) == 0 {
                    let marker = try PolicyAuthorityFile.read(path: outcomePath, owner: account.uid, maximumBytes: 64)
                    guard command.operation == .bootstrap, outcomeInfo.st_mode == S_IFREG | 0o600,
                          let value = String(data: marker.bytes, encoding: .utf8),
                          ["lifecycle-mutation-failure", "lifecycle-mutation-cancel", "lifecycle-postflight-timeout"].contains(value) else {
                        throw CustodyRecordError.fenced
                    }
                    fixtureMode = value
                } else {
                    guard errno == ENOENT else { throw CustodyRecordError.fenced }
                    fixtureMode = "lifecycle-" + command.operation.rawValue
                }
            } else {
                guard request.arguments.count == 1,
                  ["installation-absent","installation-loaded","installation-foreign","complete","fail","wait","resist","overflow","after-admit","before-resume","after-preparation","terminal-delay","deadline-before-control",
                   "trace-complete","trace-overflow","trace-resist","policy-echo","policy-resist",
                    "system-complete","system-missing","system-faildata","system-resist","system-overflow",
                    "config-complete","config-resist-sigterm-fixture", "serial-complete", "serial-system-failure", "serial-policy-failure",
                    "serial-system-cancel", "serial-policy-cancel", "serial-command-cancel", "serial-between-cancel",
                    "serial-next-before-spawn", "serial-next-after-spawn", "serial-next-before-record",
                    "serial-system-missing-next-before-spawn", "serial-system-missing-next-after-spawn", "serial-system-missing-next-before-record",
                    "serial-policy-timeout", "serial-system-overflow", "serial-policy-overflow", "serial-policy-protected", "serial-policy-malformed", "serial-policy-wrong-nonce", "serial-policy-wrong-binding", "serial-policy-multiple-batches", "serial-system-missing", "serial-policy-code-batches", "serial-postflight-cancel", "serial-postflight-eof", "serial-postflight-timeout"].contains(request.arguments[0]) || LifecycleLaunchCommand.fixtureModes.contains(request.arguments[0]),
                  request.arguments[0].hasPrefix("lifecycle-") == (request.kind == .launchctlMutation),
                  (request.arguments[0].hasPrefix("trace-") || request.arguments[0].hasPrefix("config-") || request.arguments[0].hasPrefix("serial-")) == (request.kind == .discoveryGit),
                  request.arguments[0].hasPrefix("policy-") == (request.kind == .policyClassify),
                   request.arguments[0].hasPrefix("system-") == (request.kind == .systemGitConfig),
                  request.arguments[0].hasPrefix("trace-") == (request.traceLimit > 0),
                  request.arguments[0].hasPrefix("config-") == hasFrozenConfiguration else { throw CustodyResourceError.invalidResource }
                fixtureMode = request.arguments[0]
            }
        } else {
            account = try EffectiveAccount.current(); statePath = try StateLocation.production().path; fixtureMode = nil
        }
        #else
        guard !fixture else { throw CustodyResourceError.invalidResource }
        account = try EffectiveAccount.current(); statePath = try StateLocation.production().path
        #endif
        let expectedEnvironment = request.kind == .systemGitConfig
            ? SystemGitConfigurationCommand.environment(account: account) : ClosedProcessRunner.environment(account: account)
        guard request.kind == .retentionArchive || request.environment == expectedEnvironment else { throw CustodyResourceError.invalidResource }
        #if SHADOW_SYNC_TESTING
        Self.testingRecordConstructionStage(.publisher)
        #endif
        if usesRealWire, [.repositoryGit, .retentionArchive, .policyClassify, .discoveryGit].contains(request.kind) {
            guard request.authority == .read || request.authority == .mutation, let sealedInput else {
                throw CustodyResourceError.invalidResource
            }
            let publisher: PublisherPolicyResources
            #if SHADOW_SYNC_TESTING
            if discoveryFixture {
                try helper.bindTestingDiscoveryResources(home: account.homeDirectory)
                publisher = try PublisherPolicyResources.testingDiscovery(account: account)
            } else {
                publisher = try PublisherPolicyResources.production(account: account)
            }
            #else
            publisher = try PublisherPolicyResources.production(account: account)
            #endif
            let snapshot = try HostPolicySnapshot.load(account: account,
                contract: QualifiedAWAContract.decode(publisher.contract))
            let authority = try PolicyCommandAuthority(snapshot: snapshot, publisher: publisher, helper: helper)
            if request.kind == .policyClassify {
                guard request.arguments == PolicyCommandWire.logicalArguments, let sealedCode,
                      request.stdoutLimit <= 65_536, request.stderrLimit <= 65_536 else {
                    throw CustodyResourceError.invalidResource
                }
                try authority.validate(input: sealedInput, code: sealedCode)
                discovery = nil; repository = nil; retention = nil
            } else if request.kind == .repositoryGit {
                guard let directory = owned[.gitDirectory], let file = owned[.gitFile], sealedCode == nil else {
                    throw CustodyResourceError.invalidResource
                }
                repository = try InheritedRepositoryGitResources(bytes: sealedInput, request: request, policy: authority,
                    helper: helper, account: account, parent: parent, directory: directory, file: file)
                discovery = nil; retention = nil
            } else if request.kind == .retentionArchive {
                #if SHADOW_SYNC_TESTING
                Self.testingRecordConstructionStage(.retention)
                #endif
                guard let source = owned[.retentionSource], let target = owned[.retentionWorktree], let destination = owned[.retentionDestination],
                      let directory = owned[.gitDirectory], let file = owned[.gitFile], sealedCode == nil else { throw CustodyResourceError.invalidResource }
                discovery = nil; repository = nil
                retention = try InheritedRetentionArchiveResources(bytes: sealedInput, request: request, policy: authority,
                    helper: helper, account: account, statePath: statePath, parent: parent, source: source, target: target, destination: destination, directory: directory, file: file)
            } else {
                retention = nil
                repository = nil
                guard !hasFrozenConfiguration, sealedCode == nil else { throw CustodyResourceError.invalidResource }
                discovery = try InheritedDiscoveryResources(input: sealedInput, request: request,
                    policy: authority, helper: helper, account: account, parent: parent.processID)
            }
            policy = authority
        } else {
            policy = nil; discovery = nil; retention = nil; repository = nil
            if !fixture, request.kind == .systemGitConfig {
                try SystemGitConfigurationCommand.validate(request, account: account)
            } else if !fixture, request.kind == .launchctlMutation {
                lifecycle = try LifecycleLaunchAuthority(request: request, helper: helper, account: account, installation: installation)
            } else if !fixture {
                let expected = request.kind == .launchctlRead
                    ? ["print", "gui/\(account.uid)/\(InstallationPaths.label)"]
                    : ["--verify", "--strict", "--verbose=2", account.homeDirectory + "/Applications/ShadowSync.app"]
                guard request.arguments == expected else { throw CustodyResourceError.invalidResource }
            }
        }
        // The fixture authenticates the real parent before decoding any frozen
        // pathname. Production discovery defers this pathname validation until
        // the serial policy batches have admitted every required resource.
        #if SHADOW_SYNC_TESTING
        if fixture, !discoveryFixture, hasFrozenConfiguration {
            guard let sealedInput, let directory = owned[.gitDirectory], let file = owned[.gitFile] else {
                throw CustodyResourceError.invalidResource
            }
            frozenConfiguration = try CustodyInheritedFrozenConfiguration(
                snapshot: CustodyInheritedFrozenConfiguration.fixtureSnapshot(sealedInput, parent: parent.processID),
                directory: directory, file: file)
        }
        #endif
        // No inherited original survives into a target. The retained duplicates
        // describe the same held locks; none is unlocked or reacquired.
        #if SHADOW_SYNC_TESTING
        Self.testingRecordConstructionStage(.inheritedRetirement)
        #endif
        for fd in actual where fd > 2 { close(fd) }
        if let installation {
            #if SHADOW_SYNC_TESTING
            if fixture { try helper.bindTestingInstallationSource(root: URL(fileURLWithPath: account.homeDirectory).deletingLastPathComponent().path) }
            #endif
            try installation.validateParent(parent, helper: helper)
            guard request.authority == (installation.stagedMode ?? .lifecycleMutation) else { throw CustodyRecordError.fenced }
            if installation.control.step?.action == .candidateReady {
                guard request.kind == .launchctlRead else { throw CustodyRecordError.fenced }
            }
            if request.authority.isInstallationStaged {
                if request.kind == .launchctlMutation {
                    let operation = try LifecycleLaunchCommand(arguments: request.arguments, account: account).operation
                    try installation.validateStagedOperation(mode: request.authority, operation: operation)
                }
                stagedCandidate = try InstallationStagedCandidateAuthority(binding: installation, helper: helper, account: account)
            }
            installationStore = try CustodyCatalogStore(leases: CustodyAuthorityLeaseSet.importing(self))
        }
        #if SHADOW_SYNC_TESTING
        Self.testingRecordConstructionStage(.resourcePostflight)
        #endif
        try revalidateResources()
        #if SHADOW_SYNC_TESTING
        Self.testingRecordConstructionStage(.parentPostflight)
        #endif
        try revalidateParent()
        #if SHADOW_SYNC_TESTING
        let savedTimingErrno = errno
        defer { errno = savedTimingErrno }
        if testingDiscovery, helper.testingPolicyTimingEligible, request.kind == .policyClassify,
           TestingPolicyHelperTiming.childOptedIn {
            let timing = TestingPolicyHelperTiming()
            timing.mark(.constructorFinished)
            testingPolicyTiming = timing
        }
        #endif
    }
    static func production() throws -> CustodyInheritedCommand { try Self(helper: CustodyHelperExecutable.production(), fixture: false) }
    static func lifecycle() throws -> CustodyInheritedCommand {
        try Self(helper: CustodyHelperExecutable.lifecycle(LifecyclePublisher.current()), fixture: false)
    }
    #if SHADOW_SYNC_TESTING
    static func testing() throws -> CustodyInheritedCommand {
        try Self(helper: CustodyHelperExecutable.testing(releaseSHA256: String(repeating: "c", count: 64)), fixture: true)
    }
    static func testingDiscovery() throws -> CustodyInheritedCommand {
        try Self(helper: CustodyHelperExecutable.testingDiscovery(), fixture: true, discoveryFixture: true)
    }
    #endif
    func revalidateParent() throws {
        guard getppid() == parent.processID,
              try helper.authenticateParent(parent.processID, generation: parent.generation) == parent else { throw CustodyRecordError.fenced }
    }
    func revalidateResources() throws {
        try revalidatePersistenceResources()
        try installationStore?.checkInheritedInstallation(self)
        try stagedCandidate?.revalidate()
        try discovery?.revalidate(); try retention?.revalidate(); try repository?.revalidate()
        try lifecycle?.revalidate()
        try frozenConfiguration?.revalidate()
    }
    func revalidatePersistenceResources() throws {
        try helper.revalidate(); try policy?.revalidate()
        guard request.binding.bootID == (try CustodyBootIdentity.current()),
              identity == (try ProcessIdentity.capture(processID: getpid(), generation: identity.generation, expectedExecutablePath: helper.path)) else { throw CustodyRecordError.fenced }
        for (role, fd) in descriptors {
            guard let expected = snapshots[role], try Snapshot.capture(fd.value, role: role, uid: geteuid()).matches(expected) else { throw CustodyResourceError.invalidResource }
        }
        guard let reader = descriptors[.request], try Self.readSealed(reader.value) == sealedBytes,
              let root = descriptors[.state] else { throw CustodyResourceError.invalidResource }
        if let sealedInput {
            guard let input = descriptors[.input], try Self.readSealed(input.value, role: .input) == sealedInput else {
                throw CustodyResourceError.invalidResource
            }
        }
        if let sealedCode {
            guard let code = descriptors[.code], try Self.readSealed(code.value, role: .code) == sealedCode else {
                throw CustodyResourceError.invalidResource
            }
        }
        let named = open(statePath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard named >= 0 else { throw CustodyRecordError.fenced }; defer { close(named) }
        var held = stat(), current = stat()
        guard fstat(root.value, &held) == 0, fstat(named, &current) == 0,
              FileIdentity(held).matchesStableNode(FileIdentity(current)) else { throw CustodyRecordError.fenced }
    }
    private static func readSealed(_ fd: Int32, role: CustodyDescriptorClaim.Role = .request) throws -> Data {
        guard [.request, .input, .code].contains(role) else { throw CustodyResourceError.invalidResource }
        let before = try Snapshot.capture(fd, role: role, uid: geteuid())
        var s = stat(); guard fstat(fd, &s) == 0 else { throw CustodyResourceError.invalidResource }
        var data = Data(count: Int(s.st_size))
        try data.withUnsafeMutableBytes { b in
            var offset = 0
            while offset < b.count {
                let n = pread(fd, b.baseAddress!.advanced(by: offset), b.count-offset, off_t(offset))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw CustodyResourceError.invalidResource }; offset += n
            }
        }
        guard try Snapshot.capture(fd, role: role, uid: geteuid()) == before else { throw CustodyResourceError.invalidResource }
        return data
    }
    private static func openDescriptors() throws -> Set<Int32> {
        let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0, size < 65_536 else { throw CustodyResourceError.invalidResource }
        var rows = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size)/MemoryLayout<proc_fdinfo>.stride+32)
        let capacity = rows.count * MemoryLayout<proc_fdinfo>.stride
        let actual = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &rows, Int32(capacity))
        guard actual > 0, actual < capacity, Int(actual)%MemoryLayout<proc_fdinfo>.stride == 0 else { throw CustodyResourceError.invalidResource }
        return Set(rows.prefix(Int(actual)/MemoryLayout<proc_fdinfo>.stride).map(\.proc_fd))
    }
}
