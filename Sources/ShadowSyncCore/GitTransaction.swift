import Darwin
import Foundation

#if SHADOW_SYNC_TESTING
public struct TransportMapping: Codable, Equatable, Sendable {
    public let logicalURL: String
    public let localRepositoryPath: String
    public let containmentRoot: String

    public init(logicalURL: String, localRepositoryPath: String, containmentRoot: String) throws {
        let containmentRoot = try TestIsolation.validateRoot(containmentRoot)
        try TestIsolation.validateContainedDirectory(
            localRepositoryPath,
            root: containmentRoot
        )
        guard GitHubIdentity.parse(logicalURL) != nil,
              !containmentRoot.contains("\n"),
              !localRepositoryPath.contains("\n") else {
            throw GitSafetyError.unsafeRepository("transport mapping is not contained")
        }
        self.logicalURL = logicalURL
        self.localRepositoryPath = localRepositoryPath
        self.containmentRoot = containmentRoot
    }

    var gitConfigText: String {
        let localURL = effectiveURL
        let escapedLocal = localURL
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedLogical = logicalURL
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "[url \"\(escapedLocal)\"]\n\tinsteadOf = \"\(escapedLogical)\"\n"
    }

    var effectiveURL: String {
        URL(fileURLWithPath: localRepositoryPath, isDirectory: true).absoluteString
    }

    private enum CodingKeys: String, CodingKey {
        case logicalURL
        case localRepositoryPath
        case containmentRoot
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            logicalURL: values.decode(String.self, forKey: .logicalURL),
            localRepositoryPath: values.decode(String.self, forKey: .localRepositoryPath),
            containmentRoot: values.decode(String.self, forKey: .containmentRoot)
        )
    }
}
#endif

public struct GitTransactionConfiguration: Sendable {
    var commandContext: CommandCustodyContext? = nil
    public let trampolineExecutable: String?
    public let operationLeaseDescriptor: Int32?
    #if SHADOW_SYNC_TESTING
    public let transportMapping: TransportMapping?
    public let afterPreflight: (@Sendable (RepositoryCandidate) -> Void)?
    public let afterFetchCapture: (@Sendable (String, RepositoryCandidate) -> Void)?
    public let finalMutationOnFetch: String?
    public let finalMutationOnUpdate: String?
    public let fetchMutationsByRepositoryPath: [String: String]
    public let runtimeEligibilityCheck: (@Sendable (RepositoryCandidate) throws -> Void)?
    public let maintenanceBeforeAction:
        (@Sendable (PlannedOperationKind, RepositoryCandidate) -> Void)?
    public let maintenanceAfterAction:
        (@Sendable (PlannedOperationKind, RepositoryCandidate) -> Void)?
    #endif
    public let localTimeoutSeconds: TimeInterval
    public let fetchTimeoutSeconds: TimeInterval

    public init(
        trampolineExecutable: String?,
        operationLeaseDescriptor: Int32?,
        localTimeoutSeconds: TimeInterval = 5,
        fetchTimeoutSeconds: TimeInterval = 120
    ) {
        self.trampolineExecutable = trampolineExecutable
        self.operationLeaseDescriptor = operationLeaseDescriptor
        self.localTimeoutSeconds = localTimeoutSeconds
        self.fetchTimeoutSeconds = fetchTimeoutSeconds
        #if SHADOW_SYNC_TESTING
        transportMapping = nil
        afterPreflight = nil
        afterFetchCapture = nil
        finalMutationOnFetch = nil
        finalMutationOnUpdate = nil
        fetchMutationsByRepositoryPath = [:]
        runtimeEligibilityCheck = nil
        maintenanceBeforeAction = nil
        maintenanceAfterAction = nil
        #endif
    }

