import CryptoKit
import Darwin
import Foundation

public final class FastForwardTransactionV2: @unchecked Sendable {
    private let runner: DescriptorProcessRunner
    private let configuration: GitTransactionConfiguration
    private let account: EffectiveAccount

    public init(
        runner: DescriptorProcessRunner,
        configuration: GitTransactionConfiguration,
        account: EffectiveAccount
    ) {
        self.runner = runner
        self.configuration = configuration
        self.account = account
    }

    public func execute(
        operation: PlannedOperation,
        cancellation: CancellationToken,
        phase: @escaping @Sendable (RepositoryPhase) throws -> Void,
        checkpoint: @escaping @Sendable (RepositoryCheckpoint) throws -> Void
            = { _ in }
    ) -> RepositoryResult {
        let candidate = operation.target.canonicalClone.sourceSnapshot
        let branch = operation.target.resolvedDefault
        let startedAt = WallClock.timestamp()
        let started = MonotonicInstant.now()
        var beforeCommit: String?
        var targetCommit: String?
        var fetched = false
        var remoteBefore: String?
        var remoteAfter: String?

        func result(
            _ code: ResultCode,
            updated: Bool = false,
            after: String? = nil,
            explanation: String,
            detail: String? = nil,
            failureReason: FetchFailureReason? = nil
        ) -> RepositoryResult {
            RepositoryResult(
                repository: candidate,
                operationID: operation.id,
                defaultBranch: branch.name,
                code: code,
                fetched: fetched,
                mainUpdated: updated,
                beforeCommit: beforeCommit,
                targetCommit: targetCommit,
                afterCommit: after,
                remoteTrackingBeforeCommit: remoteBefore,
                remoteTrackingAfterCommit: remoteAfter,
                startedAt: startedAt,
                endedAt: WallClock.timestamp(),
                durationMilliseconds:
                    MonotonicInstant.now().milliseconds(since: started),
                explanation: explanation,
                technicalDetail: detail.map(Redactor.sanitize),
                failureReason: failureReason
            )
        }

        if cancellation.isCancelled {
            return result(
                .cancelledPending,
                explanation:
                    "The pending Fast-forward operation was cancelled before it started."
            )
        }

        do {
            try phase(.checking)
            try validateRuntimeEligibility(operation)
            if operation.target.mode == .refOnly {
                return try executeRefOnly(
                    operation: operation,
                    cancellation: cancellation,
                    phase: phase,
                    checkpoint: checkpoint,
                    startedAt: startedAt,
                    setBefore: { beforeCommit = $0 },
                    setTarget: { targetCommit = $0 },
                    markFetched: { fetched = true },
                    setRemoteBefore: { remoteBefore = $0 },
                    setRemoteAfter: { remoteAfter = $0 },
                    result: {
                        code, updated, after, explanation,
                        detail, failureReason in
                        result(
                            code,
                            updated: updated,
                            after: after,
                            explanation: explanation,
                            detail: detail,
                            failureReason: failureReason
                        )
                    }
                )
            }
            guard let expectedWorktree = operation.target.worktree,
                  let expectedLocalOID =
                    operation.target.expectedLocalOID else {
                throw GitSafetyError.unsafeRepository(
                    "checked-out Fast-forward target is incomplete"
                )
            }
            let handle = try RepositoryHandle
                .openOperationWorktree(
                operation.target.canonicalClone,
                targetWorktree: expectedWorktree
            )
            try handle.rejectReplacementAndGraftState()
            try handle.rejectBusyState(defaultBranch: branch.name)
            let frozen = try freezeConfiguration(handle)
            let admission = try validateOriginAndTransport(
                handle: handle,
                frozen: frozen,
                cancellation: cancellation
            )
            let admittedDefault = try resolveRemoteDefault(
                handle: handle,
                frozen: frozen,
                admission: admission,
                cancellation: cancellation
            )
            guard admittedDefault.name == branch.name,
                  admittedDefault.advertisedOID
                    == branch.advertisedOID else {
                throw RemoteDefaultResolutionError.changed
            }
            let preflight = try inspectTarget(
                handle: handle,
                branch: admittedDefault,
                worktree: expectedWorktree,
                frozen: frozen,
                admission: admission,
                cancellation: cancellation
            )
            try preflight.requireMutableTarget(
                expectedLocalOID: expectedLocalOID,
                expectedWorktreeID: expectedWorktree.id
            )
            beforeCommit = preflight.localOID
            try checkpoint(RepositoryCheckpoint(
                repository: candidate,
                startedAt: startedAt,
                beforeCommit: beforeCommit,
                targetCommit: nil,
                fetched: false
            ))
            #if SHADOW_SYNC_TESTING
            configuration.afterPreflight?(candidate)
            #endif

            if cancellation.isCancelled {
                return result(
                    .cancelledNoUpdate,
                    after: beforeCommit,
                    explanation:
                        "Fast-forward was cancelled before the exact default-branch fetch."
                )
            }
            try validateRuntimeEligibility(operation)
            let fetchAdmission = try validateOriginAndTransport(
                handle: handle,
                frozen: frozen,
                cancellation: cancellation
            )
            remoteBefore = try optionalCommit(
                branch.remoteTrackingRef,
                handle: handle,
                frozen: frozen,
                admission: fetchAdmission,
                cancellation: cancellation
            )
            try phase(.fetching)
            let fetch = try runGit(
                arguments: fetchArguments(branch),
                operation: operation,
                handle: handle,
                frozen: frozen,
                admission: fetchAdmission,
                cancellation: cancellation,
                timeout: configuration.fetchTimeoutSeconds
            )
            switch FetchProcessOutcome.resolve(fetch) {
            case .cancelledBeforeCompletion:
                remoteAfter = try? optionalCommit(
                    branch.remoteTrackingRef,
                    handle: handle,
                    frozen: frozen,
                    admission: fetchAdmission,
                    cancellation: CancellationToken()
                )
                return result(
                    .cancelledDuringFetch,
                    after: beforeCommit,
                    explanation:
                        "Fetching stopped; the local default branch was not updated.",
                    detail: fetch.diagnostic
                )
            case .failed:
                remoteAfter = try? optionalCommit(
                    branch.remoteTrackingRef,
                    handle: handle,
                    frozen: frozen,
                    admission: fetchAdmission,
                    cancellation: CancellationToken()
                )
                if missingRemoteBranch(fetch, branch: branch.name) {
                    return result(
                        .skippedRemoteMainMissing,
                        after: beforeCommit,
                        explanation:
                            "The advertised remote default branch disappeared; local state was preserved.",
                        detail: fetch.diagnostic
                    )
                }
                let failure = FetchFailureClassifier.classify(fetch)
                return result(
                    fetchCode(failure),
                    after: beforeCommit,
                    explanation: fetchExplanation(failure),
                    detail: fetch.diagnostic,
                    failureReason: failure
                )
            case .completed:
                break
            }

            targetCommit = try capturedFetchTarget(
                stdout: fetch.stdout,
                truncated: fetch.stdoutTruncated,
                expectedRemoteTrackingRef: branch.remoteTrackingRef
            )
            remoteAfter = try optionalCommit(
                branch.remoteTrackingRef,
                handle: handle,
                frozen: frozen,
                admission: fetchAdmission,
                cancellation: CancellationToken()
            )
            guard remoteAfter == targetCommit,
                  targetCommit == admittedDefault.advertisedOID else {
                return result(
                    .failedInspection,
                    after: beforeCommit,
                    explanation:
                        "The fetched default-branch target changed after inspection; the local branch was not updated."
                )
            }
            fetched = true
            try checkpoint(RepositoryCheckpoint(
                repository: candidate,
                startedAt: startedAt,
                beforeCommit: beforeCommit,
                targetCommit: targetCommit,
                fetched: true
            ))
            #if SHADOW_SYNC_TESTING
            if let targetCommit {
                configuration.afterFetchCapture?(targetCommit, candidate)
            }
            #endif

            if fetch.cancelled || cancellation.isCancelled {
                return result(
                    .cancelledNoUpdate,
                    after: beforeCommit,
                    explanation:
                        "The fetch completed, but Fast-forward was cancelled before the local default branch changed."
                )
            }

            let commonDirectoryLock =
                try handle.acquireCommonDirectoryOperationLock(
                    account: account
                )
            defer { withExtendedLifetime(commonDirectoryLock) {} }
            try handle.revalidate()
            try handle.rejectReplacementAndGraftState()
            try handle.rejectBusyState(defaultBranch: branch.name)
            try validateRuntimeEligibility(operation)
            let lockedAdmission = try validateOriginAndTransport(
                handle: handle,
                frozen: frozen,
                cancellation: cancellation
            )
            let lockedDefault = try resolveRemoteDefault(
                handle: handle,
                frozen: frozen,
                admission: lockedAdmission,
                cancellation: cancellation
            )
            guard lockedDefault.name == branch.name,
                  lockedDefault.advertisedOID == targetCommit else {
                throw RemoteDefaultResolutionError.changed
            }
            let lockedInspection = try inspectTarget(
                handle: handle,
                branch: lockedDefault,
                worktree: expectedWorktree,
                frozen: frozen,
                admission: lockedAdmission,
                cancellation: cancellation
            )
            try lockedInspection.requireMutableTarget(
                expectedLocalOID: expectedLocalOID,
                expectedWorktreeID: expectedWorktree.id
            )
            guard let targetCommit else {
                throw GitSafetyError.unsafeRepository(
                    "fetched target is unavailable"
                )
            }
            let relation = try relation(
                local: lockedInspection.localOID,
                target: targetCommit,
                operation: operation,
                handle: handle,
                frozen: frozen,
                admission: lockedAdmission,
                cancellation: cancellation
            )
            switch relation.kind {
            case .equal:
                try phase(.complete)
                return result(
                    .alreadyCurrent,
                    after: lockedInspection.localOID,
                    explanation:
                        "The checked-out default branch is already current."
                )
            case .ahead:
                return result(
                    .skippedAhead,
                    after: lockedInspection.localOID,
                    explanation:
                        "The local default branch is ahead by \(relation.aheadCount ?? 0) commit(s); Fast-forward made no change."
                )
            case .diverged:
                return result(
                    .skippedDiverged,
                    after: lockedInspection.localOID,
                    explanation:
                        "The local and remote default branches have diverged; manual reconciliation is required."
                )
            case .unavailable:
                return result(
                    .failedInspection,
                    after: lockedInspection.localOID,
                    explanation:
                        "The default-branch relation could not be verified; Fast-forward made no change."
                )
            case .behind:
                break
            }
            if cancellation.isCancelled {
                return result(
                    .cancelledNoUpdate,
                    after: lockedInspection.localOID,
                    explanation:
                        "Fast-forward was cancelled before the local default branch changed."
                )
            }

            let immediate = try inspectTarget(
                handle: handle,
                branch: lockedDefault,
                worktree: expectedWorktree,
                frozen: frozen,
                admission: lockedAdmission,
                cancellation: cancellation
            )
            try immediate.requireMutableTarget(
                expectedLocalOID: expectedLocalOID,
                expectedWorktreeID: expectedWorktree.id
            )
            try phase(.updating)
            let update = try runGit(
                arguments: Self.localArguments([
                    "merge",
                    "--ff-only",
                    "--no-overwrite-ignore",
                    "--no-autostash",
                    targetCommit,
                ]),
                operation: operation,
                handle: handle,
                frozen: frozen,
                admission: lockedAdmission,
                cancellation: cancellation,
                timeout: configuration.localTimeoutSeconds
            )
            let observedAfter = try? requiredCommit(
                branch.localRef,
                operation: operation,
                handle: handle,
                frozen: frozen,
                admission: lockedAdmission,
                cancellation: CancellationToken()
            )
            if update.cancelled {
                if observedAfter == targetCommit {
                    return result(
                        .updatedBeforeCancellation,
                        updated: true,
                        after: observedAfter,
                        explanation:
                            "The default branch reached the fetched target before cancellation completed."
                    )
                }
                if observedAfter == beforeCommit {
                    return result(
                        .cancelledNoUpdate,
                        after: observedAfter,
                        explanation:
                            "Fast-forward was cancelled before the local default branch changed."
                    )
                }
                return result(
                    .needsAttention,
                    after: observedAfter,
                    explanation:
                        "Fast-forward was interrupted and the final default-branch ref needs review.",
                    detail: update.diagnostic
                )
            }
            guard update.succeeded else {
                if observedAfter == beforeCommit {
                    return result(
                        .failedUpdate,
                        after: observedAfter,
                        explanation:
                            "Git or an applicable repository hook refused Fast-forward; the local default branch was preserved.",
                        detail: update.diagnostic
                    )
                }
                if observedAfter == targetCommit {
                    return result(
                        .updatedWithWarning,
                        updated: true,
                        after: observedAfter,
                        explanation:
                            "The default branch advanced, but Git or an applicable post-hook reported a warning.",
                        detail: update.diagnostic
                    )
                }
                return result(
                    .needsAttention,
                    after: observedAfter,
                    explanation:
                        "Git failed after the default-branch ref became ambiguous; review is required.",
                    detail: update.diagnostic
                )
            }

            do {
                try handle.revalidate()
                try validateRuntimeEligibility(operation)
                let verifiedAfter = try requiredCommit(
                    branch.localRef,
                    operation: operation,
                    handle: handle,
                    frozen: frozen,
                    admission: lockedAdmission,
                    cancellation: CancellationToken()
                )
                guard verifiedAfter == targetCommit else {
                    throw GitSafetyError.unsafeRepository(
                        "default branch did not reach the fetched target"
                    )
                }
                let postflight = try inspectTarget(
                    handle: handle,
                    branch: lockedDefault,
                    worktree: expectedWorktree,
                    frozen: frozen,
                    admission: lockedAdmission,
                    cancellation: CancellationToken()
                )
                guard postflight.localOID == targetCommit,
                      postflight.claimingWorktreeIDs
                        == [expectedWorktree.id] else {
                    throw GitSafetyError.unsafeRepository(
                        "default branch postflight changed"
                    )
                }
                if !postflight.clean || postflight.hiddenIndex {
                    return result(
                        .updatedWithWarning,
                        updated: true,
                        after: verifiedAfter,
                        explanation:
                            "The default branch advanced, but an applicable hook left worktree or index residue.",
                        detail:
                            "postflight cleanliness or index visibility changed"
                    )
                }
                try phase(.complete)
                return result(
                    .updated,
                    updated: true,
                    after: verifiedAfter,
                    explanation:
                        "The checked-out default branch was fast-forwarded to the exact fetched target."
                )
            } catch {
                return result(
                    observedAfter == targetCommit
                        ? .updatedWithWarning
                        : .needsAttention,
                    updated: observedAfter == targetCommit,
                    after: observedAfter,
                    explanation: observedAfter == targetCommit
                        ? "The default branch advanced, but postflight verification found operation residue."
                        : "Git completed, but the final default-branch state could not be verified.",
                    detail: String(describing: error)
                )
            }
        } catch let error as GitSafetyError {
            return mapSafetyError(
                error,
                before: beforeCommit,
                result: result
            )
        } catch let error as RemoteDefaultResolutionError {
            return result(
                .failedInspection,
                after: beforeCommit,
                explanation:
                    "The actual remote default branch changed or became unavailable; Fast-forward made no local-branch change.",
                detail: String(describing: error)
            )
        } catch let error as FetchTargetCaptureError {
            return result(
                error.resultCode,
                after: beforeCommit,
                explanation:
                    "Git reported a successful fetch without one exact default-branch target; the local branch was not updated.",
                detail: String(describing: error)
            )
        } catch {
            return result(
                .failedInspection,
                after: beforeCommit,
                explanation:
                    "The Fast-forward target could not be verified safely.",
                detail: String(describing: error)
            )
        }
    }

