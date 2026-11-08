import Darwin
import Foundation

private enum RemovalAdmissionRefusal: Error {
    case branchClaims
    case hardBoundary
}

public enum RemovalTerminalStatus:
    String, Codable, Equatable, Sendable {
    case succeeded
    case skipped
    case refused
    case failed
    case cancelled
}

public enum AWACleanupDisposition:
    String, Codable, Equatable, Sendable {
    case notApplicable
    case succeeded
    case refused
    case unavailable
    case cancelled
}

public struct RemovalCommandEvidence:
    Codable, Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let forceLevel: RemovalForceLevel
    public let outcome: String

    public init(
        executable: String,
        arguments: [String],
        forceLevel: RemovalForceLevel,
        outcome: String
    ) {
        self.executable = executable
        self.arguments = arguments
        self.forceLevel = forceLevel
        self.outcome = Redactor.sanitize(outcome)
    }
}

public struct RemovalResidue:
    Codable, Equatable, Sendable {
    public let pathPresent: Bool?
    public let worktreeRegistrationPresent: Bool?
    public let localRefPresent: Bool?
    public let claims: [String]
    public let artifactIntact: Bool?
    public let awaState: AWAEvidenceState?
    public let needsAttention: Bool

    public init(
        pathPresent: Bool?,
        worktreeRegistrationPresent: Bool?,
        localRefPresent: Bool?,
        claims: [String],
        artifactIntact: Bool?,
        awaState: AWAEvidenceState?,
        needsAttention: Bool
    ) {
        self.pathPresent = pathPresent
        self.worktreeRegistrationPresent =
            worktreeRegistrationPresent
        self.localRefPresent = localRefPresent
        self.claims = claims.sorted()
        self.artifactIntact = artifactIntact
        self.awaState = awaState
        self.needsAttention = needsAttention
    }
}