    #if SHADOW_SYNC_TESTING
    public init(
        trampolineExecutable: String?,
        operationLeaseDescriptor: Int32?,
        transportMapping: TransportMapping,
        afterPreflight: (@Sendable (RepositoryCandidate) -> Void)? = nil,
        afterFetchCapture: (@Sendable (String, RepositoryCandidate) -> Void)? = nil,
        finalMutationOnFetch: String? = nil,
        finalMutationOnUpdate: String? = nil,
        fetchMutationsByRepositoryPath: [String: String] = [:],
        runtimeEligibilityCheck: (@Sendable (RepositoryCandidate) throws -> Void)? = nil,
        maintenanceBeforeAction:
            (@Sendable (PlannedOperationKind, RepositoryCandidate) -> Void)? = nil,
        maintenanceAfterAction:
            (@Sendable (PlannedOperationKind, RepositoryCandidate) -> Void)? = nil,
        localTimeoutSeconds: TimeInterval = 5,
        fetchTimeoutSeconds: TimeInterval = 120
    ) {
        self.trampolineExecutable = trampolineExecutable
        self.operationLeaseDescriptor = operationLeaseDescriptor
        self.transportMapping = transportMapping
        self.afterPreflight = afterPreflight
        self.afterFetchCapture = afterFetchCapture
        self.finalMutationOnFetch = finalMutationOnFetch
        self.finalMutationOnUpdate = finalMutationOnUpdate
        self.fetchMutationsByRepositoryPath = fetchMutationsByRepositoryPath
        self.runtimeEligibilityCheck = runtimeEligibilityCheck
        self.maintenanceBeforeAction = maintenanceBeforeAction
        self.maintenanceAfterAction = maintenanceAfterAction
        self.localTimeoutSeconds = localTimeoutSeconds
        self.fetchTimeoutSeconds = fetchTimeoutSeconds
    }
    #endif
}

enum GitIndexVisibility {
    static func validate(_ output: Data) throws {
        for record in output.split(separator: 0) {
            guard record.count >= 3 else {
                throw GitSafetyError.hiddenIndex
            }
            let separator = record.index(after: record.startIndex)
            guard record.first == Character("H").asciiValue,
                  record[separator] == Character(" ").asciiValue else {
                throw GitSafetyError.hiddenIndex
            }
        }
    }
}

enum FetchTargetCaptureError: Error, CustomStringConvertible {
    case invalidSuccessfulFetchOutput

    var resultCode: ResultCode {
        .failedInspection
    }

    var description: String {
        "fetch did not return exactly one valid captured target"
    }
}

enum FetchProcessOutcome: Equatable {
    case completed
    case cancelledBeforeCompletion
    case failed

    static func resolve(_ result: ProcessResult) -> FetchProcessOutcome {
        if result.exitedSuccessfully {
            return .completed
        }
        if result.cancelled, result.terminationRequested {
            return .cancelledBeforeCompletion
        }
        return .failed
    }
}

enum FetchFailureClassifier {
    static func classify(_ result: ProcessResult) -> FetchFailureReason {
        if result.timedOut {
            return .timeout
        }
        let detail = result.diagnostic.lowercased()
        if detail.contains("authentication")
            || detail.contains("permission denied")
            || detail.contains("could not read username") {
            return .authentication
        }
        if detail.contains("could not resolve host")
            || detail.contains("name or service not known") {
            return .dns
        }
        if detail.contains("operation timed out")
            || detail.contains("connection timed out")
            || detail.contains("connection timeout")
            || detail.contains("request timed out") {
            return .timeout
        }
        if detail.contains("connection refused")
            || detail.contains("connection reset")
            || detail.contains("network is unreachable") {
            return .transport
        }
        return .other
    }
}