    private func executeRefOnly(
        operation: PlannedOperation,
        cancellation: CancellationToken,
        phase:
            @escaping @Sendable (RepositoryPhase) throws
            -> Void,
        checkpoint:
            @escaping @Sendable (RepositoryCheckpoint)
            throws -> Void,
        startedAt: String,
        setBefore: (String?) -> Void,
        setTarget: (String?) -> Void,
        markFetched: () -> Void,
        setRemoteBefore: (String?) -> Void,
        setRemoteAfter: (String?) -> Void,
        result: (
            ResultCode, Bool, String?, String, String?,
            FetchFailureReason?
        ) -> RepositoryResult
    ) throws -> RepositoryResult {
        let candidate =
            operation.target.canonicalClone.sourceSnapshot
        let clone = operation.target.canonicalClone
        let branch = operation.target.resolvedDefault
        guard operation.kind == .fastForward,
            operation.target.mode == .refOnly,
            operation.target.worktree == nil,
            let expectedLocalOID =
                operation.target.expectedLocalOID,
            let expectedHookSHA256 =
                operation.target.operationHookSHA256,
            let expectedRegistrationSHA256 =
                operation.target.registrationSetSHA256,
            let expectedPreservationSHA256 =
                operation.target.preservationSHA256,
            let selectedBranch = clone.branches.first(where: {
                $0.fullRef == branch.localRef
            }),
            selectedBranch.tipOID == expectedLocalOID,
            selectedBranch.claimingWorktreeIDs.isEmpty
        else {
            throw GitSafetyError.unsafeRepository(
                "ref-only Fast-forward target is incomplete"
            )
        }
        let handle = try RepositoryHandle.open(candidate)
        try handle.rejectReplacementAndGraftState()
        try handle.rejectBusyState(defaultBranch: branch.name)
        let frozen = try freezeConfiguration(handle)
        guard
            let hooksDirectory =
                frozen.effectiveHooksDirectory
        else {
            throw GitSafetyError.unsafeRepository(
                "ref-only operation-hook location is unavailable"
            )
        }
        let admission = try validateOriginAndTransport(
            handle: handle,
            frozen: frozen,
            cancellation: cancellation
        )
        let admittedDefault = try resolveRemoteDefault(
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        guard admittedDefault.name == branch.name,
            admittedDefault.localRef == branch.localRef,
            admittedDefault.remoteTrackingRef
                == branch.remoteTrackingRef,
            admittedDefault.advertisedOID
                == branch.advertisedOID,
            try optionalCommit(
                branch.localRef,
                handle: handle,
                frozen: frozen,
                admission: admission,
                cancellation: cancellation
            ) == expectedLocalOID,
            OperationHookEvidence.updateRefSHA256(
                hooksDirectory: hooksDirectory,
                account: account
            ) == expectedHookSHA256
        else {
            throw GitSafetyError.unsafeRepository(
                "ref-only Fast-forward identity changed"
            )
        }
        let selectedClaims = try refOnlyClaimSnapshot(
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        try requireCompleteClaims(
            selectedClaims,
            clone: clone,
            targetRef: branch.localRef
        )
        let selectedPreserved =
            try RefOnlyPreservationSnapshot.capture(
                clone: clone,
                account: account,
                cancellation: cancellation
            )
        guard
            selectedPreserved.registrationDigest
                == expectedRegistrationSHA256,
            selectedPreserved.evidenceDigest
                == expectedPreservationSHA256
        else {
            throw GitSafetyError.unsafeRepository(
                "ref-only preservation identity changed"
            )
        }
        setBefore(expectedLocalOID)
        try checkpoint(
            RepositoryCheckpoint(
                repository: candidate,
                startedAt: startedAt,
                beforeCommit: expectedLocalOID,
                targetCommit: nil,
                fetched: false
            ))
        #if SHADOW_SYNC_TESTING
        configuration.afterPreflight?(candidate)
        #endif
        if cancellation.isCancelled {
            return result(
                .cancelledNoUpdate,
                false,
                expectedLocalOID,
                "Ref-only Fast-forward was cancelled before the exact default-branch fetch.",
                nil,
                nil
            )
        }

        try validateRuntimeEligibility(operation)
        let fetchAdmission = try validateOriginAndTransport(
            handle: handle,
            frozen: frozen,
            cancellation: cancellation
        )
        let remoteBefore = try optionalCommit(
            branch.remoteTrackingRef,
            handle: handle,
            frozen: frozen,
            admission: fetchAdmission,
            cancellation: cancellation
        )
        setRemoteBefore(remoteBefore)
        try phase(.fetching)
        let fetch = try runGit(
            arguments: fetchArguments(branch),
            operation: operation,
            handle: handle,
            frozen: frozen,
            admission: fetchAdmission,
            cancellation: cancellation,
            timeout: configuration.fetchTimeoutSeconds
        )
        switch FetchProcessOutcome.resolve(fetch) {
        case .cancelledBeforeCompletion:
            let remote = try? optionalCommit(
                branch.remoteTrackingRef,
                handle: handle,
                frozen: frozen,
                admission: fetchAdmission,
                cancellation: CancellationToken()
            )
            setRemoteAfter(remote ?? nil)
            return result(
                .cancelledDuringFetch,
                false,
                expectedLocalOID,
                "Fetching stopped; the unclaimed local default ref was not updated.",
                fetch.diagnostic,
                nil
            )
        case .failed:
            let remote = try? optionalCommit(
                branch.remoteTrackingRef,
                handle: handle,
                frozen: frozen,
                admission: fetchAdmission,
                cancellation: CancellationToken()
            )
            setRemoteAfter(remote ?? nil)
            if missingRemoteBranch(fetch, branch: branch.name) {
                return result(
                    .skippedRemoteMainMissing,
                    false,
                    expectedLocalOID,
                    "The advertised remote default branch disappeared; the unclaimed local ref was preserved.",
                    fetch.diagnostic,
                    nil
                )
            }
            let failure = FetchFailureClassifier.classify(fetch)
            return result(
                fetchCode(failure),
                false,
                expectedLocalOID,
                fetchExplanation(failure),
                fetch.diagnostic,
                failure
            )
        case .completed:
            break
        }

        let target = try capturedFetchTarget(
            stdout: fetch.stdout,
            truncated: fetch.stdoutTruncated,
            expectedRemoteTrackingRef:
                branch.remoteTrackingRef
        )
        setTarget(target)
        let remoteAfter = try optionalCommit(
            branch.remoteTrackingRef,
            handle: handle,
            frozen: frozen,
            admission: fetchAdmission,
            cancellation: CancellationToken()
        )
        setRemoteAfter(remoteAfter)
        guard target == admittedDefault.advertisedOID,
            remoteAfter == target
        else {
            return result(
                .failedInspection,
                false,
                expectedLocalOID,
                "The fetched default-branch target changed after inspection; the unclaimed local ref was not updated.",
                nil,
                nil
            )
        }
        markFetched()
        try checkpoint(
            RepositoryCheckpoint(
                repository: candidate,
                startedAt: startedAt,
                beforeCommit: expectedLocalOID,
                targetCommit: target,
                fetched: true
            ))
        #if SHADOW_SYNC_TESTING
        configuration.afterFetchCapture?(target, candidate)
        #endif
        if fetch.cancelled || cancellation.isCancelled {
            return result(
                .cancelledNoUpdate,
                false,
                expectedLocalOID,
                "The fetch completed, but Ref-only Fast-forward was cancelled before the local ref changed.",
                nil,
                nil
            )
        }

        let preserved = try RefOnlyPreservationSnapshot.capture(
            clone: clone,
            account: account,
            cancellation: cancellation
        )
        guard preserved == selectedPreserved else {
            throw GitSafetyError.unsafeRepository(
                "ref-only preservation evidence changed before lock"
            )
        }
        let commonDirectoryLock =
            try handle.acquireCommonDirectoryOperationLock(
                account: account
            )
        defer { withExtendedLifetime(commonDirectoryLock) {} }
        try commonDirectoryLock.revalidate()
        try validateRuntimeEligibility(operation)
        try handle.revalidate()
        try handle.rejectReplacementAndGraftState()
        try handle.rejectBusyState(defaultBranch: branch.name)
        let lockedAdmission = try validateOriginAndTransport(
            handle: handle,
            frozen: frozen,
            cancellation: cancellation
        )
        let lockedDefault = try resolveRemoteDefault(
            handle: handle,
            frozen: frozen,
            admission: lockedAdmission,
            cancellation: cancellation
        )
        let lockedClaims = try refOnlyClaimSnapshot(
            handle: handle,
            frozen: frozen,
            admission: lockedAdmission,
            cancellation: cancellation
        )
        try requireCompleteClaims(
            lockedClaims,
            clone: clone,
            targetRef: branch.localRef
        )
        let refsBefore = try refMap(
            handle: handle,
            frozen: frozen,
            admission: lockedAdmission,
            cancellation: cancellation
        )
        let lockedPreserved =
            try RefOnlyPreservationSnapshot.capture(
                clone: clone,
                account: account,
                cancellation: cancellation
            )
        guard lockedDefault.name == admittedDefault.name else {
            throw GitSafetyError.unsafeRepository(
                "ref-only remote default name changed under lock"
            )
        }
        guard
            lockedDefault.advertisedOID
                == admittedDefault.advertisedOID
        else {
            throw GitSafetyError.unsafeRepository(
                "ref-only remote default OID changed under lock"
            )
        }
        guard
            refsBefore[branch.localRef]
                == expectedLocalOID,
            refsBefore[branch.remoteTrackingRef] == target
        else {
            throw GitSafetyError.unsafeRepository(
                "ref-only target refs changed under lock"
            )
        }
        guard lockedClaims == selectedClaims else {
            throw GitSafetyError.unsafeRepository(
                "ref-only claim evidence changed under lock"
            )
        }
        guard lockedPreserved == preserved else {
            throw GitSafetyError.unsafeRepository(
                "ref-only worktree or index evidence changed under lock"
            )
        }
        guard
            OperationHookEvidence.updateRefSHA256(
                hooksDirectory: hooksDirectory,
                account: account
            ) == expectedHookSHA256
        else {
            throw GitSafetyError.unsafeRepository(
                "ref-only operation-hook evidence changed under lock"
            )
        }
        let lockedRelation = try relation(
            local: expectedLocalOID,
            target: target,
            operation: operation,
            handle: handle,
            frozen: frozen,
            admission: lockedAdmission,
            cancellation: cancellation
        )
        switch lockedRelation.kind {
        case .equal:
            try phase(.complete)
            return result(
                .alreadyCurrent,
                false,
                expectedLocalOID,
                "The unclaimed local default ref is already current; no checkout, index, or worktree changed.",
                nil,
                nil
            )
        case .ahead:
            return result(
                .skippedAhead,
                false,
                expectedLocalOID,
                "The unclaimed local default ref is ahead; Ref-only Fast-forward made no change.",
                nil,
                nil
            )
        case .diverged:
            return result(
                .skippedDiverged,
                false,
                expectedLocalOID,
                "The unclaimed local and fetched default refs diverged; manual reconciliation is required.",
                nil,
                nil
            )
        case .unavailable:
            return result(
                .failedInspection,
                false,
                expectedLocalOID,
                "The unclaimed local default-ref relation could not be verified; no change was made.",
                nil,
                nil
            )
        case .behind:
            break
        }
        if cancellation.isCancelled {
            return result(
                .cancelledNoUpdate,
                false,
                expectedLocalOID,
                "Ref-only Fast-forward was cancelled before the expected-old compare-and-swap.",
                nil,
                nil
            )
        }

        #if SHADOW_SYNC_TESTING
        configuration.maintenanceBeforeAction?(
            operation.kind,
            candidate
        )
        #endif
        try commonDirectoryLock.revalidate()
        try phase(.updating)
        try validateRuntimeEligibility(operation)
        try handle.revalidate()
        let actionDefault = try resolveRemoteDefault(
            handle: handle,
            frozen: frozen,
            admission: lockedAdmission,
            cancellation: cancellation
        )
        let actionClaims = try refOnlyClaimSnapshot(
            handle: handle,
            frozen: frozen,
            admission: lockedAdmission,
            cancellation: cancellation
        )
        try requireCompleteClaims(
            actionClaims,
            clone: clone,
            targetRef: branch.localRef
        )
        let actionRefs = try refMap(
            handle: handle,
            frozen: frozen,
            admission: lockedAdmission,
            cancellation: cancellation
        )
        let actionPreserved =
            try RefOnlyPreservationSnapshot.capture(
                clone: clone,
                account: account,
                cancellation: cancellation
            )
        guard actionDefault.name == lockedDefault.name,
            actionDefault.advertisedOID
                == lockedDefault.advertisedOID,
            actionClaims == lockedClaims,
            actionRefs == refsBefore,
            actionPreserved == preserved,
            OperationHookEvidence.updateRefSHA256(
                hooksDirectory: hooksDirectory,
                account: account
            ) == expectedHookSHA256
        else {
            throw GitSafetyError.unsafeRepository(
                "ref-only Fast-forward final evidence changed"
            )
        }
        if cancellation.isCancelled {
            return result(
                .cancelledNoUpdate,
                false,
                expectedLocalOID,
                "Ref-only Fast-forward was cancelled before the expected-old compare-and-swap.",
                nil,
                nil
            )
        }

        let action: ProcessResult?
        let actionError: String?
        do {
            action = try runGit(
                arguments:
                    RepositoryMaintenancePlanner
                    .gitDirectoryArguments(
                        handle: handle,
                        command: [
                            "update-ref",
                            branch.localRef,
                            target,
                            expectedLocalOID,
                        ]
                    ),
                operation: operation,
                handle: handle,
                frozen: frozen,
                admission: lockedAdmission,
                cancellation: cancellation,
                timeout:
                    configuration.localTimeoutSeconds
            )
            actionError = nil
        } catch {
            action = nil
            actionError = Redactor.sanitize(
                String(describing: error)
            )
        }
        #if SHADOW_SYNC_TESTING
        configuration.maintenanceAfterAction?(
            operation.kind,
            candidate
        )
        #endif

        let refsAfter = try? refMap(
            handle: handle,
            frozen: frozen,
            admission: lockedAdmission,
            cancellation: CancellationToken()
        )
        let observed = refsAfter?[branch.localRef]
        var expectedRefs = refsBefore
        expectedRefs[branch.localRef] = target
        let claimsAfter = try? refOnlyClaimSnapshot(
            handle: handle,
            frozen: frozen,
            admission: lockedAdmission,
            cancellation: CancellationToken()
        )
        let preservedAfter =
            try? RefOnlyPreservationSnapshot.capture(
                clone: clone,
                account: account,
                cancellation: CancellationToken()
            )
        let remoteStillTarget =
            (try? optionalCommit(
                branch.remoteTrackingRef,
                handle: handle,
                frozen: frozen,
                admission: lockedAdmission,
                cancellation: CancellationToken()
            )) == target
        let hookStillExact =
            OperationHookEvidence.updateRefSHA256(
                hooksDirectory: hooksDirectory,
                account: account
            ) == expectedHookSHA256
        let lockStillExact =
            (try? commonDirectoryLock.revalidate()) != nil
        let commonPostflight =
            claimsAfter == lockedClaims
            && claimsAfter?.claims[branch.localRef] == nil
            && preservedAfter == preserved
            && remoteStillTarget
            && hookStillExact
            && lockStillExact
        let exactPostflight =
            refsAfter == expectedRefs
            && commonPostflight
        let unchangedPostflight =
            refsAfter == refsBefore
            && commonPostflight
        let detail = [
            action?.diagnostic,
            actionError,
        ].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: "\n")

        if observed == expectedLocalOID {
            guard unchangedPostflight else {
                return result(
                    .needsAttention,
                    false,
                    expectedLocalOID,
                    "The local default ref remains at its expected commit, but postflight found reference-hook or preservation residue; review is required.",
                    detail.isEmpty
                        ? "ref-only postflight evidence changed"
                        : detail,
                    nil
                )
            }
            return result(
                action?.cancelled == true
                    ? .cancelledNoUpdate : .failedUpdate,
                false,
                expectedLocalOID,
                action?.cancelled == true
                    ? "Ref-only Fast-forward was cancelled before the local ref changed."
                    : "Git, the expected-old compare-and-swap, or an applicable reference hook refused Ref-only Fast-forward; the local ref remains unchanged.",
                detail.isEmpty ? nil : detail,
                nil
            )
        }
        if observed == target, exactPostflight {
            try? phase(.complete)
            if action?.cancelled == true {
                return result(
                    .updatedBeforeCancellation,
                    true,
                    target,
                    "The unclaimed local default ref reached the exact fetched target before cancellation. No checkout, index, or worktree changed.",
                    detail.isEmpty ? nil : detail,
                    nil
                )
            }
            guard action?.succeeded == true else {
                return result(
                    .needsAttention,
                    true,
                    target,
                    "The local default ref reached the fetched target, but Git did not confirm the expected-old compare-and-swap; review is required.",
                    detail.isEmpty
                        ? "ref-only compare-and-swap outcome is ambiguous"
                        : detail,
                    nil
                )
            }
            return result(
                .updated,
                true,
                target,
                "The unclaimed local default ref reached the exact fetched target by expected-old compare-and-swap. No checkout, index, or worktree changed.",
                detail.isEmpty ? nil : detail,
                nil
            )
        }
        let updateWasConfirmed =
            action?.succeeded == true && observed == target
        return result(
            updateWasConfirmed
                ? .updatedWithWarning
                : .needsAttention,
            observed == target,
            observed ?? nil,
            updateWasConfirmed
                ? "The local default ref reached the fetched target, but postflight found reference-hook or preservation residue; review is required."
                : "Ref-only Fast-forward ended with an ambiguous ref or postflight state; review is required.",
            detail.isEmpty
                ? "ref-only postflight evidence changed"
                : detail,
            nil
        )
    }

    private struct RefOnlyClaimSnapshot: Equatable {
        let worktreePaths: [String]
        let claims: [String: [String]]
        let digest: String
    }

    private func refOnlyClaimSnapshot(
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws -> RefOnlyClaimSnapshot {
        let output = try runGit(
            arguments: Self.localArguments([
                "worktree", "list", "--porcelain", "-z",
            ]),
            operation: nil,
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation,
            timeout: configuration.localTimeoutSeconds
        )
        guard output.succeeded,
            !output.stdoutTruncated,
            !output.stderrTruncated,
            !output.stdout.isEmpty,
            output.stdout.last == 0
        else {
            throw GitSafetyError.unsafeRepository(
                "ref-only worktree claims are unavailable"
            )
        }

        struct Record {
            var path: String?
            var head: String?
            var branch: String?
            var detached = false
            var bare = false
            var terminalStateCount = 0
        }
        var current: Record?
        var paths: [String] = []
        var claims: [String: [String]] = [:]

        func append(_ record: Record?) throws {
            guard let record,
                let path = record.path,
                path.hasPrefix("/"),
                path.rangeOfCharacter(
                    from: .controlCharacters
                ) == nil,
                !paths.contains(path),
                record.bare
                    || (record.head.map(Self.validOID)
                        == true
                        && record.terminalStateCount == 1)
            else {
                throw GitSafetyError.unsafeRepository(
                    "ref-only worktree claims are malformed"
                )
            }
            paths.append(path)
            if let branch = record.branch {
                guard
                    GitReferenceSyntax
                        .isValidLocalBranchRef(branch),
                    !record.detached,
                    !record.bare
                else {
                    throw GitSafetyError.unsafeRepository(
                        "ref-only worktree claims are malformed"
                    )
                }
                claims[branch, default: []].append(path)
            }
        }

        for raw in output.stdout.split(
            separator: 0,
            omittingEmptySubsequences: false
        ) {
            if raw.isEmpty {
                if current != nil {
                    try append(current)
                    current = nil
                }
                continue
            }
            let field = String(decoding: raw, as: UTF8.self)
            if field.hasPrefix("worktree ") {
                guard current == nil else {
                    throw GitSafetyError.unsafeRepository(
                        "ref-only worktree claims are malformed"
                    )
                }
                current = Record(
                    path: String(
                        field.dropFirst("worktree ".count)
                    )
                )
            } else if field.hasPrefix("HEAD ") {
                guard current != nil,
                    current?.head == nil
                else {
                    throw GitSafetyError.unsafeRepository(
                        "ref-only worktree claims are malformed"
                    )
                }
                current?.head = String(
                    field.dropFirst("HEAD ".count)
                ).lowercased()
            } else if field.hasPrefix("branch ") {
                guard current != nil,
                    current?.branch == nil,
                    current?.terminalStateCount == 0
                else {
                    throw GitSafetyError.unsafeRepository(
                        "ref-only worktree claims are malformed"
                    )
                }
                current?.branch = String(
                    field.dropFirst("branch ".count)
                )
                current?.terminalStateCount += 1
            } else if field == "detached" {
                guard current != nil,
                    current?.terminalStateCount == 0
                else {
                    throw GitSafetyError.unsafeRepository(
                        "ref-only worktree claims are malformed"
                    )
                }
                current?.detached = true
                current?.terminalStateCount += 1
            } else if field == "bare" {
                guard current != nil,
                    current?.terminalStateCount == 0
                else {
                    throw GitSafetyError.unsafeRepository(
                        "ref-only worktree claims are malformed"
                    )
                }
                current?.bare = true
                current?.terminalStateCount += 1
            } else if field == "locked"
                || field.hasPrefix("locked ")
                || field == "prunable"
                || field.hasPrefix("prunable ")
            {
                guard current != nil else {
                    throw GitSafetyError.unsafeRepository(
                        "ref-only worktree claims are malformed"
                    )
                }
            } else {
                throw GitSafetyError.unsafeRepository(
                    "ref-only worktree claims contain an unknown field"
                )
            }
        }
        if current != nil {
            try append(current)
        }
        guard !paths.isEmpty else {
            throw GitSafetyError.unsafeRepository(
                "ref-only worktree claim inventory is empty"
            )
        }
        let normalizedClaims = claims.mapValues {
            $0.sorted()
        }
        let digest = SHA256.hash(data: output.stdout).map {
            String(format: "%02x", $0)
        }.joined()
        return RefOnlyClaimSnapshot(
            worktreePaths: paths.sorted(),
            claims: normalizedClaims,
            digest: digest
        )
    }

    private func requireCompleteClaims(
        _ snapshot: RefOnlyClaimSnapshot,
        clone: LocalClone,
        targetRef: String
    ) throws {
        let expectedPaths = clone.worktrees.map(\.path).sorted()
        var expectedClaims: [String: [String]] = [:]
        for worktree in clone.worktrees {
            guard worktree.verification == .verified,
                worktree.rootIdentity != nil
            else {
                throw GitSafetyError.unsafeRepository(
                    "ref-only worktree inventory is incomplete"
                )
            }
            if let branch = worktree.attachedBranchRef {
                expectedClaims[branch, default: []]
                    .append(worktree.path)
            }
        }
        expectedClaims = expectedClaims.mapValues {
            $0.sorted()
        }
        guard snapshot.worktreePaths == expectedPaths,
            snapshot.claims == expectedClaims,
            snapshot.claims[targetRef] == nil
        else {
            throw GitSafetyError.unsafeRepository(
                "ref-only target gained a worktree claim or claim-list drift"
            )
        }
    }

    private func refMap(
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws -> [String: String] {
        let output = try runGit(
            arguments: Self.localArguments([
                "for-each-ref",
                "--format=%(refname)%00%(objectname)%00",
                "refs/",
            ]),
            operation: nil,
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation,
            timeout: configuration.localTimeoutSeconds
        )
        guard output.succeeded,
            !output.stdoutTruncated,
            !output.stderrTruncated
        else {
            throw GitSafetyError.commandFailed(
                "git for-each-ref",
                output.status,
                output.diagnostic
            )
        }
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
                "ref-only ref inventory is malformed"
            )
        }
        var refs: [String: String] = [:]
        for index in stride(
            from: 0,
            to: fields.count,
            by: 2
        ) {
            let reference = fields[index]
            let oid = fields[index + 1].lowercased()
            guard !reference.isEmpty,
                Self.validOID(oid),
                refs[reference] == nil
            else {
                throw GitSafetyError.unsafeRepository(
                    "ref-only ref inventory is malformed"
                )
            }
            refs[reference] = oid
        }
        return refs
    }

    func freezeConfiguration(
        _ handle: RepositoryHandle
    ) throws -> FrozenGitConfiguration {
        #if SHADOW_SYNC_TESTING
        let additional = configuration.transportMapping.flatMap {
            $0.logicalURL == handle.rawOrigin ? $0.gitConfigText : nil
        }
        #else
        let additional: String? = nil
        #endif
        return try handle.freezeConfiguration(
            account: account,
            additionalConfiguration: additional
        )
    }

    func validateOriginAndTransport(
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        cancellation: CancellationToken
    ) throws -> GitAdmissionSnapshot {
        let first = try effectiveTransport(
            handle: handle,
            frozen: frozen,
            cancellation: cancellation
        )
        let second = try effectiveTransport(
            handle: handle,
            frozen: frozen,
            cancellation: cancellation
        )
        guard first == second else {
            throw GitSafetyError.originChanged
        }
        #if SHADOW_SYNC_TESTING
        return GitAdmissionSnapshot(
            effectiveURL: second.url,
            transport: second.transport,
            frozenConfigSHA256: frozen.snapshot.frozenSHA256,
            mappedTestURL: configuration.transportMapping?.effectiveURL
        )
        #else
        return GitAdmissionSnapshot(
            effectiveURL: second.url,
            transport: second.transport,
            frozenConfigSHA256: frozen.snapshot.frozenSHA256
        )
        #endif
    }

    private func effectiveTransport(
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        cancellation: CancellationToken
    ) throws -> (url: String, transport: GitTransport) {
        let topLevel = try output(
            Self.localArguments(["rev-parse", "--show-toplevel"]),
            operation: nil,
            handle: handle,
            frozen: frozen,
            admission: nil,
            cancellation: cancellation
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard RepositoryRootPathIdentity.matches(
            path: topLevel,
            expected: handle.identity.root
        ) else {
            throw GitSafetyError.unsafeRepository(
                "effective Git top-level does not match the target worktree"
            )
        }
        let effective = try output(
            Self.localArguments(["remote", "get-url", "--all", "origin"]),
            operation: nil,
            handle: handle,
            frozen: frozen,
            admission: nil,
            cancellation: cancellation
        )
        let lines = effective.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count == 1 else {
            throw GitSafetyError.originChanged
        }
        var identityURL = lines[0]
        #if SHADOW_SYNC_TESTING
        if lines[0] == configuration.transportMapping?.effectiveURL {
            identityURL = configuration.transportMapping!.logicalURL
        }
        #endif
        guard let identity = GitHubIdentity.parse(identityURL),
              identity.canonicalName == handle.githubIdentity.canonicalName else {
            throw GitSafetyError.originChanged
        }
        let transportConfig = try runGit(
            arguments: Self.localArguments(
                EffectiveTransportConfiguration.queryArguments
            ),
            operation: nil,
            handle: handle,
            frozen: frozen,
            admission: nil,
            cancellation: cancellation,
            timeout: configuration.localTimeoutSeconds
        )
        try EffectiveTransportConfiguration.validate(
            status: transportConfig.status,
            output: transportConfig.stdout,
            transport: identity.transport,
            operation: "git config effective transport",
            diagnostic: transportConfig.diagnostic
        )
        return (identityURL, identity.transport)
    }

    func resolveRemoteDefault(
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws -> RemoteDefaultBranch {
        let result = try runGit(
            arguments: [
                "--no-replace-objects",
                "ls-remote",
                "--symref",
                "origin",
                "HEAD",
            ],
            operation: nil,
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation,
            timeout: configuration.fetchTimeoutSeconds
        )
        guard result.succeeded, !result.stdoutTruncated else {
            throw RemoteDefaultResolutionError.missing
        }
        return try RemoteDefaultResolver.parse(result.stdout)
    }

    private func inspectTarget(
        handle: RepositoryHandle,
        branch: RemoteDefaultBranch,
        worktree: Worktree,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws -> DefaultBranchTargetInspection {
        try LocalRepositoryInspection.inspectDefaultBranchTarget(
            handle: handle,
            defaultBranch: branch,
            expectedWorktree: worktree
        ) { arguments in
            let process = try runGit(
                arguments: arguments,
                operation: nil,
                handle: handle,
                frozen: frozen,
                admission: admission,
                cancellation: cancellation,
                timeout: configuration.localTimeoutSeconds
            )
            return LocalRepositoryCommandResult(
                status: process.status,
                stdout: process.stdout,
                stdoutTruncated: process.stdoutTruncated,
                stderrTruncated: process.stderrTruncated,
                diagnostic:
                    arguments.contains("ls-files")
                        ? process.diagnosticOmittingStdout
                        : process.diagnostic
            )
        }
    }

    private func relation(
        local: String,
        target: String,
        operation: PlannedOperation,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws -> DefaultBranchRelation {
        let value = try output(
            Self.localArguments([
                "rev-list", "--left-right", "--count",
                "\(local)...\(target)",
            ]),
            operation: operation,
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = value.split { $0.isWhitespace }
        guard fields.count == 2,
              let ahead = Int(fields[0]),
              let behind = Int(fields[1]),
              ahead >= 0,
              behind >= 0 else {
            throw GitSafetyError.unsafeRepository(
                "default branch relation output is malformed"
            )
        }
        let kind: DefaultBranchRelationKind
        if ahead == 0, behind == 0 {
            kind = .equal
        } else if ahead == 0 {
            kind = .behind
        } else if behind == 0 {
            kind = .ahead
        } else {
            kind = .diverged
        }
        return DefaultBranchRelation(
            kind: kind,
            aheadCount: ahead,
            behindCount: behind
        )
    }

    func optionalCommit(
        _ reference: String,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws -> String? {
        let result = try runGit(
            arguments: Self.localArguments([
                "rev-parse", "--verify", "--quiet", "\(reference)^{commit}",
            ]),
            operation: nil,
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation,
            timeout: configuration.localTimeoutSeconds
        )
        if result.status == 1 {
            return nil
        }
        guard result.succeeded,
              !result.stdoutTruncated,
              let oid = Self.objectID(result.stdout) else {
            throw GitSafetyError.commandFailed(
                "git rev-parse",
                result.status,
                result.diagnostic
            )
        }
        return oid
    }

    func requiredCommit(
        _ reference: String,
        operation: PlannedOperation?,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws -> String {
        let value = try output(
            Self.localArguments([
                "rev-parse", "--verify", "\(reference)^{commit}",
            ]),
            operation: operation,
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validOID(value) else {
            throw GitSafetyError.unsafeRepository(
                "default branch object identifier is invalid"
            )
        }
        return value.lowercased()
    }

    private func output(
        _ arguments: [String],
        operation: PlannedOperation?,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot?,
        cancellation: CancellationToken
    ) throws -> String {
        let result = try runGit(
            arguments: arguments,
            operation: operation,
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation,
            timeout: configuration.localTimeoutSeconds
        )
        guard result.succeeded, !result.stdoutTruncated else {
            if result.cancelled {
                throw GitSafetyError.cancelled
            }
            throw GitSafetyError.commandFailed(
                "git \(arguments.dropFirst().first ?? "command")",
                result.status,
                result.diagnostic
            )
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    func runGit(
        arguments: [String],
        operation: PlannedOperation?,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot?,
        cancellation: CancellationToken,
        timeout: TimeInterval,
        postExecutionHandle: RepositoryHandle? = nil
    ) throws -> ProcessResult {
        if let operation {
            try validateRuntimeEligibility(operation)
        }
        try handle.revalidate()
        var admittedArguments = arguments
        #if SHADOW_SYNC_TESTING
        if configuration.transportMapping != nil,
           arguments.first != "-c" {
            admittedArguments = [
                "-c", GitCommandPolicy.testRootMarker,
            ] + arguments
        }
        if arguments.contains("fetch"),
           let mutation =
            configuration.fetchMutationsByRepositoryPath[
                handle.candidate.path
            ] ?? configuration.finalMutationOnFetch {
            admittedArguments.insert(mutation, at: 2)
        }
        if (
            arguments.contains("merge")
                || arguments.contains("update-ref")
        ),
           let mutation = configuration.finalMutationOnUpdate {
            admittedArguments.insert(mutation, at: 2)
        }
        #endif
        let snapshot = try handle.executionSnapshot(
            account: account,
            frozenConfiguration: frozen,
            admission: admission
        )
        let validationHandle = postExecutionHandle ?? handle
        let validationSnapshot: RepositoryExecutionSnapshot
        if postExecutionHandle == nil {
            validationSnapshot = snapshot
        } else {
            try validationHandle.revalidate()
            validationSnapshot = try validationHandle
                .executionSnapshot(
                    account: account,
                    frozenConfiguration: frozen,
                    admission: admission
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
                executable: DescriptorProcessRunner.gitPath,
                arguments: admittedArguments,
                environment: environment,
                workingDirectoryDescriptor: handle.worktreeDescriptor,
                inheritedLeaseDescriptor:
                    configuration.operationLeaseDescriptor,
                frozenConfigDescriptor: frozen.descriptor,
                frozenConfigDirectoryDescriptor: frozen.directoryDescriptor,
                timeoutSeconds: timeout,
                trampolineExecutable: configuration.trampolineExecutable,
                executionSnapshot: snapshot
            ),
            cancellation: cancellation
        )
        try validationHandle.validateExecutionSnapshot(
            validationSnapshot,
            account: account,
            requirePackedIdentity: !arguments.contains("fetch")
        )
        try RepositoryHandle.validateFrozenConfiguration(
            descriptor: frozen.descriptor,
            directoryDescriptor: frozen.directoryDescriptor,
            snapshot: frozen.snapshot
        )
        return result
    }

    func validateRuntimeEligibility(
        _ operation: PlannedOperation
    ) throws {
        #if SHADOW_SYNC_TESTING
        try configuration.runtimeEligibilityCheck?(
            operation.target.canonicalClone.sourceSnapshot
        )
        #else
        try RepositoryDiscovery.validateRuntimeEligibility(
            operation,
            account: account
        )
        #endif
    }

    func fetchArguments(
        _ branch: RemoteDefaultBranch
    ) -> [String] {
        [
            "--no-replace-objects",
            "fetch",
            "--porcelain",
            "--verbose",
            "--no-write-fetch-head",
            "--no-tags",
            "--no-prune",
            "--no-recurse-submodules",
            "--no-auto-maintenance",
            "origin",
            "\(branch.localRef):\(branch.remoteTrackingRef)",
        ]
    }

    func capturedFetchTarget(
        stdout: Data,
        truncated: Bool,
        expectedRemoteTrackingRef: String
    ) throws -> String {
        guard !truncated,
              let text = String(data: stdout, encoding: .utf8) else {
            throw FetchTargetCaptureError.invalidSuccessfulFetchOutput
        }
        var candidates: [String] = []
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            guard let status = line.first,
                  [" ", "*", "="].contains(status) else {
                throw FetchTargetCaptureError.invalidSuccessfulFetchOutput
            }
            let delimiter = line.index(after: line.startIndex)
            guard delimiter < line.endIndex,
                  line[delimiter] == " " else {
                throw FetchTargetCaptureError.invalidSuccessfulFetchOutput
            }
            let payload = line[line.index(after: delimiter)...]
            let fields = payload.split(
                whereSeparator: \.isWhitespace
            ).map(String.init)
            guard fields.count == 3,
                  fields[2] == expectedRemoteTrackingRef,
                  Self.validOID(fields[1]),
                  !fields[1].allSatisfy({ $0 == "0" }) else {
                throw FetchTargetCaptureError.invalidSuccessfulFetchOutput
            }
            candidates.append(fields[1].lowercased())
        }
        guard candidates.count == 1 else {
            throw FetchTargetCaptureError.invalidSuccessfulFetchOutput
        }
        return candidates[0]
    }

    private func missingRemoteBranch(
        _ result: ProcessResult,
        branch: String
    ) -> Bool {
        let detail = result.diagnostic.lowercased()
        return detail.contains(
            "couldn't find remote ref \(branch.lowercased())"
        ) || detail.contains(
            "could not find remote ref \(branch.lowercased())"
        ) || detail.contains(
            "couldn't find remote ref refs/heads/\(branch.lowercased())"
        ) || detail.contains(
            "could not find remote ref refs/heads/\(branch.lowercased())"
        )
    }

    private func mapSafetyError(
        _ error: GitSafetyError,
        before: String?,
        result: (
            ResultCode,
            Bool,
            String?,
            String,
            String?,
            FetchFailureReason?
        ) -> RepositoryResult
    ) -> RepositoryResult {
        let code: ResultCode
        let explanation: String
        switch error {
        case .busy:
            code = .skippedBusy
            explanation =
                "Another Git operation is active for this Fast-forward target."
        case .dirty:
            code = .skippedDirty
            explanation =
                "The checked-out default-branch worktree has local changes; Fast-forward made no branch change."
        case .hiddenIndex:
            code = .skippedHiddenIndexState
            explanation =
                "The checked-out default-branch worktree has hidden index state; Fast-forward made no change."
        case .detached:
            code = .skippedDetachedHead
            explanation =
                "The selected target is no longer attached to the remote default branch."
        case .localMainMissing:
            code = .skippedLocalMainMissing
            explanation =
                "The local default branch is missing. Initialize is planned for Body 2."
        case .repositoryRemoved:
            code = .skippedRepositoryRemoved
            explanation =
                "The canonical clone or target worktree was removed before Fast-forward."
        case .originChanged:
            code = .skippedOriginChanged
            explanation =
                "The repository origin or effective transport changed; Fast-forward made no branch change."
        case .cancelled:
            code = .cancelledNoUpdate
            explanation =
                "Fast-forward was cancelled before a verified local-branch change."
        default:
            code = .failedInspection
            explanation =
                "The Fast-forward target changed or could not be verified safely."
        }
        return result(
            code,
            false,
            before,
            explanation,
            String(describing: error),
            nil
        )
    }

    private func fetchCode(
        _ reason: FetchFailureReason
    ) -> ResultCode {
        switch reason {
        case .authentication:
            return .failedFetchAuthentication
        case .dns, .transport, .timeout:
            return .failedFetchNetwork
        case .other:
            return .failedFetch
        }
    }

    private func fetchExplanation(
        _ reason: FetchFailureReason
    ) -> String {
        switch reason {
        case .authentication:
            return
                "GitHub authentication failed; the local default branch was not updated."
        case .dns:
            return
                "The GitHub host could not be resolved; the local default branch was not updated."
        case .transport:
            return
                "The Git transport failed; the local default branch was not updated."
        case .timeout:
            return
                "The exact default-branch fetch timed out; the local branch was not updated."
        case .other:
            return
                "The exact default-branch fetch failed; the local branch was not updated."
        }
    }

    private static func objectID(_ data: Data) -> String? {
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return validOID(value) ? value : nil
    }

    private static func validOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy {
                $0.isNumber || ("a"..."f").contains($0.lowercased())
            }
    }

    private static func localArguments(_ command: [String]) -> [String] {
        ["--no-replace-objects", "--no-lazy-fetch"] + command
    }
}

struct RefOnlyPreservationSnapshot: Equatable {
    let roots: [String: RepositoryDirectoryIdentity]
    let contentDigests: [String: String]
    let indexes: [String: RefOnlyIndexSnapshot]
    let registrationDigest: String

    var evidenceDigest: String {
        var rows = [registrationDigest]
        for path in roots.keys.sorted() {
            guard let root = roots[path],
                let content = contentDigests[path],
                let index = indexes[path]
            else {
                continue
            }
            let file =
                index.file.map {
                    [
                        String($0.identity.device),
                        String($0.identity.inode),
                        String($0.identity.owner),
                        String($0.identity.mode),
                        String($0.identity.linkCount),
                        String($0.size),
                        String($0.modifiedSeconds),
                        String($0.modifiedNanoseconds),
                    ].joined(separator: ":")
                } ?? "missing"
            rows.append(
                [
                    path,
                    "\(root.device):\(root.inode)",
                    content,
                    file,
                    index.mode.map(String.init) ?? "missing",
                    index.sha256 ?? "missing",
                ].joined(separator: "\u{0}"))
        }
        return V2EvidenceDigest.make(rows)
    }

    static func capture(
        clone: LocalClone,
        account: EffectiveAccount,
        cancellation: CancellationToken
    ) throws -> RefOnlyPreservationSnapshot {
        var roots: [String: RepositoryDirectoryIdentity] = [:]
        var content: [String: String] = [:]
        var indexes: [String: RefOnlyIndexSnapshot] = [:]
        for worktree in clone.worktrees {
            guard !cancellation.isCancelled,
                worktree.verification == .verified,
                let root = worktree.rootIdentity
            else {
                if cancellation.isCancelled {
                    throw GitSafetyError.cancelled
                }
                throw GitSafetyError.unsafeRepository(
                    "ref-only preservation inventory is incomplete"
                )
            }
            let handle = try RepositoryHandle.openOperationWorktree(
                clone,
                targetWorktree: worktree
            )
            roots[worktree.path] = root
            content[worktree.path] =
                try RemovalContentEvidence.filesystemDigest(
                    rootDescriptor:
                        handle.worktreeDescriptor,
                    includeRegularFileContents: true,
                    cancellation: cancellation
                )
            let indexDirectory =
                try handle.duplicateIndexDirectoryDescriptor()
            do {
                defer { Darwin.close(indexDirectory) }
                indexes[worktree.path] =
                    try RefOnlyIndexSnapshot.capture(
                        directory: indexDirectory,
                        account: account
                    )
            }
        }
        return RefOnlyPreservationSnapshot(
            roots: roots,
            contentDigests: content,
            indexes: indexes,
            registrationDigest:
                try RepositoryMaintenancePlanner
                .registrationSetDigest(
                    commonDirectory:
                        clone.primaryRoot + "/.git",
                    account: account
                )
        )
    }
}

struct RefOnlyIndexSnapshot: Equatable {
    let file: RepositoryMetadataFileIdentity?
    let mode: UInt16?
    let sha256: String?

    static func capture(
        directory: Int32,
        account: EffectiveAccount
    ) throws -> RefOnlyIndexSnapshot {
        var pathInfo = stat()
        guard
            fstatat(
                directory,
                "index",
                &pathInfo,
                AT_SYMLINK_NOFOLLOW
            ) == 0
        else {
            if errno == ENOENT {
                return RefOnlyIndexSnapshot(
                    file: nil,
                    mode: nil,
                    sha256: nil
                )
            }
            throw GitSafetyError.unsafeRepository(
                "ref-only index inventory is unavailable"
            )
        }
        guard FileIdentity(pathInfo).isRegular,
            pathInfo.st_uid == account.uid,
            pathInfo.st_nlink == 1,
            (pathInfo.st_mode & 0o022) == 0,
            pathInfo.st_size >= 0,
            pathInfo.st_size <= 67_108_864
        else {
            throw GitSafetyError.unsafeRepository(
                "ref-only index inventory is unsafe"
            )
        }
        let descriptor = openat(
            directory,
            "index",
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw GitSafetyError.unsafeRepository(
                "ref-only index cannot be opened"
            )
        }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
            sameSnapshot(pathInfo, opened)
        else {
            throw GitSafetyError.unsafeRepository(
                "ref-only index changed while opening"
            )
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(
                descriptor,
                &buffer,
                buffer.count
            )
            if count > 0 {
                hasher.update(
                    data: Data(buffer.prefix(count))
                )
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw GitSafetyError.unsafeRepository(
                    "ref-only index cannot be read"
                )
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
            sameSnapshot(pathInfo, after)
        else {
            throw GitSafetyError.unsafeRepository(
                "ref-only index changed while reading"
            )
        }
        return RefOnlyIndexSnapshot(
            file: RepositoryMetadataFileIdentity(pathInfo),
            mode: UInt16(pathInfo.st_mode & 0o7777),
            sha256: hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    private static func sameSnapshot(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_uid == rhs.st_uid
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec
                == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec
                == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec
                == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec
                == rhs.st_ctimespec.tv_nsec
    }
}