public struct RemovalExecutionResult:
    Codable, Equatable, Sendable {
    public let candidateID: String
    public let repositoryID: String
    public let kind: RemovalEntityKind
    public let target: String
    public let status: RemovalTerminalStatus
    public let finalClass: RemovalFinalClass
    public let awaDisposition: AWACleanupDisposition
    public let commands: [RemovalCommandEvidence]
    public let residue: RemovalResidue
    public let explanation: String
    public let startedAt: String
    public let endedAt: String
    public let durationMilliseconds: Int64

    public init(
        prepared: PreparedRemoval,
        status: RemovalTerminalStatus,
        awaDisposition: AWACleanupDisposition,
        commands: [RemovalCommandEvidence],
        residue: RemovalResidue,
        explanation: String,
        startedAt: String,
        durationMilliseconds: Int64
    ) {
        let candidate = prepared.selection.candidate
        candidateID = candidate.id
        repositoryID = candidate.repository.id
        kind = candidate.kind
        target = candidate.target
        self.status = status
        finalClass = prepared.finalClass
        self.awaDisposition = awaDisposition
        self.commands = commands
        self.residue = residue
        self.explanation = Redactor.sanitize(explanation)
        self.startedAt = startedAt
        endedAt = WallClock.timestamp()
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct RemovalTransactionConfiguration:
    Sendable {
    public let git: GitTransactionConfiguration
    public let stateLocation: StateLocation
    public let awaExecutablePath: String
    public let protectedPaths: [String]

    public init(
        git: GitTransactionConfiguration,
        stateLocation: StateLocation,
        awaExecutablePath: String,
        protectedPaths: [String]
    ) {
        self.git = git
        self.stateLocation = stateLocation
        self.awaExecutablePath = awaExecutablePath
        self.protectedPaths = protectedPaths
    }

    public static func production(
        git: GitTransactionConfiguration,
        account: EffectiveAccount,
        executablePath: String
    ) throws -> RemovalTransactionConfiguration {
        let state = try StateLocation.production()
        return RemovalTransactionConfiguration(
            git: git,
            stateLocation: state,
            // No implicit host-tool discovery. The private policy-bound
            // adapter remains unavailable until its integration is qualified.
            awaExecutablePath: "",
            protectedPaths: [
                state.path,
                executablePath,
                URL(fileURLWithPath: executablePath)
                    .deletingLastPathComponent().path,
            ]
        )
    }
}

public final class AWAWorktreeCleanupAdapter:
    @unchecked Sendable {
    private struct ExecutableSnapshot: Equatable {
        let identity: FileIdentity
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    private let executablePath: String
    private let runner: ClosedProcessRunner
    private let account: EffectiveAccount

    public init(
        executablePath: String,
        runner: ClosedProcessRunner = ClosedProcessRunner(),
        account: EffectiveAccount
    ) {
        self.executablePath = executablePath
        self.runner = runner
        self.account = account
    }

    public func clean(
        worktree: Worktree,
        workingDirectoryDescriptor: Int32,
        cancellation: CancellationToken
    ) -> (
        disposition: AWACleanupDisposition,
        command: RemovalCommandEvidence?
    ) {
        guard worktree.locationKind == .awaManaged else {
            return (.notApplicable, nil)
        }
        let arguments = ["clean", "--path", worktree.path]
        #if !SHADOW_SYNC_TESTING
        // No private-policy-bound adapter is qualified. Refuse before opening
        // an executable or constructing a deployment environment.
        return (.unavailable, RemovalCommandEvidence(
            executable: executablePath,
            arguments: arguments,
            forceLevel: .ordinaryOnly,
            outcome: "AWA cleanup adapter is unavailable."
        ))
        #else
        guard let opened = openAdapterExecutable()
                else {
            return (
                .unavailable,
                RemovalCommandEvidence(
                    executable: executablePath,
                    arguments: arguments,
                    forceLevel: .ordinaryOnly,
                    outcome: "AWA cleanup adapter is unavailable."
                )
            )
        }
        let executableSnapshot = opened.snapshot
        defer { Darwin.close(opened.descriptor) }
        do {
            let result = try runner.run(
                command: ClosedProcessCommand(
                    executable: "/bin/bash",
                    arguments: [
                        "/dev/fd/\(ClosedProcessCommand.inheritedReadDescriptorNumber)",
                    ] + arguments,
                    logicalExecutable: executablePath,
                    logicalArguments: arguments,
                    inheritedReadDescriptor:
                        opened.descriptor
                ),
                environment: ClosedProcessRunner.awaEnvironment(
                    account: account
                ),
                workingDirectoryDescriptor:
                    workingDirectoryDescriptor,
                account: account,
                timeout: 120,
                cancellation: cancellation
            )
            guard validateAdapterExecutable()
                    == executableSnapshot else {
                return (
                    .unavailable,
                    RemovalCommandEvidence(
                        executable: executablePath,
                        arguments: arguments,
                        forceLevel: .ordinaryOnly,
                        outcome:
                            "AWA cleanup adapter identity changed; its result was not trusted."
                    )
                )
            }
            if result.cancelled {
                return (
                    .cancelled,
                    RemovalCommandEvidence(
                        executable: executablePath,
                        arguments: arguments,
                        forceLevel: .ordinaryOnly,
                        outcome: "AWA cleanup was cancelled and reaped."
                    )
                )
            }
            if result.succeeded {
                return (
                    .succeeded,
                    RemovalCommandEvidence(
                        executable: executablePath,
                        arguments: arguments,
                        forceLevel: .ordinaryOnly,
                        outcome:
                            "AWA normal cleanup returned success; Git and path postflight remains authoritative."
                    )
                )
            }
            if result.status == 3 {
                return (
                    .unavailable,
                    RemovalCommandEvidence(
                        executable: executablePath,
                        arguments: arguments,
                        forceLevel: .ordinaryOnly,
                        outcome:
                            "AWA normal cleanup is unavailable; this remains advisory."
                    )
                )
            }
            return (
                .refused,
                RemovalCommandEvidence(
                    executable: executablePath,
                    arguments: arguments,
                    forceLevel: .ordinaryOnly,
                    outcome:
                        "AWA normal cleanup refused; this remains advisory."
                )
            )
        } catch {
            return (
                cancellation.isCancelled
                    ? .cancelled : .unavailable,
                RemovalCommandEvidence(
                    executable: executablePath,
                    arguments: arguments,
                    forceLevel: .ordinaryOnly,
                    outcome: cancellation.isCancelled
                        ? "AWA cleanup was cancelled."
                        : "AWA cleanup adapter is unavailable."
                )
            )
        }
        #endif
    }

    private func validateAdapterExecutable()
        -> ExecutableSnapshot? {
        guard let opened = openAdapterExecutable()
                else { return nil }
        defer { Darwin.close(opened.descriptor) }
        return opened.snapshot
    }

    private func openAdapterExecutable()
        -> (
            descriptor: Int32,
            snapshot: ExecutableSnapshot
        )? {
        guard executablePath.hasPrefix(
            account.homeDirectory + "/"
        ) else {
            return nil
        }
        let descriptor = Darwin.open(
            executablePath,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return nil }
        var opened = stat()
        var observed = stat()
        guard fstat(descriptor, &opened) == 0
            && lstat(executablePath, &observed) == 0
            && FileIdentity(opened).isRegular
            && opened.st_uid == account.uid
            && opened.st_nlink == 1
            && opened.st_dev == observed.st_dev
            && opened.st_ino == observed.st_ino
            && (opened.st_mode & 0o022) == 0
            && (opened.st_mode & 0o111) != 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return (
            descriptor,
            ExecutableSnapshot(
                identity: FileIdentity(opened),
                size: Int64(opened.st_size),
                modifiedSeconds:
                    Int64(opened.st_mtimespec.tv_sec),
                modifiedNanoseconds:
                    Int64(opened.st_mtimespec.tv_nsec)
            )
        )
    }
}

public final class RemovalTransaction:
    @unchecked Sendable {
    private let runner: DescriptorProcessRunner
    private let configuration:
        RemovalTransactionConfiguration
    private let account: EffectiveAccount
    private let awa: AWAWorktreeCleanupAdapter

    public init(
        runner: DescriptorProcessRunner,
        configuration: RemovalTransactionConfiguration,
        account: EffectiveAccount,
        awaRunner: ClosedProcessRunner = ClosedProcessRunner()
    ) {
        self.runner = runner
        self.configuration = configuration
        self.account = account
        awa = AWAWorktreeCleanupAdapter(
            executablePath:
                configuration.awaExecutablePath,
            runner: awaRunner,
            account: account
        )
    }

    public func execute(
        prepared: PreparedRemoval,
        confirmation: GroupedRemovalConfirmation,
        cancellation: CancellationToken
    ) -> RemovalExecutionResult {
        let startedAt = WallClock.timestamp()
        let started = MonotonicInstant.now()
        var commands: [RemovalCommandEvidence] = []
        var awaDisposition:
            AWACleanupDisposition = .notApplicable

        func result(
            _ status: RemovalTerminalStatus,
            residue: RemovalResidue,
            explanation: String
        ) -> RemovalExecutionResult {
            RemovalExecutionResult(
                prepared: prepared,
                status: status,
                awaDisposition: awaDisposition,
                commands: commands,
                residue: residue,
                explanation: explanation,
                startedAt: startedAt,
                durationMilliseconds:
                    MonotonicInstant.now().milliseconds(
                        since: started
                    )
            )
        }

        guard confirmation.authorizes(prepared),
              confirmation.run.count > 0 else {
            return result(
                .skipped,
                residue: emptyResidue(prepared),
                explanation:
                    "This row was not retained in the grouped final confirmation."
            )
        }
        if cancellation.isCancelled {
            return result(
                .cancelled,
                residue: postflight(prepared),
                explanation:
                    "Removal was cancelled before child admission."
            )
        }
        do {
            try validateHardBoundaries(prepared)
            try validateRuntimeEligibility(
                prepared.selection.candidate
            )
            if prepared.selection.candidate.kind == .worktree {
                let candidate =
                    prepared.selection.candidate
                let primary = try RepositoryHandle.open(
                    candidate.clone.sourceSnapshot
                )
                let target = try RepositoryHandle.open(
                    candidate.clone.sourceSnapshot,
                    targetWorktree: candidate.worktree!
                )
                try validateArtifact(prepared)
                let frozen = try freeze(primary)
                let admission = try validateOrigin(
                    handle: primary,
                    frozen: frozen,
                    cancellation: cancellation
                )
                try validateFreshWorktree(
                    prepared,
                    target: target,
                    frozen: frozen,
                    admission: admission,
                    cancellation: cancellation
                )
                let protectedRefs =
                    try protectedWorktreeRefSnapshot(
                        candidate,
                        handle: primary,
                        frozen: frozen,
                        admission: admission,
                        cancellation: cancellation
                    )
                let awaResult = awa.clean(
                    worktree: candidate.worktree!,
                    workingDirectoryDescriptor:
                        primary.worktreeDescriptor,
                    cancellation: cancellation
                )
                awaDisposition = awaResult.disposition
                if let command = awaResult.command {
                    commands.append(command)
                }
                if awaDisposition == .cancelled {
                    return result(
                        .cancelled,
                        residue: postflightWorktree(
                            prepared,
                            expectedRefs: protectedRefs,
                            handle: primary,
                            frozen: frozen,
                            admission: admission
                        ),
                        explanation:
                            "AWA cleanup was cancelled; completed recovery remains protected."
                    )
                }
                if awaDisposition == .succeeded {
                    let residue = postflightWorktree(
                        prepared,
                        expectedRefs: protectedRefs,
                        handle: primary,
                        frozen: frozen,
                        admission: admission
                    )
                    if residue.pathPresent == false,
                       residue.worktreeRegistrationPresent
                        == false,
                       !residue.needsAttention {
                        return result(
                            .succeeded,
                            residue: residue,
                            explanation:
                                "Normal AWA cleanup removed the Worktree. "
                                + (residue.awaState == .notManaged
                                    ? "No AWA residue remains."
                                    : "AWA still reports \(residue.awaState?.rawValue ?? "unknown") state; that bookkeeping is advisory residue.")
                        )
                    }
                    return result(
                        .failed,
                        residue: residue,
                        explanation:
                            "AWA returned success, but independent Git/path postflight did not prove complete removal. No native fallback was started after a claimed success."
                    )
                }
                let lock = try primary
                    .acquireCommonDirectoryOperationLock(
                        account: account
                    )
                defer { _ = lock }
                let freshPrimary = try RepositoryHandle.open(
                    candidate.clone.sourceSnapshot
                )
                let freshTarget = try RepositoryHandle.open(
                    candidate.clone.sourceSnapshot,
                    targetWorktree: candidate.worktree!
                )
                let freshFrozen = try freeze(freshPrimary)
                let freshAdmission = try validateOrigin(
                    handle: freshPrimary,
                    frozen: freshFrozen,
                    cancellation: cancellation
                )
                try validateFreshWorktree(
                    prepared,
                    target: freshTarget,
                    frozen: freshFrozen,
                    admission: freshAdmission,
                    cancellation: cancellation
                )
                guard try protectedWorktreeRefSnapshot(
                    candidate,
                    handle: freshPrimary,
                    frozen: freshFrozen,
                    admission: freshAdmission,
                    cancellation: cancellation
                ) == protectedRefs else {
                    throw GitSafetyError.unsafeRepository(
                        "protected refs changed before native worktree removal"
                    )
                }
                let ordinary = worktreeArguments(
                    prepared,
                    commonDirectory:
                        freshPrimary.identity
                            .commonDirectoryPath,
                    force: .ordinaryOnly
                )
                let first = try runGit(
                    ordinary,
                    handle: freshTarget,
                    validationHandle: freshPrimary,
                    frozen: freshFrozen,
                    admission: freshAdmission,
                    cancellation: cancellation
                )
                commands.append(RemovalCommandEvidence(
                    executable: DescriptorProcessRunner.gitPath,
                    arguments: ordinary,
                    forceLevel: .ordinaryOnly,
                    outcome: first.succeeded
                        ? "Git ordinary worktree removal completed."
                        : "Git ordinary worktree removal refused."
                ))
                if cancellation.isCancelled {
                    return result(
                        .cancelled,
                        residue: postflightWorktree(
                            prepared,
                            expectedRefs: protectedRefs,
                            handle: freshPrimary,
                            frozen: freshFrozen,
                            admission: freshAdmission
                        ),
                        explanation:
                            "Removal child was stopped and reaped; postflight reports any partial residue."
                    )
                }
                if first.succeeded {
                    let residue = postflightWorktree(
                        prepared,
                        expectedRefs: protectedRefs,
                        handle: freshPrimary,
                        frozen: freshFrozen,
                        admission: freshAdmission
                    )
                    return result(
                        residue.needsAttention
                            ? .failed : .succeeded,
                        residue: residue,
                        explanation: residue.needsAttention
                            ? "Git returned success but Worktree residue needs attention."
                            : completionCopy(
                                prepared,
                                residue: residue
                            )
                    )
                }
                let refusal = WorktreeRemovalRefusal(
                    result: first
                )
                let admittedForce:
                    RemovalForceLevel?
                switch (
                    refusal,
                    prepared.forceLevel
                ) {
                case (.dirty, .singleForce):
                    admittedForce = .singleForce
                case (.dirty, .doubleForceLocked):
                    admittedForce = .singleForce
                case (.locked, .doubleForceLocked):
                    admittedForce = .doubleForceLocked
                default:
                    admittedForce = nil
                }
                guard let admittedForce else {
                    return result(
                        .refused,
                        residue: postflightWorktree(
                            prepared,
                            expectedRefs: protectedRefs,
                            handle: freshPrimary,
                            frozen: freshFrozen,
                            admission: freshAdmission
                        ),
                        explanation:
                            "Git refused the ordinary command outside the exact confirmed force path. No filesystem fallback exists."
                    )
                }
                let beforeForce = try RepositoryHandle.open(
                    candidate.clone.sourceSnapshot,
                    targetWorktree: candidate.worktree!
                )
                try validateFreshWorktree(
                    prepared,
                    target: beforeForce,
                    frozen: freshFrozen,
                    admission: freshAdmission,
                    cancellation: cancellation
                )
                guard try protectedWorktreeRefSnapshot(
                    candidate,
                    handle: freshPrimary,
                    frozen: freshFrozen,
                    admission: freshAdmission,
                    cancellation: cancellation
                ) == protectedRefs else {
                    throw GitSafetyError.unsafeRepository(
                        "protected refs changed before confirmed worktree removal"
                    )
                }
                let forced = worktreeArguments(
                    prepared,
                    commonDirectory:
                        freshPrimary.identity
                            .commonDirectoryPath,
                    force: admittedForce
                )
                let forcedResult = try runGit(
                    forced,
                    handle: beforeForce,
                    validationHandle: freshPrimary,
                    frozen: freshFrozen,
                    admission: freshAdmission,
                    cancellation: cancellation
                )
                commands.append(RemovalCommandEvidence(
                    executable: DescriptorProcessRunner.gitPath,
                    arguments: forced,
                    forceLevel: admittedForce,
                    outcome: forcedResult.succeeded
                        ? "Git confirmed-force worktree removal completed."
                        : "Git confirmed-force worktree removal refused."
                ))
                let residue = postflightWorktree(
                    prepared,
                    expectedRefs: protectedRefs,
                    handle: freshPrimary,
                    frozen: freshFrozen,
                    admission: freshAdmission
                )
                if cancellation.isCancelled {
                    return result(
                        .cancelled,
                        residue: residue,
                        explanation:
                            "Confirmed removal was interrupted; completed artifacts remain protected and residue was inspected."
                    )
                }
                return result(
                    forcedResult.succeeded
                        && !residue.needsAttention
                        ? .succeeded : .failed,
                    residue: residue,
                    explanation:
                        forcedResult.succeeded
                            && !residue.needsAttention
                        ? completionCopy(
                            prepared,
                            residue: residue
                        )
                        : "Deferred last-resort cleanup: Git could not fully remove this Worktree. Path, ref, and artifact were not manually deleted."
                )
            }

            let candidate = prepared.selection.candidate
            let primary = try RepositoryHandle.open(
                candidate.clone.sourceSnapshot
            )
            let lock = try primary
                .acquireCommonDirectoryOperationLock(
                    account: account
                )
            defer { _ = lock }
            try validateArtifact(prepared)
            let frozen = try freeze(primary)
            let admission = try validateOrigin(
                handle: primary,
                frozen: frozen,
                cancellation: cancellation
            )
            let branch = candidate.branch!
            try validateFreshBranch(
                prepared,
                handle: primary,
                frozen: frozen,
                admission: admission,
                cancellation: cancellation
            )
            let defaultsBefore = try defaultRefSnapshot(
                candidate,
                handle: primary,
                frozen: frozen,
                admission: admission,
                cancellation: cancellation
            )
            let defaultWorktree = candidate.clone.worktrees
                .first {
                    $0.attachedBranchRef
                        == candidate.repository.resolvedDefault?
                            .localRef
                        && $0.verification == .verified
                }
            let useBranchDelete =
                prepared.finalClass == .recommended
            var postflightHandle = primary
            var postflightFrozen = frozen
            var postflightAdmission = admission
            if useBranchDelete, let defaultWorktree {
                let defaultHandle = try RepositoryHandle.open(
                    candidate.clone.sourceSnapshot,
                    targetWorktree: defaultWorktree
                )
                try validateFreshBranch(
                    prepared,
                    handle: defaultHandle,
                    frozen: frozen,
                    admission: admission,
                    cancellation: cancellation
                )
                let arguments = Self.localArguments([
                    "-C", defaultWorktree.path,
                    "branch", "-d", branch.name,
                ])
                let deleted = try runGit(
                    arguments,
                    handle: defaultHandle,
                    validationHandle: defaultHandle,
                    frozen: frozen,
                    admission: admission,
                    cancellation: cancellation
                )
                commands.append(RemovalCommandEvidence(
                    executable: DescriptorProcessRunner.gitPath,
                    arguments: arguments,
                    forceLevel: .ordinaryOnly,
                    outcome: deleted.succeeded
                        ? "Git ancestry-aware branch deletion completed."
                        : "Git ancestry-aware branch deletion refused without CAS fallback."
                ))
                postflightHandle =
                    try reopenAfterBranchDeletion(
                        candidate.clone.sourceSnapshot
                    )
                postflightFrozen =
                    try freeze(postflightHandle)
                postflightAdmission =
                    try validateOrigin(
                        handle: postflightHandle,
                        frozen: postflightFrozen,
                        cancellation:
                            CancellationToken()
                    )
                if cancellation.isCancelled {
                    return result(
                        .cancelled,
                        residue: postflightBranch(
                            prepared,
                            expectedDefaults:
                                defaultsBefore,
                            handle: postflightHandle,
                            frozen: postflightFrozen,
                            admission:
                                postflightAdmission
                        ),
                        explanation:
                            "Branch removal child was stopped and reaped; exact ref and claim residue was inspected."
                    )
                }
                guard deleted.succeeded else {
                    return result(
                        .refused,
                        residue: postflightBranch(
                            prepared,
                            expectedDefaults:
                                defaultsBefore,
                            handle: postflightHandle,
                            frozen: postflightFrozen,
                            admission:
                                postflightAdmission
                        ),
                        explanation:
                            "branch -d refused. No unconfirmed CAS fallback was attempted."
                    )
                }
            } else {
                guard prepared.finalClass == .recoveryBacked
                        || prepared.historyLossAccepted
                        || candidate.hasVerifiedHistorySink
                        || candidate.preview.recommendation
                            == .recommended else {
                    return result(
                        .refused,
                        residue: postflight(prepared),
                        explanation:
                            "Exact branch CAS lacks a verified preservation sink or confirmed history-loss override."
                    )
                }
                try validateFreshBranch(
                    prepared,
                    handle: primary,
                    frozen: frozen,
                    admission: admission,
                    cancellation: cancellation
                )
                let arguments = Self.localArguments([
                    "--git-dir=\(primary.identity.commonDirectoryPath)",
                    "update-ref", "-d",
                    branch.fullRef,
                    branch.tipOID!,
                ])
                let deleted = try runGit(
                    arguments,
                    handle: primary,
                    validationHandle: primary,
                    frozen: frozen,
                    admission: admission,
                    cancellation: cancellation
                )
                commands.append(RemovalCommandEvidence(
                    executable: DescriptorProcessRunner.gitPath,
                    arguments: arguments,
                    forceLevel: .ordinaryOnly,
                    outcome: deleted.succeeded
                        ? "Git expected-old branch CAS completed."
                        : "Git expected-old branch CAS refused."
                ))
                if cancellation.isCancelled {
                    return result(
                        .cancelled,
                        residue: postflightBranch(
                            prepared,
                            expectedDefaults:
                                defaultsBefore,
                            handle: primary,
                            frozen: frozen,
                            admission: admission
                        ),
                        explanation:
                            "Branch CAS child was stopped and reaped; exact ref and claim residue was inspected."
                    )
                }
                guard deleted.succeeded else {
                    return result(
                        .refused,
                        residue: postflightBranch(
                            prepared,
                            expectedDefaults:
                                defaultsBefore,
                            handle: primary,
                            frozen: frozen,
                            admission: admission
                        ),
                        explanation:
                            "Exact expected-old branch CAS refused; the local ref remains."
                    )
                }
            }
            let defaultsAfter = try defaultRefSnapshot(
                candidate,
                handle: postflightHandle,
                frozen: postflightFrozen,
                admission: postflightAdmission,
                cancellation: cancellation
            )
            let residue = postflightBranchResidue(
                prepared,
                handle: postflightHandle,
                frozen: postflightFrozen,
                admission: postflightAdmission
            )
            guard defaultsBefore == defaultsAfter else {
                return result(
                    .failed,
                    residue: RemovalResidue(
                        pathPresent: residue.pathPresent,
                        worktreeRegistrationPresent:
                            residue.worktreeRegistrationPresent,
                        localRefPresent:
                            residue.localRefPresent,
                        claims: residue.claims,
                        artifactIntact:
                            residue.artifactIntact,
                        awaState: residue.awaState,
                        needsAttention: true
                    ),
                    explanation:
                        "Branch postflight detected unexpected default or remote-ref drift."
                )
            }
            return result(
                residue.needsAttention
                    ? .failed : .succeeded,
                residue: residue,
                explanation: residue.needsAttention
                    ? "Branch removal left unexpected residue."
                    : completionCopy(
                        prepared,
                        residue: residue
                    )
            )
        } catch GitSafetyError.cancelled {
            return result(
                .cancelled,
                residue: postflight(prepared),
                explanation:
                    "Removal was cancelled; completed artifacts and observed mutations remain in place."
            )
        } catch RemovalAdmissionRefusal.branchClaims {
            return result(
                .refused,
                residue: postflight(prepared),
                explanation:
                    "Branch removal was refused because a fresh worktree claim exists. Claims cannot be overridden."
            )
        } catch RemovalAdmissionRefusal.hardBoundary {
            return result(
                .refused,
                residue: postflight(prepared),
                explanation:
                    "Removal was refused because the target intersects a protected runtime, install, source, or private-state boundary."
            )
        } catch {
            return result(
                .failed,
                residue: postflight(prepared),
                explanation:
                    "Removal stopped at a fresh identity, policy, content, claim, or command gate: \(error)"
            )
        }
    }

    private func validateHardBoundaries(
        _ prepared: PreparedRemoval
    ) throws {
        let candidate = prepared.selection.candidate
        guard candidate.canSelect,
              candidate.hardExclusion == nil,
              candidate.repository.policyCategory == .writable,
              candidate.clone.policyCategory == .writable,
              candidate.clone.sourceSnapshot.blockedReason != .permanentNoTouch,
              candidate.repository.resolvedDefault != nil,
              !configuration.protectedPaths.contains(where: {
                  candidate.target == $0
                    || candidate.target.hasPrefix($0 + "/")
                    || $0.hasPrefix(candidate.target + "/")
                    || candidate.clone.primaryRoot == $0
                    || candidate.clone.primaryRoot
                        .hasPrefix($0 + "/")
                    || $0.hasPrefix(
                        candidate.clone.primaryRoot + "/"
                    )
              }) else {
            throw RemovalAdmissionRefusal.hardBoundary
        }
        if let branch = candidate.branch {
            guard branch.fullRef
                    != candidate.repository.resolvedDefault?
                        .localRef,
                  GitReferenceSyntax.isValidLocalBranchRef(
                    branch.fullRef
                  ) else {
                throw GitSafetyError.unsafeRepository(
                    "default or non-local branch target is excluded"
                )
            }
        }
        if let worktree = candidate.worktree {
            guard worktree.verification == .verified,
                  !worktree.isPrimary,
                  worktree.registrationIdentity != nil,
                  worktree.attachedBranchRef
                    != candidate.repository.resolvedDefault?
                        .localRef else {
                throw GitSafetyError.unsafeRepository(
                    "default or unverified worktree target is excluded"
                )
            }
        }
    }

    private func validateRuntimeEligibility(
        _ candidate: RemovalCandidate
    ) throws {
        #if SHADOW_SYNC_TESTING
        if let check = configuration.git
            .runtimeEligibilityCheck {
            try check(candidate.clone.sourceSnapshot)
            return
        }
        #endif
        let state = try SecureStateDirectory.openExisting(
            configuration.stateLocation
        )
        let authority = RepositoryAuthorityStore(
            state: state
        ).snapshot()
        guard authority.status == .available,
              authority.usableRecords.filter({
                  $0.repositoryID == candidate.repository.id
              }).count == 1 else {
            throw GitSafetyError.unsafeRepository(
                "logical repository authority changed"
            )
        }
        try RepositoryDiscovery
            .validateRemovalRuntimeEligibility(
            candidate.clone.sourceSnapshot,
            repositoryID: candidate.repository.id,
            account: account
        )
    }

    private func validateFreshWorktree(
        _ prepared: PreparedRemoval,
        target: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws {
        let candidate = prepared.selection.candidate
        guard let expected = candidate.worktree,
              target.worktreePath == expected.path,
              RepositoryDirectoryIdentity(
                target.identity.root
              ) == expected.rootIdentity,
              candidate.expectedOID != nil else {
            throw GitSafetyError.unsafeRepository(
                "worktree identity or tip changed"
            )
        }
        let status = try successfulGit(
            Self.localArguments([
                "status", "--porcelain=v1", "-z",
                "--untracked-files=all",
                "--ignored=matching",
            ]),
            handle: target,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        let index = try successfulGit(
            Self.localArguments([
                "ls-files", "--stage", "-v", "-z",
            ]),
            handle: target,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        let filesystemDigest =
            try RemovalContentEvidence
                .filesystemDigest(
                    rootDescriptor:
                        target.worktreeDescriptor,
                    cancellation: cancellation
                )
        guard expected.contentEvidenceDigest != nil,
              expected.contentEvidenceDigest
                == RemovalContentEvidence.make(
                    status: status.stdout,
                    index: index.stdout,
                    filesystemDigest:
                        filesystemDigest
                ) else {
            throw GitSafetyError.unsafeRepository(
                "worktree content or index changed after preview"
            )
        }
        let ref = expected.attachedBranchRef
        if let ref {
            let tip = try requiredOID(
                ref,
                handle: target,
                frozen: frozen,
                admission: admission,
                cancellation: cancellation
            )
            guard tip == candidate.expectedOID else {
                throw GitSafetyError.unsafeRepository(
                    "worktree branch tip changed"
                )
            }
        } else {
            let tip = try requiredOID(
                "HEAD",
                handle: target,
                frozen: frozen,
                admission: admission,
                cancellation: cancellation
            )
            guard tip == candidate.expectedOID else {
                throw GitSafetyError.unsafeRepository(
                    "detached worktree tip changed"
                )
            }
        }
        let worktreeInventory = try freshWorktreeInventory(
            handle: target,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        guard worktreeInventory.registeredPaths
                .contains(expected.path) else {
            throw GitSafetyError.unsafeRepository(
                "worktree registration disappeared"
            )
        }
        if let ref {
            guard worktreeInventory.claims[ref]?
                    .contains(expected.path)
                    == true else {
                throw GitSafetyError.unsafeRepository(
                    "worktree branch backlink changed"
                )
            }
        }
        let currentSession =
            CurrentSessionWorktreeDetector.inspect(
                worktreePath: expected.path,
                account: account
            )
        guard currentSession == .inactive
                || expected.currentSession == true else {
            throw GitSafetyError.unsafeRepository(
                "current-session activity increased after final confirmation"
            )
        }
        let freshAWA = AWAEvidenceReader.read(
            worktreePath: expected.path,
            commonDirectory:
                target.identity.commonDirectoryPath,
            branch: expected.attachedBranchRef,
            location: expected.locationKind,
            account: account,
            capturedNow: Date()
        )
        #if !SHADOW_SYNC_TESTING
        guard freshAWA.state != .unavailable else {
            throw GitSafetyError.unsafeRepository(
                "External workspace-manager evidence is unavailable; worktree removal is disabled."
            )
        }
        #endif
        guard Self.awaRisk(freshAWA.state)
                <= Self.awaRisk(
                    expected.awaEvidence?.state
                        ?? .notManaged
                ) else {
            throw GitSafetyError.unsafeRepository(
                "AWA liveness risk increased after final confirmation"
            )
        }
        try target.rejectBusyState(
            defaultBranch: expected.attachedBranchRef.map {
                String($0.dropFirst("refs/heads/".count))
            } ?? "main"
        )
    }

    private func validateFreshBranch(
        _ prepared: PreparedRemoval,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws {
        let candidate = prepared.selection.candidate
        guard let branch = candidate.branch,
              let expected = branch.tipOID,
              branch.claimingWorktreeIDs.isEmpty,
              branch.fullRef
                != candidate.repository.resolvedDefault?
                    .localRef else {
            if candidate.branch?.claimingWorktreeIDs
                .isEmpty == false {
                throw RemovalAdmissionRefusal.branchClaims
            }
            throw GitSafetyError.unsafeRepository(
                "branch identity or preview claims are incomplete"
            )
        }
        if prepared.artifact == nil,
           !prepared.historyLossAccepted {
            guard try freshHistoryIsPreserved(
                candidate,
                handle: handle,
                frozen: frozen,
                admission: admission,
                cancellation: cancellation
            ) else {
                throw GitSafetyError.unsafeRepository(
                    "branch history preservation sink changed"
                )
            }
        }
        let claims = try freshWorktreeInventory(
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        ).claims
        guard claims[branch.fullRef, default: []].isEmpty else {
            throw RemovalAdmissionRefusal.branchClaims
        }
        let observed = try requiredOID(
            branch.fullRef,
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        guard observed == expected else {
            throw GitSafetyError.unsafeRepository(
                "branch expected-old identity changed"
            )
        }
        let finalClaims = try freshWorktreeInventory(
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        ).claims
        guard finalClaims[
            branch.fullRef,
            default: []
        ].isEmpty else {
            throw RemovalAdmissionRefusal.branchClaims
        }
    }

    private func freshHistoryIsPreserved(
        _ candidate: RemovalCandidate,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws -> Bool {
        guard let expected = candidate.expectedOID else {
            return false
        }
        let relation =
            candidate.branch?.relationToDefault
                ?? candidate.worktree?.relationToDefault
        if relation?.kind == .equal
            || relation?.kind == .behind {
            guard let defaultRef =
                    candidate.repository.resolvedDefault?
                        .localRef else {
                return false
            }
            let defaultOID = try requiredOID(
                defaultRef,
                handle: handle,
                frozen: frozen,
                admission: admission,
                cancellation: cancellation
            )
            let result = try runGit(
                Self.localArguments([
                    "merge-base", "--is-ancestor",
                    expected, defaultOID,
                ]),
                handle: handle,
                validationHandle: handle,
                frozen: frozen,
                admission: admission,
                cancellation: cancellation
            )
            if result.cancelled {
                throw GitSafetyError.cancelled
            }
            if result.status == 0 {
                return true
            }
            if result.status == 1 {
                return false
            }
            throw GitSafetyError.commandFailed(
                "verify branch history sink",
                result.status,
                result.diagnostic
            )
        }
        let attached =
            candidate.worktree?.attachedBranchRef
                .flatMap { reference in
                    candidate.clone.branches.first {
                        $0.fullRef == reference
                    }
                }
        guard let upstream =
                candidate.branch?.upstream
                    ?? attached?.upstream,
              upstream.fullRef.hasPrefix(
                "refs/remotes/origin/"
              ),
              upstream.localOID == expected,
              upstream.upstreamOID == expected else {
            return false
        }
        return try optionalOID(
            upstream.fullRef,
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        ) == expected
    }

    private struct FreshWorktreeInventory {
        let registeredPaths: Set<String>
        let claims: [String: [String]]
    }

    private func freshWorktreeInventory(
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws -> FreshWorktreeInventory {
        let result = try successfulGit(
            Self.localArguments([
                "worktree", "list", "--porcelain", "-z",
            ]),
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        let fields = result.stdout.split(
            separator: 0,
            omittingEmptySubsequences: true
        ).map { String(decoding: $0, as: UTF8.self) }
        var path: String?
        var registeredPaths = Set<String>()
        var claims: [String: [String]] = [:]
        for field in fields {
            if field.hasPrefix("worktree ") {
                path = String(field.dropFirst("worktree ".count))
                guard let path,
                      path.hasPrefix("/"),
                      !path.contains("\n"),
                      !path.contains("\r"),
                      !path.contains("\0"),
                      registeredPaths.insert(path)
                        .inserted else {
                    throw GitSafetyError.unsafeRepository(
                        "worktree registration path is malformed"
                    )
                }
            } else if field.hasPrefix("branch "),
                      let path {
                let ref = String(field.dropFirst("branch ".count))
                guard GitReferenceSyntax.isValidLocalBranchRef(ref) else {
                    throw GitSafetyError.unsafeRepository(
                        "worktree claim ref is malformed"
                    )
                }
                claims[ref, default: []].append(path)
            } else if field.hasPrefix("HEAD ")
                        || field == "detached"
                        || field == "bare"
                        || field == "locked"
                        || field.hasPrefix("locked ")
                        || field == "prunable"
                        || field.hasPrefix("prunable ") {
                continue
            } else {
                throw GitSafetyError.unsafeRepository(
                    "worktree claim inventory is malformed"
                )
            }
        }
        return FreshWorktreeInventory(
            registeredPaths: registeredPaths,
            claims: claims.mapValues { $0.sorted() }
        )
    }

    private func defaultRefSnapshot(
        _ candidate: RemovalCandidate,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws -> [String: String] {
        guard let resolved =
                candidate.repository.resolvedDefault else {
            throw GitSafetyError.unsafeRepository(
                "actual default is unavailable"
            )
        }
        let output = try successfulGit(
            Self.localArguments([
                "for-each-ref",
                "--format=%(refname)%00%(objectname)%00",
                "refs/",
            ]),
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        var fields = output.stdout.split(
            separator: 0,
            omittingEmptySubsequences: false
        ).map {
            String(decoding: $0, as: UTF8.self)
                .trimmingCharacters(in: .newlines)
        }
        while fields.last?.isEmpty == true {
            fields.removeLast()
        }
        guard fields.count.isMultiple(of: 2) else {
            throw GitSafetyError.unsafeRepository(
                "protected ref inventory is malformed"
            )
        }
        var result: [String: String] = [:]
        for index in stride(
            from: 0,
            to: fields.count,
            by: 2
        ) {
            let reference = fields[index]
            let oid = fields[index + 1].lowercased()
            guard RetentionOID.isValid(oid) else {
                throw GitSafetyError.unsafeRepository(
                    "protected ref inventory is malformed"
                )
            }
            if reference == resolved.localRef
                || reference.hasPrefix("refs/remotes/") {
                guard result[reference] == nil else {
                    throw GitSafetyError.unsafeRepository(
                        "protected ref inventory is ambiguous"
                    )
                }
                result[reference] = oid
            }
        }
        return result
    }

    private func protectedWorktreeRefSnapshot(
        _ candidate: RemovalCandidate,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws -> [String: String] {
        var result = try defaultRefSnapshot(
            candidate,
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        if let reference =
                candidate.worktree?.attachedBranchRef {
            result[reference] = try requiredOID(
                reference,
                handle: handle,
                frozen: frozen,
                admission: admission,
                cancellation: cancellation
            )
        }
        return result
    }

    private func requiredOID(
        _ reference: String,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws -> String {
        guard let value = try optionalOID(
            reference,
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        ) else {
            throw GitSafetyError.unsafeRepository(
                "required local ref is unavailable"
            )
        }
        return value
    }

    private func optionalOID(
        _ reference: String,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws -> String? {
        let result = try runGit(
            Self.localArguments([
                "rev-parse", "--verify", "--quiet",
                "\(reference)^{commit}",
            ]),
            handle: handle,
            validationHandle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        if result.status == 1 { return nil }
        guard result.succeeded,
              let value = String(
                data: result.stdout,
                encoding: .utf8
              )?.trimmingCharacters(
                in: .whitespacesAndNewlines
              ),
              RetentionOID.isValid(value) else {
            throw GitSafetyError.unsafeRepository(
                "local ref object ID is malformed"
            )
        }
        return value.lowercased()
    }

    private func validateArtifact(
        _ prepared: PreparedRemoval
    ) throws {
        guard let artifact = prepared.artifact else {
            if prepared.finalClass == .recoveryBacked {
                throw GitSafetyError.unsafeRepository(
                    "recovery-backed row lost its artifact"
                )
            }
            return
        }
        let state = try SecureStateDirectory.openExisting(
            configuration.stateLocation
        )
        let store = RetentionArtifactStore(
            state: state,
            account: account
        )
        guard try store.verify(artifact) else {
            throw GitSafetyError.unsafeRepository(
                "completed recovery artifact changed"
            )
        }
    }

    private func freeze(
        _ handle: RepositoryHandle
    ) throws -> FrozenGitConfiguration {
        #if SHADOW_SYNC_TESTING
        let additional = configuration.git.transportMapping
            .flatMap {
                $0.logicalURL == handle.rawOrigin
                    ? $0.gitConfigText : nil
            }
        #else
        let additional: String? = nil
        #endif
        return try handle.freezeConfiguration(
            account: account,
            additionalConfiguration: additional
        )
    }

    private func validateOrigin(
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        cancellation: CancellationToken
    ) throws -> GitAdmissionSnapshot {
        let first = try effectiveOrigin(
            handle: handle,
            frozen: frozen,
            cancellation: cancellation
        )
        let second = try effectiveOrigin(
            handle: handle,
            frozen: frozen,
            cancellation: cancellation
        )
        guard first == second else {
            throw GitSafetyError.originChanged
        }
        #if SHADOW_SYNC_TESTING
        return GitAdmissionSnapshot(
            effectiveURL: second.0,
            transport: second.1,
            frozenConfigSHA256:
                frozen.snapshot.frozenSHA256,
            mappedTestURL:
                configuration.git.transportMapping?
                    .effectiveURL
        )
        #else
        return GitAdmissionSnapshot(
            effectiveURL: second.0,
            transport: second.1,
            frozenConfigSHA256:
                frozen.snapshot.frozenSHA256
        )
        #endif
    }

    private func effectiveOrigin(
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        cancellation: CancellationToken
    ) throws -> (String, GitTransport) {
        let result = try successfulGit(
            Self.localArguments([
                "remote", "get-url", "--all", "origin",
            ]),
            handle: handle,
            frozen: frozen,
            admission: nil,
            cancellation: cancellation
        )
        let lines = String(
            decoding: result.stdout,
            as: UTF8.self
        ).split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count == 1 else {
            throw GitSafetyError.originChanged
        }
        var identityURL = lines[0]
        #if SHADOW_SYNC_TESTING
        if identityURL
            == configuration.git.transportMapping?
                .effectiveURL {
            identityURL = configuration.git
                .transportMapping!.logicalURL
        }
        #endif
        guard let identity =
                GitHubIdentity.parse(identityURL),
              identity.canonicalName
                == handle.githubIdentity.canonicalName else {
            throw GitSafetyError.originChanged
        }
        return (identityURL, identity.transport)
    }

    private func successfulGit(
        _ arguments: [String],
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot?,
        cancellation: CancellationToken
    ) throws -> ProcessResult {
        let result = try runGit(
            arguments,
            handle: handle,
            validationHandle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        guard result.succeeded,
              !result.stdoutTruncated else {
            if result.cancelled {
                throw GitSafetyError.cancelled
            }
            throw GitSafetyError.commandFailed(
                "Git removal preflight",
                result.status,
                arguments.contains("ls-files")
                    ? result.diagnosticOmittingStdout
                    : result.diagnostic
            )
        }
        return result
    }

    private func reopenAfterBranchDeletion(
        _ source: RepositoryCandidate
    ) throws -> RepositoryHandle {
        let refreshed = RepositoryCandidate(
            id: source.id,
            displayName: source.displayName,
            path: source.path,
            rawOrigin: source.rawOrigin,
            presentationLocation:
                source.presentationLocation,
            rootIdentity: source.rootIdentity,
            gitDirectoryIdentity:
                source.gitDirectoryIdentity,
            commonDirectoryIdentity:
                source.commonDirectoryIdentity,
            configIdentity: nil,
            policyAdmissionSHA256:
                source.policyAdmissionSHA256,
            hookAdmissionSHA256:
                source.hookAdmissionSHA256,
            linkedWorktreePaths:
                source.linkedWorktreePaths,
            linkedWorktrees: source.linkedWorktrees,
            cachedMainRelation:
                source.cachedMainRelation,
            blockedReason: source.blockedReason
        )
        return try RepositoryHandle.open(refreshed)
    }

    private func runGit(
        _ arguments: [String],
        handle: RepositoryHandle,
        validationHandle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot?,
        cancellation: CancellationToken
    ) throws -> ProcessResult {
        try handle.revalidate()
        var admitted = arguments
        #if SHADOW_SYNC_TESTING
        if configuration.git.transportMapping != nil,
           admitted.first != "-c" {
            admitted = [
                "-c", GitCommandPolicy.testRootMarker,
            ] + admitted
        }
        #endif
        let snapshot = try handle.executionSnapshot(
            account: account,
            frozenConfiguration: frozen,
            admission: admission
        )
        let validation = try validationHandle
            .executionSnapshot(
                account: account,
                frozenConfiguration: frozen,
                admission: admission
            )
        let deletedBranch =
            GitCommandPolicy.ordinaryBranchDeletionName(
                arguments,
                expectedWorktreePath:
                    validation.rootPath
            )
        let repositoryConfigurationBefore =
            try deletedBranch.map { _ in
                try RepositoryHandle
                    .captureRepositoryConfiguration(
                        validation
                    )
            }
        let environment = ClosedGitEnvironment.make(
            account: account,
            transport: admission?.transport
                ?? handle.githubIdentity.transport,
            frozenConfigPath: frozen.snapshot.frozenPath
        )
        let result = try runner.run(
            ProcessRequest(
                executable:
                    DescriptorProcessRunner.gitPath,
                arguments: admitted,
                environment: environment,
                workingDirectoryDescriptor:
                    handle.worktreeDescriptor,
                inheritedLeaseDescriptor:
                    configuration.git
                        .operationLeaseDescriptor,
                frozenConfigDescriptor: frozen.descriptor,
                frozenConfigDirectoryDescriptor:
                    frozen.directoryDescriptor,
                timeoutSeconds:
                    configuration.git.localTimeoutSeconds,
                trampolineExecutable:
                    configuration.git.trampolineExecutable,
                executionSnapshot: snapshot
            ),
            cancellation: cancellation
        )
        if let deletedBranch,
           let repositoryConfigurationBefore {
            try RepositoryHandle
                .validateBranchDeletionSnapshot(
                    validation,
                    account: account,
                    branchName: deletedBranch,
                    configurationBefore:
                        repositoryConfigurationBefore,
                    commandSucceeded:
                        result.succeeded
                )
        } else {
            try validationHandle
                .validateExecutionSnapshot(
                    validation,
                    account: account,
                    requirePackedIdentity:
                        !arguments.contains("update-ref")
                            && !arguments
                                .contains("branch")
                )
        }
        return result
    }

    private func worktreeArguments(
        _ prepared: PreparedRemoval,
        commonDirectory: String,
        force: RemovalForceLevel
    ) -> [String] {
        let candidate = prepared.selection.candidate
        return Self.localArguments([
            "--git-dir=\(commonDirectory)",
            "worktree", "remove",
        ] + force.arguments + [candidate.worktree!.path])
    }

    private func postflight(
        _ prepared: PreparedRemoval
    ) -> RemovalResidue {
        let candidate = prepared.selection.candidate
        let artifactIntact: Bool? = prepared.artifact.map {
            artifact in
            guard let state = try?
                    SecureStateDirectory.openExisting(
                        configuration.stateLocation
                    ) else { return false }
            return (try? RetentionArtifactStore(
                state: state,
                account: account
            ).verify(artifact)) == true
        }
        if let worktree = candidate.worktree {
            var pathInfo = stat()
            let pathPresent = lstat(
                worktree.path,
                &pathInfo
            ) == 0
            var registrationPresent: Bool?
            var claims: [String] = []
            if let primary = try? RepositoryHandle.open(
                candidate.clone.sourceSnapshot
            ), let frozen = try? freeze(primary),
            let admission = try? validateOrigin(
                handle: primary,
                frozen: frozen,
                cancellation: CancellationToken()
            ), let observed = try? freshWorktreeInventory(
                handle: primary,
                frozen: frozen,
                admission: admission,
                cancellation: CancellationToken()
            ) {
                claims = observed.claims.compactMap {
                    $0.value.contains(worktree.path)
                        ? $0.key : nil
                }
                registrationPresent =
                    observed.registeredPaths.contains(
                        worktree.path
                    )
            }
            let awaState = AWAEvidenceReader.read(
                worktreePath: worktree.path,
                commonDirectory:
                    candidate.clone.sourceSnapshot.path
                    + "/.git",
                branch: worktree.attachedBranchRef,
                location: worktree.locationKind,
                account: account,
                capturedNow: Date()
            ).state
            let attention = pathPresent
                || registrationPresent != false
                || !claims.isEmpty
                || artifactIntact == false
            return RemovalResidue(
                pathPresent: pathPresent,
                worktreeRegistrationPresent:
                    registrationPresent,
                localRefPresent: nil,
                claims: claims,
                artifactIntact: artifactIntact,
                awaState: awaState,
                needsAttention: attention
            )
        }
        let ref = candidate.branch!.fullRef
        var refPresent: Bool?
        var claims: [String] = []
        var claimsKnown = false
        if let primary = try? RepositoryHandle.open(
            candidate.clone.sourceSnapshot
        ), let frozen = try? freeze(primary),
        let admission = try? validateOrigin(
            handle: primary,
            frozen: frozen,
            cancellation: CancellationToken()
        ) {
            do {
                refPresent = try optionalOID(
                    ref,
                    handle: primary,
                    frozen: frozen,
                    admission: admission,
                    cancellation:
                        CancellationToken()
                ) != nil
                claims = try freshWorktreeInventory(
                    handle: primary,
                    frozen: frozen,
                    admission: admission,
                    cancellation:
                        CancellationToken()
                ).claims[ref] ?? []
                claimsKnown = true
            } catch {
                refPresent = nil
            }
        }
        return RemovalResidue(
            pathPresent: nil,
            worktreeRegistrationPresent: nil,
            localRefPresent: refPresent,
            claims: claims,
            artifactIntact: artifactIntact,
            awaState: nil,
            needsAttention:
                refPresent != false
                    || !claimsKnown
                    || !claims.isEmpty
                    || artifactIntact == false
        )
    }

    private func postflightWorktree(
        _ prepared: PreparedRemoval,
        expectedRefs: [String: String],
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot
    ) -> RemovalResidue {
        let observedRefs = try?
            protectedWorktreeRefSnapshot(
                prepared.selection.candidate,
                handle: handle,
                frozen: frozen,
                admission: admission,
                cancellation: CancellationToken()
            )
        let residue = postflight(prepared)
        guard observedRefs == expectedRefs else {
            return RemovalResidue(
                pathPresent: residue.pathPresent,
                worktreeRegistrationPresent:
                    residue.worktreeRegistrationPresent,
                localRefPresent:
                    residue.localRefPresent,
                claims: residue.claims,
                artifactIntact:
                    residue.artifactIntact,
                awaState: residue.awaState,
                needsAttention: true
            )
        }
        return residue
    }

    private func postflightBranch(
        _ prepared: PreparedRemoval,
        expectedDefaults: [String: String],
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot
    ) -> RemovalResidue {
        let observedDefaults = try? defaultRefSnapshot(
            prepared.selection.candidate,
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: CancellationToken()
        )
        let residue = postflightBranchResidue(
            prepared,
            handle: handle,
            frozen: frozen,
            admission: admission
        )
        guard observedDefaults == expectedDefaults else {
            return RemovalResidue(
                pathPresent: residue.pathPresent,
                worktreeRegistrationPresent:
                    residue.worktreeRegistrationPresent,
                localRefPresent:
                    residue.localRefPresent,
                claims: residue.claims,
                artifactIntact:
                    residue.artifactIntact,
                awaState: residue.awaState,
                needsAttention: true
            )
        }
        return residue
    }

    private func postflightBranchResidue(
        _ prepared: PreparedRemoval,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot
    ) -> RemovalResidue {
        let candidate = prepared.selection.candidate
        let ref = candidate.branch!.fullRef
        var refPresent: Bool?
        var claims: [String] = []
        var claimsKnown = false
        do {
            refPresent = try optionalOID(
                ref,
                handle: handle,
                frozen: frozen,
                admission: admission,
                cancellation: CancellationToken()
            ) != nil
            claims = try freshWorktreeInventory(
                handle: handle,
                frozen: frozen,
                admission: admission,
                cancellation: CancellationToken()
            ).claims[ref] ?? []
            claimsKnown = true
        } catch {
            refPresent = nil
        }
        let artifactIntact = prepared.artifact.map {
            artifact in
            guard let state = try?
                    SecureStateDirectory.openExisting(
                        configuration.stateLocation
                    ) else { return false }
            return (try? RetentionArtifactStore(
                state: state,
                account: account
            ).verify(artifact)) == true
        }
        return RemovalResidue(
            pathPresent: nil,
            worktreeRegistrationPresent: nil,
            localRefPresent: refPresent,
            claims: claims,
            artifactIntact: artifactIntact,
            awaState: nil,
            needsAttention:
                refPresent != false
                    || !claimsKnown
                    || !claims.isEmpty
                    || artifactIntact == false
        )
    }

    private func emptyResidue(
        _ prepared: PreparedRemoval
    ) -> RemovalResidue {
        RemovalResidue(
            pathPresent: nil,
            worktreeRegistrationPresent: nil,
            localRefPresent: nil,
            claims:
                prepared.selection.candidate.dependencies,
            artifactIntact:
                prepared.artifact.map { _ in true },
            awaState:
                prepared.selection.candidate.worktree?
                    .awaEvidence?.state,
            needsAttention: false
        )
    }

    private func completionCopy(
        _ prepared: PreparedRemoval,
        residue: RemovalResidue
    ) -> String {
        let base: String
        switch prepared.finalClass {
        case .recommended:
            base =
                "Removed by explicit operator selection."
        case .recoveryBacked:
            base =
                "Removed by explicit operator selection; the restore-proven recovery artifact remains protected."
        case .operatorOverrideRisk:
            base =
                "Removed by Operator override; this result does not imply AWA approval or complete preservation."
        }
        if let awaState = residue.awaState,
           awaState != .notManaged {
            return base
                + " AWA still reports \(awaState.rawValue) state; that bookkeeping is advisory residue."
        }
        return base
    }

    private static func localArguments(
        _ arguments: [String]
    ) -> [String] {
        [
            "--no-replace-objects",
            "--no-lazy-fetch",
        ] + arguments
    }

    private static func awaRisk(
        _ state: AWAEvidenceState
    ) -> Int {
        switch state {
        case .notManaged: return 0
        case .dead, .stale, .untracked: return 1
        case .unavailable: return 2
        case .active: return 3
        }
    }
}

private enum WorktreeRemovalRefusal {
    case dirty
    case locked
    case other

    init(result: ProcessResult) {
        guard !result.stderrTruncated else {
            self = .other
            return
        }
        let text = String(
            decoding: result.stderr,
            as: UTF8.self
        ).lowercased()
        if text.contains("is locked")
            || text.contains("locked working tree") {
            self = .locked
        } else if text.contains("modified or untracked files")
            || text.contains("contains modified")
            || text.contains("is dirty") {
            self = .dirty
        } else {
            self = .other
        }
    }
}

private enum RetentionOID {
    static func isValid(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy {
                $0.isNumber
                    || ("a"..."f").contains(
                        $0.lowercased()
                    )
            }
    }
}