public final class GitTransaction: @unchecked Sendable {
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
        candidate: RepositoryCandidate,
        cancellation: CancellationToken,
        phase: @escaping @Sendable (RepositoryPhase) throws -> Void,
        checkpoint: @escaping @Sendable (RepositoryCheckpoint) throws -> Void = { _ in }
    ) -> RepositoryResult {
        let startedAt = WallClock.timestamp()
        let started = MonotonicInstant.now()
        var beforeCommit: String?
        var targetCommit: String?
        var fetched = false
        var remoteTrackingBeforeCommit: String?
        var remoteTrackingAfterCommit: String?

        func result(
            _ code: ResultCode,
            updated: Bool = false,
            after: String? = nil,
            explanation: String,
            detail: String? = nil,
            failureReason: FetchFailureReason? = nil
        ) -> RepositoryResult {
            let pending = configuration.commandContext?.hasCleanupPending == true
            return RepositoryResult(
                repository: candidate,
                code: pending ? .cleanupPending : code,
                fetched: fetched,
                mainUpdated: updated,
                beforeCommit: beforeCommit,
                targetCommit: targetCommit,
                afterCommit: after,
                remoteTrackingBeforeCommit: remoteTrackingBeforeCommit,
                remoteTrackingAfterCommit: remoteTrackingAfterCommit,
                startedAt: startedAt,
                endedAt: WallClock.timestamp(),
                durationMilliseconds: MonotonicInstant.now().milliseconds(since: started),
                explanation: pending ? "Cleanup is still pending. Further repository work is blocked." : explanation,
                technicalDetail: detail.map(Redactor.sanitize),
                failureReason: failureReason
            )
        }

        if cancellation.isCancelled {
            return result(
                .cancelledPending,
                explanation: "The pending repository was cancelled before it started."
            )
        }

        do {
            try phase(.checking)
            try validateRuntimeEligibility(candidate)
            let handle = try RepositoryHandle.open(candidate)
            try handle.rejectReplacementAndGraftState()
            try handle.rejectBusyState()
            #if SHADOW_SYNC_TESTING
            let additionalConfiguration = configuration.transportMapping.flatMap {
                $0.logicalURL == handle.rawOrigin ? $0.gitConfigText : nil
            }
            #else
            let additionalConfiguration: String? = nil
            #endif
            let frozenConfiguration: FrozenGitConfiguration
            if let context = configuration.commandContext {
                frozenConfiguration = try handle.freezeConfiguration(account: account,
                    retainedConfigurationProbe: SystemGitConfigurationProbe(context: context, cancellation: cancellation),
                    additionalConfiguration: additionalConfiguration)
            } else {
                frozenConfiguration = try handle.freezeConfiguration(account: account,
                    additionalConfiguration: additionalConfiguration)
            }
            _ = try validateOriginAndTransport(
                handle: handle,
                frozenConfiguration: frozenConfiguration,
                cancellation: cancellation
            )
            let localInspection = try inspectLocalRepository(
                handle: handle,
                frozenConfiguration: frozenConfiguration,
                cancellation: cancellation
            )
            try localInspection.requireEligible()
            beforeCommit = localInspection.localMainCommit
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
                return mapPreflightError(
                    .cancelled,
                    result: result,
                    beforeCommit: beforeCommit,
                    fetched: fetched
                )
            }

            try validateRuntimeEligibility(candidate)
            let fetchAdmission = try validateOriginAndTransport(
                handle: handle,
                frozenConfiguration: frozenConfiguration,
                cancellation: cancellation
            )
            remoteTrackingBeforeCommit = try optionalCommit(
                "refs/remotes/origin/main",
                handle: handle,
                frozenConfiguration: frozenConfiguration,
                cancellation: cancellation
            )
            try phase(.fetching)
            let fetch = try runGit(
                arguments: fetchArguments(handle: handle),
                handle: handle,
                cancellation: cancellation,
                timeout: configuration.fetchTimeoutSeconds,
                admission: fetchAdmission,
                frozenConfiguration: frozenConfiguration
            )
            switch FetchProcessOutcome.resolve(fetch) {
            case .cancelledBeforeCompletion:
                remoteTrackingAfterCommit = try? optionalCommit(
                    "refs/remotes/origin/main",
                    handle: handle,
                    frozenConfiguration: frozenConfiguration,
                    cancellation: CancellationToken()
                )
                return result(
                    .cancelledDuringFetch,
                    explanation: "Fetching stopped; local main was not updated.",
                    detail: fetch.diagnostic
                )
            case .failed:
                remoteTrackingAfterCommit = try? optionalCommit(
                    "refs/remotes/origin/main",
                    handle: handle,
                    frozenConfiguration: frozenConfiguration,
                    cancellation: CancellationToken()
                )
                if isMissingRemoteMain(fetch) {
                    return result(
                        .skippedRemoteMainMissing,
                        explanation: "Remote main is missing; local main was preserved.",
                        detail: fetch.diagnostic
                    )
                }
                let reason = FetchFailureClassifier.classify(fetch)
                return result(
                    fetchCode(reason),
                    explanation: fetchExplanation(reason),
                    detail: fetch.diagnostic,
                    failureReason: reason
                )
            case .completed:
                break
            }
            do {
                targetCommit = try capturedFetchTarget(
                    stdout: fetch.stdout,
                    truncated: fetch.stdoutTruncated
                )
                remoteTrackingAfterCommit = try optionalCommit(
                    "refs/remotes/origin/main",
                    handle: handle,
                    frozenConfiguration: frozenConfiguration,
                    cancellation: CancellationToken()
                )
                guard remoteTrackingAfterCommit == targetCommit else {
                    throw FetchTargetCaptureError.invalidSuccessfulFetchOutput
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
            } catch let error as FetchTargetCaptureError {
                return result(
                    error.resultCode,
                    explanation: "Git reported a successful fetch without exactly one valid origin/main target; local main was not updated.",
                    detail: String(describing: error)
                )
            }
            if fetch.cancelled || cancellation.isCancelled {
                return result(
                    .cancelledNoUpdate,
                    after: beforeCommit,
                    explanation: "Fetch completed, but the run was cancelled before local main changed."
                )
            }

            try handle.revalidate()
            try handle.rejectReplacementAndGraftState()
            try handle.rejectBusyState()
            try validateRuntimeEligibility(candidate)
            let updateAdmission = try validateOriginAndTransport(
                handle: handle,
                frozenConfiguration: frozenConfiguration,
                cancellation: cancellation
            )
            let postfetchInspection = try inspectLocalRepository(
                handle: handle,
                frozenConfiguration: frozenConfiguration,
                cancellation: cancellation
            )
            guard let current = postfetchInspection.localMainCommit else {
                throw GitSafetyError.localMainMissing
            }
            guard current == beforeCommit else {
                return result(
                    .failedInspection,
                    after: current,
                    explanation: "Local main changed during inspection; no update was attempted."
                )
            }
            try postfetchInspection.requireEligible()
            guard let targetCommit else {
                return result(.failedInspection, explanation: "The fetched target could not be frozen.")
            }

            if current == targetCommit {
                try phase(.complete)
                return result(
                    .alreadyCurrent,
                    after: current,
                    explanation: "Local main is already current."
                )
            }

            if try isAncestor(current, of: targetCommit, handle: handle, frozenConfiguration: frozenConfiguration, cancellation: cancellation) {
                if cancellation.isCancelled {
                    return result(.cancelledNoUpdate, after: current, explanation: "The update was cancelled before local main changed.")
                }
                try phase(.updating)
                let update = try runGit(
                    arguments: [
                        "--no-replace-objects",
                        "--no-lazy-fetch",
                        "merge",
                        "--ff-only",
                        "--no-overwrite-ignore",
                        "--no-autostash",
                        targetCommit,
                    ],
                    handle: handle,
                    cancellation: cancellation,
                    timeout: configuration.localTimeoutSeconds,
                    admission: updateAdmission,
                    frozenConfiguration: frozenConfiguration
                )
                let observedAfter = try? commit(
                    "refs/heads/main",
                    handle: handle,
                    frozenConfiguration: frozenConfiguration,
                    cancellation: CancellationToken()
                )
                if update.cancelled {
                    if observedAfter == targetCommit {
                        return result(
                            .updatedBeforeCancellation,
                            updated: true,
                            after: observedAfter,
                            explanation: "Local main reached the fetched commit before cancellation."
                        )
                    }
                    if observedAfter == current {
                        return result(
                            .cancelledNoUpdate,
                            after: observedAfter,
                            explanation: "The update was cancelled before local main changed."
                        )
                    }
                    return result(
                        .needsAttention,
                        after: observedAfter,
                        explanation: "The update was interrupted and the final ref state needs review.",
                        detail: update.diagnostic
                    )
                }
                guard update.succeeded else {
                    let detail = update.diagnostic
                    if observedAfter == current {
                        let code: ResultCode = detail.localizedCaseInsensitiveContains("would be overwritten")
                            ? .skippedIgnoredFileCollision
                            : .failedUpdate
                        return result(
                            code,
                            after: observedAfter,
                            explanation: "Git refused the fast-forward; existing files were preserved.",
                            detail: detail
                        )
                    }
                    if observedAfter == targetCommit {
                        return result(
                            .updatedWithWarning,
                            updated: true,
                            after: observedAfter,
                            explanation: "Local main advanced, but Git reported a warning.",
                            detail: detail
                        )
                    }
                    return result(
                        .needsAttention,
                        after: observedAfter,
                        explanation: "Git failed and the final ref state needs review.",
                        detail: detail
                    )
                }
                let verifiedAfter: String
                do {
                    try handle.revalidate()
                    try validateRuntimeEligibility(candidate)
                    verifiedAfter = try commit(
                        "refs/heads/main",
                        handle: handle,
                        frozenConfiguration: frozenConfiguration,
                        cancellation: CancellationToken()
                    )
                } catch {
                    return result(
                        .needsAttention,
                        updated: observedAfter == targetCommit,
                        after: observedAfter,
                        explanation: "Git completed, but the repository identity or final ref could not be verified.",
                        detail: String(describing: error)
                    )
                }
                guard verifiedAfter == targetCommit else {
                    return result(
                        .needsAttention,
                        after: verifiedAfter,
                        explanation: "Git returned success but local main did not match the captured target."
                    )
                }
                do {
                    let postflight = try inspectLocalRepository(
                        handle: handle,
                        frozenConfiguration: frozenConfiguration,
                        cancellation: CancellationToken()
                    )
                    try postflight.requireEligible()
                    guard postflight.localMainCommit == verifiedAfter else {
                        throw GitSafetyError.unsafeRepository(
                            "local main changed after update"
                        )
                    }
                } catch {
                    return result(
                        .updatedWithWarning,
                        updated: true,
                        after: verifiedAfter,
                        explanation: "Local main advanced, but the working copy needs review.",
                        detail: String(describing: error)
                    )
                }
                try phase(.complete)
                return result(
                    .updated,
                    updated: true,
                    after: verifiedAfter,
                    explanation: "Local main was fast-forwarded to the captured fetched commit."
                )
            }

            if try isAncestor(targetCommit, of: current, handle: handle, frozenConfiguration: frozenConfiguration, cancellation: cancellation) {
                return result(
                    .skippedAhead,
                    after: current,
                    explanation: "Local main is ahead; no update was made."
                )
            }
            return result(
                .skippedDiverged,
                after: current,
                explanation: "Local and remote main have diverged; no update was made."
            )
        } catch let error as GitSafetyError {
            return mapPreflightError(
                error,
                result: result,
                beforeCommit: beforeCommit,
                fetched: fetched
            )
        } catch {
            return result(
                .failedInspection,
                explanation: "The repository could not be verified safely.",
                detail: String(describing: error)
            )
        }
    }

    private func validateOriginAndTransport(
        handle: RepositoryHandle,
        frozenConfiguration: FrozenGitConfiguration,
        cancellation: CancellationToken
    ) throws -> GitAdmissionSnapshot {
        let first = try readEffectiveTransport(
            handle: handle,
            frozenConfiguration: frozenConfiguration,
            cancellation: cancellation
        )
        let second = try readEffectiveTransport(
            handle: handle,
            frozenConfiguration: frozenConfiguration,
            cancellation: cancellation
        )
        guard first == second else {
            throw GitSafetyError.originChanged
        }
        #if SHADOW_SYNC_TESTING
        return GitAdmissionSnapshot(
            effectiveURL: second.url,
            transport: second.transport,
            frozenConfigSHA256: frozenConfiguration.snapshot.frozenSHA256,
            mappedTestURL: configuration.transportMapping?.effectiveURL
        )
        #else
        return GitAdmissionSnapshot(
            effectiveURL: second.url,
            transport: second.transport,
            frozenConfigSHA256: frozenConfiguration.snapshot.frozenSHA256
        )
        #endif
    }

    private func readEffectiveTransport(
        handle: RepositoryHandle,
        frozenConfiguration: FrozenGitConfiguration,
        cancellation: CancellationToken
    ) throws -> (url: String, transport: GitTransport) {
        try handle.revalidate()
        let topLevel = try output(
            arguments: localArguments(["rev-parse", "--show-toplevel"]),
            handle: handle,
            frozenConfiguration: frozenConfiguration,
            cancellation: cancellation
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard RepositoryRootPathIdentity.matches(
            path: topLevel,
            expected: handle.identity.root
        ) else {
            throw GitSafetyError.unsafeRepository(
                "effective Git top-level does not match the retained primary root"
            )
        }
        let effective = try output(
            arguments: localArguments(["remote", "get-url", "--all", "origin"]),
            handle: handle,
            frozenConfiguration: frozenConfiguration,
            cancellation: cancellation
        )
        let effectiveLines = effective.split(whereSeparator: \.isNewline).map(String.init)
        guard effectiveLines.count == 1 else {
            throw GitSafetyError.originChanged
        }
        var identityURL = effectiveLines[0]
        #if SHADOW_SYNC_TESTING
        if let mapping = configuration.transportMapping,
           effectiveLines[0] == mapping.effectiveURL {
            identityURL = mapping.logicalURL
        }
        #endif
        let effectiveIdentity = try Self.validatedEffectiveIdentity(
            identityURL,
            rawIdentity: handle.githubIdentity
        )
        let transportConfiguration = try runGit(
            arguments: localArguments(EffectiveTransportConfiguration.queryArguments),
            handle: handle,
            cancellation: cancellation,
            timeout: configuration.localTimeoutSeconds,
            frozenConfiguration: frozenConfiguration
        )
        try EffectiveTransportConfiguration.validate(
            status: transportConfiguration.status,
            output: transportConfiguration.stdout,
            transport: effectiveIdentity.transport,
            operation: "git config effective transport",
            diagnostic: transportConfiguration.diagnostic
        )
        return (identityURL, effectiveIdentity.transport)
    }

    static func validatedEffectiveIdentity(
        _ effectiveURL: String,
        rawIdentity: GitHubIdentity
    ) throws -> GitHubIdentity {
        guard let effectiveIdentity = GitHubIdentity.parse(effectiveURL),
              effectiveIdentity.canonicalName == rawIdentity.canonicalName else {
            throw GitSafetyError.originChanged
        }
        return effectiveIdentity
    }

    private func inspectLocalRepository(
        handle: RepositoryHandle,
        frozenConfiguration: FrozenGitConfiguration,
        cancellation: CancellationToken
    ) throws -> LocalRepositoryInspection {
        try LocalRepositoryInspection.inspect(handle: handle) {
            arguments in
            let result = try runGit(
                arguments: arguments,
                handle: handle,
                cancellation: cancellation,
                timeout: configuration.localTimeoutSeconds,
                frozenConfiguration: frozenConfiguration
            )
            return LocalRepositoryCommandResult(
                status: result.status,
                stdout: result.stdout,
                stdoutTruncated: result.stdoutTruncated,
                stderrTruncated: result.stderrTruncated,
                diagnostic: result.diagnostic
            )
        }
    }

    private func commit(
        _ reference: String,
        handle: RepositoryHandle,
        frozenConfiguration: FrozenGitConfiguration,
        cancellation: CancellationToken
    ) throws -> String {
        let value = try output(
            arguments: localArguments(["rev-parse", "--verify", "\(reference)^{commit}"]),
            handle: handle,
            frozenConfiguration: frozenConfiguration,
            cancellation: cancellation
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = value.count == 40 || value.count == 64
        guard valid, value.allSatisfy(\.isHexDigit) else {
            throw GitSafetyError.commandFailed("git rev-parse", 1, "invalid object identifier")
        }
        return value
    }

    private func optionalCommit(
        _ reference: String,
        handle: RepositoryHandle,
        frozenConfiguration: FrozenGitConfiguration,
        cancellation: CancellationToken
    ) throws -> String? {
        let result = try runGit(
            arguments: localArguments([
                "rev-parse", "--verify", "--quiet", "\(reference)^{commit}",
            ]),
            handle: handle,
            cancellation: cancellation,
            timeout: configuration.localTimeoutSeconds,
            frozenConfiguration: frozenConfiguration
        )
        if result.status == 1 {
            return nil
        }
        guard result.succeeded, !result.stdoutTruncated else {
            throw GitSafetyError.commandFailed(
                "git rev-parse",
                result.status,
                result.diagnostic
            )
        }
        let value = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard (value.count == 40 || value.count == 64),
              value.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) }) else {
            throw GitSafetyError.commandFailed(
                "git rev-parse",
                1,
                "invalid object identifier"
            )
        }
        return value
    }

    private func isAncestor(
        _ ancestor: String,
        of descendant: String,
        handle: RepositoryHandle,
        frozenConfiguration: FrozenGitConfiguration,
        cancellation: CancellationToken
    ) throws -> Bool {
        let result = try runGit(
            arguments: localArguments([
                "merge-base",
                "--is-ancestor",
                ancestor,
                descendant,
            ]),
            handle: handle,
            cancellation: cancellation,
            timeout: configuration.localTimeoutSeconds,
            frozenConfiguration: frozenConfiguration
        )
        if result.status == 0 {
            return true
        }
        if result.status == 1 {
            return false
        }
        throw GitSafetyError.commandFailed(
            "git merge-base",
            result.status,
            result.diagnostic
        )
    }

    private func output(
        arguments: [String],
        handle: RepositoryHandle,
        frozenConfiguration: FrozenGitConfiguration,
        cancellation: CancellationToken
    ) throws -> String {
        let result = try runGit(
            arguments: arguments,
            handle: handle,
            cancellation: cancellation,
            timeout: configuration.localTimeoutSeconds,
            frozenConfiguration: frozenConfiguration
        )
        guard result.succeeded else {
            if result.cancelled {
                throw GitSafetyError.cancelled
            }
            throw GitSafetyError.commandFailed(
                "git \(arguments.dropFirst().first ?? "command")",
                result.status,
                result.diagnostic
            )
        }
        guard !result.stdoutTruncated else {
            throw GitSafetyError.unsafeRepository("Git machine output was truncated")
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    private func fetchArguments(handle: RepositoryHandle) -> [String] {
        return [
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
            "refs/heads/main:refs/remotes/origin/main",
        ]
    }

    private func runGit(
        arguments: [String],
        handle: RepositoryHandle,
        cancellation: CancellationToken,
        timeout: TimeInterval,
        admission: GitAdmissionSnapshot? = nil,
        frozenConfiguration: FrozenGitConfiguration
    ) throws -> ProcessResult {
        try validateRuntimeEligibility(handle.candidate)
        try handle.revalidate()
        var admittedArguments = arguments
        #if SHADOW_SYNC_TESTING
        if configuration.transportMapping != nil,
           arguments.first != "-c" {
            admittedArguments = ["-c", GitCommandPolicy.testRootMarker] + arguments
        }
        if arguments.contains("fetch"),
           let mutation = configuration.fetchMutationsByRepositoryPath[handle.candidate.path]
                ?? configuration.finalMutationOnFetch {
            admittedArguments.insert(mutation, at: 2)
        }
        if arguments.contains("merge"), let mutation = configuration.finalMutationOnUpdate {
            admittedArguments.insert(mutation, at: 2)
        }
        #endif
        let environment = ClosedGitEnvironment.make(
            account: account,
            transport: admission?.transport ?? handle.githubIdentity.transport,
            frozenConfigPath: frozenConfiguration.snapshot.frozenPath
        )
        let snapshot = try handle.executionSnapshot(
            account: account,
            frozenConfiguration: frozenConfiguration,
            admission: admission
        )
        let request = ProcessRequest(
            executable: DescriptorProcessRunner.gitPath,
            arguments: admittedArguments,
            environment: environment,
            workingDirectoryDescriptor: handle.worktreeDescriptor,
            inheritedLeaseDescriptor: configuration.operationLeaseDescriptor,
            frozenConfigDescriptor: frozenConfiguration.descriptor,
            frozenConfigDirectoryDescriptor: frozenConfiguration.directoryDescriptor,
            timeoutSeconds: timeout,
            trampolineExecutable: configuration.trampolineExecutable,
            executionSnapshot: snapshot
        )
        let result: ProcessResult
        if let context = configuration.commandContext {
            result = try runner.runRepository(arguments: admittedArguments, context: context, handle: handle,
                frozen: frozenConfiguration, snapshot: snapshot, timeout: timeout, cancellation: cancellation)
        } else { result = try runner.run(request, cancellation: cancellation) }
        let mayChangePackedRefs = admittedArguments.contains("fetch")
            || admittedArguments.contains("merge")
        try handle.validateExecutionSnapshot(
            snapshot,
            account: account,
            requirePackedIdentity: !mayChangePackedRefs,
            frozenConfiguration: frozenConfiguration
        )
        try RepositoryHandle.validateFrozenConfiguration(
            descriptor: frozenConfiguration.descriptor,
            directoryDescriptor: frozenConfiguration.directoryDescriptor,
            snapshot: frozenConfiguration.snapshot
        )
        return result
    }

    private func localArguments(_ command: [String]) -> [String] {
        ["--no-replace-objects", "--no-lazy-fetch"] + command
    }

    func capturedFetchTarget(stdout: Data, truncated: Bool) throws -> String {
        guard !truncated, let text = String(data: stdout, encoding: .utf8) else {
            throw FetchTargetCaptureError.invalidSuccessfulFetchOutput
        }
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        var candidates: [String] = []
        for line in lines {
            guard let status = line.first,
                  [" ", "*", "="].contains(status) else {
                throw FetchTargetCaptureError.invalidSuccessfulFetchOutput
            }
            let delimiter = line.index(after: line.startIndex)
            guard delimiter < line.endIndex, line[delimiter] == " " else {
                throw FetchTargetCaptureError.invalidSuccessfulFetchOutput
            }
            let payload = line[line.index(after: delimiter)...]
            let fields = payload.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 3,
                  fields[2] == "refs/remotes/origin/main" else {
                throw FetchTargetCaptureError.invalidSuccessfulFetchOutput
            }
            let newOID = fields[1].lowercased()
            guard (newOID.count == 40 || newOID.count == 64),
                  newOID.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) }),
                  !newOID.allSatisfy({ $0 == "0" }) else {
                throw FetchTargetCaptureError.invalidSuccessfulFetchOutput
            }
            candidates.append(newOID)
        }
        guard candidates.count == 1 else {
            throw FetchTargetCaptureError.invalidSuccessfulFetchOutput
        }
        return candidates[0]
    }

    private func isMissingRemoteMain(_ result: ProcessResult) -> Bool {
        let detail = result.diagnostic.lowercased()
        return ["couldn't find remote ref ", "could not find remote ref "].contains {
            detail.contains($0 + "main") || detail.contains($0 + "refs/heads/main")
        }
    }

    private func validateRuntimeEligibility(
        _ candidate: RepositoryCandidate
    ) throws {
        guard candidate.isEligible,
              candidate.hasValidatedOriginIdentity else {
            throw GitSafetyError.unsafeRepository(
                "blocked repository entered Git transaction"
            )
        }
        #if SHADOW_SYNC_TESTING
        try configuration.runtimeEligibilityCheck?(candidate)
        #else
        try RepositoryDiscovery.validateRuntimeEligibility(candidate, account: account)
        #endif
    }

    private func fetchCode(_ reason: FetchFailureReason) -> ResultCode {
        switch reason {
        case .authentication:
            return .failedFetchAuthentication
        case .dns, .transport, .timeout:
            return .failedFetchNetwork
        case .other:
            return .failedFetch
        }
    }

    private func fetchExplanation(_ reason: FetchFailureReason) -> String {
        switch reason {
        case .authentication:
            return "GitHub authentication failed; local main was not updated."
        case .dns:
            return "The GitHub host could not be resolved; local main was not updated."
        case .transport:
            return "The Git transport failed; local main was not updated."
        case .timeout:
            return "The fetch timed out; local main was not updated."
        case .other:
            return "The fetch failed; local main was not updated."
        }
    }

    private func mapPreflightError(
        _ error: GitSafetyError,
        result: (
            ResultCode,
            Bool,
            String?,
            String,
            String?,
            FetchFailureReason?
        ) -> RepositoryResult,
        beforeCommit: String?,
        fetched: Bool
    ) -> RepositoryResult {
        let code: ResultCode
        let explanation: String
        switch error {
        case .repositoryRemoved:
            code = .skippedRepositoryRemoved
            explanation = "The repository was removed; no update was made."
        case .originChanged:
            code = .skippedOriginChanged
            explanation = "The origin no longer matches the reviewed repository; no network update was attempted."
        case .busy:
            code = .skippedBusy
            explanation = "Another Git operation is active; no update was made."
        case .hiddenIndex:
            code = .skippedHiddenIndexState
            explanation = "Hidden index state is present; no update was made."
        case .dirty:
            code = .skippedDirty
            explanation = "The working copy has changes; no update was made."
        case .detached:
            code = .skippedDetachedHead
            explanation = "The primary working copy is detached; no update was made."
        case .primaryNotOnMain:
            code = .skippedPrimaryNotOnMain
            explanation = "The primary working copy is not on main; no branch was switched."
        case .mainInLinkedWorktree:
            code = .skippedMainInLinkedWorktree
            explanation = "Main is checked out in a linked worktree; no update was made."
        case .localMainMissing:
            code = .skippedLocalMainMissing
            explanation = "Local main is missing; no branch was created."
        case .remoteMainMissing:
            code = .skippedRemoteMainMissing
            explanation = "Remote main is missing; local main was preserved."
        case .unsupportedHookFramework:
            code = .skippedUnsupportedHookFramework
            explanation = "An unsupported hook framework appeared; no Git command was run."
        case .cancelled:
            code = beforeCommit == nil ? .cancelledPending : .cancelledNoUpdate
            if beforeCommit == nil {
                explanation = "The pending repository was cancelled before it started."
            } else if fetched {
                explanation = "Fetch completed, but the run was cancelled before local main changed."
            } else {
                explanation = "The run was cancelled before local main changed."
            }
        default:
            code = .failedInspection
            explanation = "The repository could not be verified safely; no update was made."
        }
        return result(
            code,
            false,
            beforeCommit,
            explanation,
            String(describing: error),
            nil
        )
    }
}
