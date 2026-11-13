import Foundation

public struct Body3CoordinatorEvent:
    Sendable {
    public let progress: Body3BatchProgress?
    public let record: Body3LogRecord?
    public let confirmation:
        Body3ConfirmationRequest?

    public init(
        progress: Body3BatchProgress? = nil,
        record: Body3LogRecord? = nil,
        confirmation:
            Body3ConfirmationRequest? = nil
    ) {
        self.progress = progress
        self.record = record
        self.confirmation = confirmation
    }
}

public final class Body3ConfirmationRequest:
    @unchecked Sendable {
    fileprivate enum Resolution {
        case pending
        case confirmed(GroupedRemovalConfirmation)
        case cancelled
    }

    public let run: String
    public let prepared: [PreparedRemoval]
    public let operations: [PlannedOperation]
    private let condition = NSCondition()
    private var resolution: Resolution = .pending

    fileprivate init(
        run: String,
        prepared: [PreparedRemoval],
        operations: [PlannedOperation]
    ) {
        self.run = run
        self.prepared = prepared
        self.operations = operations
    }

    @discardableResult
    public func confirm(
        retainedIDs: Set<String>
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard case .pending = resolution else {
            return false
        }
        let known = Set(prepared.map {
            $0.selection.candidate.id
        })
        guard retainedIDs.isSubset(of: known),
              let confirmation =
                try? GroupedRemovalConfirmation(
                    run: run,
                    rows: prepared.map {
                        ConfirmedRemovalRow(
                            prepared: $0,
                            retained: retainedIDs.contains(
                                $0.selection.candidate.id
                            )
                        )
                    }
                ) else {
            return false
        }
        resolution = .confirmed(confirmation)
        condition.broadcast()
        return true
    }

    @discardableResult
    public func cancel() -> Bool {
        condition.lock()
        let settled: Bool
        if case .pending = resolution {
            resolution = .cancelled
            condition.broadcast()
            settled = true
        } else {
            settled = false
        }
        condition.unlock()
        return settled
    }

    fileprivate func wait(
        cancellation: CancellationToken
    ) -> Resolution {
        condition.lock()
        defer { condition.unlock() }
        while case .pending = resolution {
            if cancellation.isCancelled {
                resolution = .cancelled
                break
            }
            _ = condition.wait(
                until: Date(
                    timeIntervalSinceNow: 0.05
                )
            )
        }
        return resolution
    }

    #if SHADOW_SYNC_TESTING
    public static func testing(
        run: String,
        prepared: [PreparedRemoval],
        operations: [PlannedOperation] = []
    ) -> Body3ConfirmationRequest {
        Body3ConfirmationRequest(
            run: run,
            prepared: prepared,
            operations: operations
        )
    }

    public func testingWait(
        cancellation: CancellationToken
    ) -> String {
        switch wait(cancellation: cancellation) {
        case .pending:
            return "pending"
        case .confirmed:
            return "confirmed"
        case .cancelled:
            return "cancelled"
        }
    }
    #endif
}

private final class Body3ExecutionContext:
    @unchecked Sendable {
    private struct VerifiedFreshCard {
        let card: RepositoryCard
        let capability: VerifiedRepositoryAuthorityCapability
    }
    private let lock = NSLock()
    private var confirmation:
        GroupedRemovalConfirmation?
    private var preparedRows:
        [String: PreparedRemoval] = [:]
    private var retentionPreparations:
        [String: RetentionPreparation] = [:]
    private var freshCards:
        [String: VerifiedFreshCard] = [:]
    private var removalResults:
        [String: RemovalExecutionResult] = [:]
    private var nodeStatuses:
        [String: Body3BatchNodeStatus] = [:]

    init() {}

    func record(
        nodeID: String,
        status: Body3BatchNodeStatus
    ) {
        lock.lock()
        nodeStatuses[nodeID] = status
        lock.unlock()
    }

    func prerequisitesSucceeded(
        _ nodeIDs: Set<String>
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return nodeIDs.allSatisfy {
            nodeStatuses[$0] == .succeeded
        }
    }

    func prepared(candidateID: String) -> PreparedRemoval? {
        lock.lock()
        defer { lock.unlock() }
        return preparedRows[candidateID]
    }

    func record(
        _ prepared: PreparedRemoval,
        retention: RetentionPreparation? = nil
    ) {
        lock.lock()
        let candidateID = prepared.selection.candidate.id
        preparedRows[candidateID] = prepared
        if let retention {
            retentionPreparations[candidateID] = retention
        }
        lock.unlock()
    }

    func removePrepared(candidateID: String) {
        lock.lock()
        preparedRows.removeValue(forKey: candidateID)
        retentionPreparations.removeValue(
            forKey: candidateID
        )
        lock.unlock()
    }

    func retentionPreparation(
        candidateID: String
    ) -> RetentionPreparation? {
        lock.lock()
        defer { lock.unlock() }
        return retentionPreparations[candidateID]
    }

    func record(_ verified: VerifiedSelectedRepositoryInventory) {
        lock.lock()
        for card in verified.inventory.cards {
            freshCards[card.repository.id] = VerifiedFreshCard(
                card: card,
                capability: verified.capability
            )
        }
        lock.unlock()
    }

    func refreshedSelection(
        from original: RemovalSelection,
        protectedPaths: [String]
    ) -> RemovalSelection? {
        lock.lock()
        let verifiedCard = freshCards[
            original.candidate.repository.id
        ]
        lock.unlock()
        guard let verifiedCard else {
            return nil
        }
        let card = verifiedCard.card
        guard
              let clone = card.clones.first(where: {
                  $0.id == original.candidate.clone.id
              }) else {
            return nil
        }
        let candidates =
            RepositoryInventoryRemovalCandidates.make(
                from: RepositoryInventory(
                    cards: [card],
                    onboardingProposals: [],
                    authorityFileIdentity: nil
                ),
                capability: verifiedCard.capability,
                protectedPaths: protectedPaths
            )
        guard let fresh = candidates.first(where: {
            $0.clone.id == clone.id
                && $0.kind == original.candidate.kind
                && $0.target == original.candidate.target
        }),
        fresh.canSelect,
        fresh.expectedOID == original.candidate.expectedOID,
        fresh.worktree?.rootIdentity
            == original.candidate.worktree?.rootIdentity,
        fresh.worktree?.registrationIdentity
            == original.candidate.worktree?
                .registrationIdentity,
        fresh.worktree?.contentEvidenceDigest
            == original.candidate.worktree?
                .contentEvidenceDigest,
        fresh.liveRiskIsNoWorse(
            than: original.candidate
        ) else {
            return nil
        }
        let intent = original.intent.isExplicitOverride
            ? original.intent
            : fresh.defaultIntent
        return try? RemovalSelection(
            candidate: fresh,
            intent: intent,
            includePossibleSecrets:
                original.includePossibleSecrets,
            selectedAt: original.selectedAt
        )
    }

    func prepared(
        candidateIDs: [String]
    ) -> [PreparedRemoval] {
        lock.lock()
        defer { lock.unlock() }
        return candidateIDs.compactMap {
            preparedRows[$0]
        }
    }

    func record(
        _ confirmation: GroupedRemovalConfirmation
    ) {
        lock.lock()
        self.confirmation = confirmation
        lock.unlock()
    }

    func admitted(candidateID: String) -> PreparedRemoval? {
        lock.lock()
        defer { lock.unlock() }
        return confirmation?.admitted.first {
            $0.selection.candidate.id == candidateID
        }
    }

    func finalConfirmation()
        -> GroupedRemovalConfirmation? {
        lock.lock()
        defer { lock.unlock() }
        return confirmation
    }

    func record(_ result: RemovalExecutionResult) {
        lock.lock()
        removalResults[result.candidateID] = result
        lock.unlock()
    }

    func result(candidateID: String)
        -> RemovalExecutionResult? {
        lock.lock()
        defer { lock.unlock() }
        return removalResults[candidateID]
    }
}

private final class Body3EventSerialization:
    @unchecked Sendable {
    private let lock = NSLock()

    func perform<Result>(
        _ body: () throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public extension RunCoordinator {
    func runBody3(
        authorizedPlan: AuthorizedBody3Plan,
        cancellation: CancellationToken,
        processObserver: @escaping @Sendable (
            Int,
            ProcessIdentity?
        ) -> Bool = { _, _ in true },
        repositoryObserver: @escaping @Sendable (Int, RepositoryCommandObservation) -> Bool = { _, _ in true },
        eventSink: @escaping @Sendable (
            Body3CoordinatorEvent
        ) -> Void
    ) throws -> Body3BatchReport {
        try runBody3Unverified(
            plan: authorizedPlan.plan,
            selectedScope: authorizedPlan.scope,
            cancellation: cancellation,
            inventoryProvider: nil,
            processObserver: processObserver,
            repositoryObserver: repositoryObserver,
            eventSink: eventSink
        )
    }

    #if SHADOW_SYNC_TESTING
    func runBody3(
        plan: Body3BatchPlan,
        selectedScope: ValidatedSelectedRepositoryScope,
        cancellation: CancellationToken,
        inventoryProvider: (
            @Sendable (ValidatedSelectedRepositoryScope)
                throws -> RepositoryInventory
        )? = nil,
        processObserver: @escaping @Sendable (
            Int,
            ProcessIdentity?
        ) -> Bool = { _, _ in true },
        repositoryObserver: @escaping @Sendable (Int, RepositoryCommandObservation) -> Bool = { _, _ in true },
        eventSink: @escaping @Sendable (
            Body3CoordinatorEvent
        ) -> Void
    ) throws -> Body3BatchReport {
        try runBody3Unverified(
            plan: plan,
            selectedScope: selectedScope,
            cancellation: cancellation,
            inventoryProvider: inventoryProvider,
            processObserver: processObserver,
            repositoryObserver: repositoryObserver,
            eventSink: eventSink
        )
    }
    #endif

    private func runBody3Unverified(
        plan: Body3BatchPlan,
        selectedScope: ValidatedSelectedRepositoryScope,
        cancellation: CancellationToken,
        inventoryProvider: (
            @Sendable (ValidatedSelectedRepositoryScope)
                throws -> RepositoryInventory
        )? = nil,
        processObserver: @escaping @Sendable (
            Int,
            ProcessIdentity?
        ) -> Bool = { _, _ in true },
        repositoryObserver: @escaping @Sendable (Int, RepositoryCommandObservation) -> Bool = { _, _ in true },
        eventSink: @escaping @Sendable (
            Body3CoordinatorEvent
        ) -> Void
    ) throws -> Body3BatchReport {
        let confirmationNodes = plan.nodes.filter {
            $0.kind == .groupedRemovalConfirmation
        }
        let plannedRemovalRows =
            plan.nodes.compactMap {
                node -> String? in
                if case let .removal(candidate)
                        = node.payload {
                    return candidate.id
                }
                return nil
            }
        let plannedRemovalIDs = Set(plannedRemovalRows)
        let retentionRows = plan.nodes.compactMap {
            node -> String? in
            if case let .retention(selection)
                    = node.payload {
                return selection.candidate.id
            }
            return nil
        }
        let residueRows = plan.nodes.compactMap {
            node -> String? in
            if case let .residue(candidate)
                    = node.payload {
                return candidate.id
            }
            return nil
        }
        let selectedRemovals =
            confirmationNodes.compactMap {
                node -> [RemovalSelection]? in
                if case let .confirmation(selections)
                        = node.payload {
                    return selections
                }
                return nil
            }.flatMap { $0 }
        let selectedRemovalIDs = Set(
            selectedRemovals.map { $0.candidate.id }
        )
        let selectedOperations = plan.nodes.compactMap {
            node -> PlannedOperation? in
            if case let .operation(operation)
                    = node.payload {
                return operation
            }
            return nil
        }
        let plannedRepositoryIDs = Set(
            plan.nodes.compactMap { node -> String? in
                switch node.payload {
                case let .operation(operation):
                    return operation.target.repository.id
                case let .removal(candidate),
                     let .residue(candidate):
                    return candidate.repository.id
                case let .retention(selection):
                    return selection.candidate.repository.id
                case .confirmation:
                    return nil
                case let .reinspection(repositoryID, _, _),
                     let .policyInvalidation(repositoryID):
                    return repositoryID
                }
            }
        )
        let expectedRetentionIDs = Set(
            selectedRemovals.filter {
                $0.candidate.requiresRecoveryAttempt
            }.map { $0.candidate.id }
        )
        let hasRemovals =
            !selectedRemovalIDs.isEmpty
        guard plan.isStructurallyValid,
              confirmationNodes.count
                == (hasRemovals ? 1 : 0),
              hasRemovals
                || !selectedOperations.isEmpty,
              selectedRemovalIDs == plannedRemovalIDs,
              expectedRetentionIDs == Set(retentionRows),
              selectedRemovalIDs == Set(residueRows),
              selectedRemovals.count
                == selectedRemovalIDs.count,
              Set(selectedOperations.map(\.id)).count
                == selectedOperations.count,
              plan.policyEvidenceDigest
                == Body3BatchPlanner.evidenceDigest(
                    operations: selectedOperations,
                    removals: selectedRemovals,
                    governedRoot: try selectedScope.requireGovernedRootRole()
                ),
              Body3BatchPlanner.matchesPolicyBoundary(
                  plan, governedRoot: try selectedScope.requireGovernedRootRole()),
              plannedRemovalRows.count
                == selectedRemovalIDs.count,
              retentionRows.count == expectedRetentionIDs.count,
              residueRows.count == selectedRemovalIDs.count else {
            throw GitSafetyError.unsafeRepository(
                "Body 3 confirmation boundary does not match its immutable plan"
            )
        }
        guard plannedRepositoryIDs.isSubset(
            of: selectedScope.repositoryIDs
        ) else {
            throw GitSafetyError.unsafeRepository(
                "Body 3 plan exceeds immutable selected scope"
            )
        }
        let authority = try RunAuthority.acquireRun(
            at: configuration.stateLocation
        )
        defer { authority.release() }
        try configuration.installationAdmission?()
        let lease = try authority.duplicateOperationLease()
        defer { close(lease) }
        let log = try Body3RunLogWriter(
            authority: authority,
            plan: plan
        )
        let context = Body3ExecutionContext()
        let removalSafetyPrerequisites =
            Self.removalSafetyPrerequisites(
                plan
            )
        let eventSerialization = Body3EventSerialization()
        let sourceByClone = Self.body3Sources(plan)
        let control = Body3BatchControl()
        let coordinator = Body3BatchCoordinator()

        func transactionConfiguration()
            -> GitTransactionConfiguration {
            #if SHADOW_SYNC_TESTING
            if let mapping = configuration.transportMapping {
                return GitTransactionConfiguration(
                    trampolineExecutable:
                        configuration.trampolineExecutable,
                    operationLeaseDescriptor: lease,
                    transportMapping: mapping,
                    fetchMutationsByRepositoryPath:
                        configuration
                            .fetchMutationsByRepositoryPath,
                    localTimeoutSeconds:
                        configuration.localTimeoutSeconds,
                    fetchTimeoutSeconds:
                        configuration.fetchTimeoutSeconds
                )
            }
            #endif
            return GitTransactionConfiguration(
                trampolineExecutable:
                    configuration.trampolineExecutable,
                operationLeaseDescriptor: lease
            )
        }
        let configurationContext: CommandCustodyContext?
        #if SHADOW_SYNC_TESTING
        configurationContext = try borrowRepositoryContext(authority)
        #else
        configurationContext = try CommandCustodyContext.borrowing(authority)
        #endif
        defer { configurationContext?.close() }
        var preparedGitConfiguration = transactionConfiguration()
        preparedGitConfiguration.commandContext = configurationContext
        let gitConfiguration = preparedGitConfiguration
        let effectiveAccount = account
        let coordinatorConfiguration = configuration
        let protectedPaths = [
            coordinatorConfiguration.stateLocation.path,
            coordinatorConfiguration.trampolineExecutable
                ?? "",
            coordinatorConfiguration.trampolineExecutable
                .map {
                    URL(fileURLWithPath: $0)
                        .deletingLastPathComponent().path
                } ?? "",
        ].filter { !$0.isEmpty }
        let freshInventory: @Sendable (String, CommandAudit?)
            throws -> VerifiedSelectedRepositoryInventory =
            { repositoryID, audit in
                let exactScope = try selectedScope
                    .exactRepositoryScope(
                        repositoryID: repositoryID
                    )
                if let inventoryProvider {
                    let inventory = try inventoryProvider(
                        exactScope
                    )
                    guard Set(inventory.cards.map(\.id))
                            == exactScope.repositoryIDs,
                          inventory.onboardingProposals.isEmpty,
                          inventory.cards.allSatisfy({
                        $0.id == repositoryID
                            && $0.clones.allSatisfy {
                                exactScope.admits(
                                    $0.sourceSnapshot
                                )
                            }
                    }) else {
                        throw GitSafetyError.unsafeRepository(
                            "Body 3 refresh returned foreign repository data"
                        )
                    }
                    return try SelectedRepositoryHydrator
                        .verifyFreshInventory(
                            scope: exactScope,
                            inventory: inventory
                        )
                }
                guard let executable =
                    coordinatorConfiguration
                        .trampolineExecutable else {
                    throw GitSafetyError.unsafeRepository(
                        "fresh Body 3 inventory executable is unavailable"
                    )
                }
                let inventory = try RepositoryInventoryDiscovery(
                    executablePath: executable
                ).discoverInventory(
                    scope: exactScope,
                    state: authority.stateDirectory,
                    leaseDescriptor: lease,
                    audit: audit
                )
                return try SelectedRepositoryHydrator
                    .verifyFreshInventory(
                        scope: exactScope,
                        inventory: inventory
                    )
            }
        let state = try SecureStateDirectory.open(
            configuration.stateLocation
        )

        @Sendable func emit(
            node: Body3BatchNode,
            worker: Int?,
            type: String,
            status: Body3BatchNodeStatus?,
            detail: String,
            technicalDetail: String? = nil,
            command: Body3CommandLogEvidence? = nil,
            duration: Int64? = nil
        ) throws {
            try eventSerialization.perform {
                let removal: RemovalCandidate?
                switch node.payload {
                case let .removal(candidate),
                     let .residue(candidate):
                    removal = candidate
                case let .retention(selection):
                    removal = selection.candidate
                default:
                    removal = nil
                }
                let prepared = context.prepared(
                    candidateID: removal?.id ?? ""
                )
                let effectiveRemoval =
                    prepared?.selection.candidate ?? removal
                let record = try log.append(
                    type: type,
                    repository: node.repositoryID,
                    operation: node.id,
                    target: effectiveRemoval?.target,
                    kind: node.kind.rawValue,
                    phase: node.kind.phase,
                    worker: worker,
                    recommendation:
                        effectiveRemoval?.preview
                            .recommendation.rawValue,
                    selection:
                        prepared?.selection.intent.rawValue,
                    awa: effectiveRemoval?.worktree?
                        .awaEvidence?.state.rawValue,
                    retention: prepared?.finalClass.rawValue,
                    artifact: prepared?.artifact?.artifactID,
                    restore: prepared?.artifact?
                        .restoreInstructions
                        .joined(separator: " "),
                    exclusions: effectiveRemoval?
                        .hardExclusion.map { [$0] },
                    command: command,
                    status: status,
                    residue: context.result(
                        candidateID: removal?.id ?? ""
                    ).map {
                        "path=\($0.residue.pathPresent.map(String.init) ?? "n/a") registration=\($0.residue.worktreeRegistrationPresent.map(String.init) ?? "n/a") ref=\($0.residue.localRefPresent.map(String.init) ?? "n/a") claims=\($0.residue.claims.count) attention=\($0.residue.needsAttention)"
                    },
                    recovery:
                        "Interrupted nodes are postflighted without retry.",
                    detail: detail,
                    technicalDetail: technicalDetail,
                    durationMilliseconds: duration
                )
                try log.flush()
                eventSink(
                    Body3CoordinatorEvent(record: record)
                )
            }
        }

        let report = try coordinator.execute(
            plan: plan,
            control: control,
            externalCancellation: cancellation,
            onProgress: { progress in
                eventSink(Body3CoordinatorEvent(
                    progress: progress
                ))
            },
            onNodeTerminal: { nodeID, status in
                context.record(
                    nodeID: nodeID,
                    status: status
                )
            },
            runner: { node, worker, token in
                let nodeStarted = MonotonicInstant.now()
                if configurationContext?.hasCleanupPending == true {
                    let detail = "Cleanup is still pending. Further repository work is blocked."
                    try? emit(node: node, worker: worker, type: "node_cleanup_pending", status: .cleanupPending, detail: detail)
                    return Body3BatchNodeOutcome(status: .cleanupPending, detail: detail)
                }
                do {
                    try emit(
                        node: node,
                        worker: worker,
                        type: "node_started",
                        status: .running,
                        detail: "Node admitted to worker \(worker)."
                    )
                } catch {
                    cancellation.cancel()
                    return Body3BatchNodeOutcome(
                        status: .failed,
                        detail:
                            "Structured event write failed.",
                        infrastructureFailure:
                            Body3InfrastructureFailure(
                                category: "event-log-write",
                                stableFields: ["latest.log"]
                            )
                    )
                }

                let outcome: Body3BatchNodeOutcome
                var removalResult:
                    RemovalExecutionResult?
                var removalAudit: CommandAudit?
                switch node.payload {
                case let .operation(operation):
                    let commandAudit = CommandAudit()
                    let nodeRunner = DescriptorProcessRunner(
                        audit: commandAudit,
                        outputLimit:
                            DescriptorProcessRunner
                                .completeRepositoryOutputLimit,
                        processObserver: {
                            processObserver(worker, $0)
                        },
                        repositoryObserver: { repositoryObserver(worker, $0) }
                    )
                    let result: RepositoryResult
                    if operation.kind == .fastForward {
                        result = FastForwardTransactionV2(
                            runner: nodeRunner,
                            configuration: gitConfiguration,
                            account: effectiveAccount
                        ).execute(
                            operation: operation,
                            cancellation: token,
                            phase: { phase in
                                try emit(
                                    node: node,
                                    worker: worker,
                                    type: "node_phase",
                                    status: .running,
                                    detail: phase.rawValue
                                )
                            }
                        )
                    } else {
                        result = RepositoryMaintenanceTransaction(
                            runner: nodeRunner,
                            configuration: gitConfiguration,
                            account: effectiveAccount
                        ).execute(
                            operation: operation,
                            cancellation: token,
                            phase: { phase in
                                try emit(
                                    node: node,
                                    worker: worker,
                                    type: "node_phase",
                                    status: .running,
                                    detail: phase.rawValue
                                )
                            }
                        )
                    }
                    outcome = Self.body3Outcome(
                        result,
                        operationKind: operation.kind
                    )
                    do {
                        for invocation in
                            commandAudit.invocations {
                            try emit(
                                node: node,
                                worker: worker,
                                type: "command",
                                status: .running,
                                detail:
                                    "Closed Git command admitted for \(operation.kind.rawValue).",
                                command:
                                    Body3CommandLogEvidence(
                                        executable:
                                            invocation
                                                .executable,
                                        arguments:
                                            invocation
                                                .arguments,
                                        outcome:
                                            "admitted"
                                    )
                            )
                        }
                    } catch {
                        cancellation.cancel()
                    }

                case let .reinspection(
                    repositoryID, cloneID, reason
                ):
                    guard let source =
                            sourceByClone[cloneID] else {
                        outcome = Body3BatchNodeOutcome(
                            status: .failed,
                            detail:
                                "Re-inspection source is unavailable."
                        )
                        break
                    }
                    do {
                        let commandAudit = CommandAudit()
                        let handle = try RepositoryHandle.open(
                            source
                        )
                        try handle.revalidate()
                        context.record(
                            try freshInventory(
                                repositoryID,
                                commandAudit
                            )
                        )
                        for invocation in
                            commandAudit.invocations {
                            try emit(
                                node: node,
                                worker: worker,
                                type: "command",
                                status: .running,
                                detail:
                                    "Closed Git command admitted for fresh inventory.",
                                command:
                                    Body3CommandLogEvidence(
                                        executable:
                                            invocation
                                                .executable,
                                        arguments:
                                            invocation
                                                .arguments,
                                        outcome:
                                            "fresh inventory completed"
                                    )
                            )
                        }
                        outcome = Body3BatchNodeOutcome(
                            status: .succeeded,
                            detail:
                                "Fresh \(reason) identity inspection passed."
                        )
                    } catch {
                        outcome = Body3BatchNodeOutcome(
                            status: .refused,
                            detail:
                                "Fresh \(reason) inspection refused changed identity."
                        )
                    }

                case let .retention(selection):
                    let commandAudit = CommandAudit()
                    let retention =
                        RetentionArtifactStore(
                            state: state,
                            account: effectiveAccount,
                            runner: ClosedProcessRunner(
                                audit: commandAudit
                            ),
                            configurationContext: configurationContext
                        )
                    #if SHADOW_SYNC_TESTING
                    retention.testingCustodyHooks = self.configuration.testingRetentionCustodyHooks
                    #endif
                    do {
                        guard let configurationContext else { throw SelectedRepositoryScopeError.policyUnavailable }
                        let exactScope = try selectedScope.exactRepositoryScope(
                            repositoryID: selection.candidate.repository.id)
                        try configurationContext.withRemovalDiscoveryPolicy(exactScope,
                            account: effectiveAccount, cancellation: token) { policy in
                            try RepositoryDiscovery.validateRemovalRuntimeEligibility(
                                selection.candidate.clone.sourceSnapshot,
                                repositoryID: selection.candidate.repository.id, policy: policy)
                        }
                    } catch {
                        outcome = Body3BatchNodeOutcome(
                            status: .refused,
                            detail:
                                "Recovery preparation was refused because policy or repository identity changed."
                        )
                        break
                    }
                    guard let freshSelection =
                            context.refreshedSelection(
                                from: selection,
                                protectedPaths:
                                    protectedPaths
                            ) else {
                        outcome = Body3BatchNodeOutcome(
                            status: .skipped,
                            detail:
                                "Fresh cleanup evidence was unavailable or risk increased; this row remained protected."
                        )
                        break
                    }
                    let preparation:
                        RetentionPreparation?
                    if freshSelection.candidate
                        .requiresRecoveryAttempt
                        || freshSelection
                            .includePossibleSecrets {
                        preparation = retention.prepare(
                            selection: freshSelection,
                            cancellation: token
                        )
                    } else {
                        preparation = nil
                    }
                    if case .cleanupPending? = preparation {
                        token.closeFutureChildAdmissions()
                        outcome = Body3BatchNodeOutcome(status: .cleanupPending,
                            detail: "Recovery work is still stopping; incomplete artifacts remain protected and removal is unavailable.")
                    } else if case .cancelled? = preparation {
                        outcome = Body3BatchNodeOutcome(
                            status: .cancelled,
                            detail:
                                "Recovery preparation was cancelled; completed artifacts and source state were preserved."
                        )
                    } else {
                        do {
                            let prepared = try
                                PreparedRemovalOracle.prepare(
                                    selection: freshSelection,
                                    retention: preparation
                                )
                            context.record(
                                prepared,
                                retention: preparation
                            )
                            let detail: String
                            if let artifact = prepared.artifact {
                                detail =
                                    "Restore-proven artifact \(artifact.artifactID) was published and remains protected."
                            } else if prepared.finalClass
                                        == .operatorOverrideRisk {
                                detail =
                                    "Recovery was not complete; the row was reclassified as Operator override risk for final confirmation."
                            } else {
                                detail =
                                    "Removal preparation completed without a required recovery payload."
                            }
                            outcome = Body3BatchNodeOutcome(
                                status: .succeeded,
                                detail: detail
                            )
                        } catch {
                            outcome = Body3BatchNodeOutcome(
                                status: .failed,
                                detail:
                                    "Removal preparation could not be closed from current evidence."
                            )
                        }
                    }
                    do {
                        for invocation in
                            commandAudit.invocations {
                            try emit(
                                node: node,
                                worker: worker,
                                type: "command",
                                status: .running,
                                detail:
                                    "Closed Git command admitted for protected recovery.",
                                command:
                                    Body3CommandLogEvidence(
                                        executable:
                                            invocation
                                                .executable,
                                        arguments:
                                            invocation
                                                .arguments,
                                        outcome:
                                            "admitted"
                                    )
                            )
                        }
                    } catch {
                        cancellation.cancel()
                    }

                case let .confirmation(selections):
                    do {
                        let commandAudit = CommandAudit()
                        for repositoryID in Set(
                            selections.map {
                                $0.candidate.repository.id
                            }
                        ).sorted() {
                            context.record(
                                try freshInventory(
                                    repositoryID,
                                    commandAudit
                                )
                            )
                        }
                        for invocation in
                            commandAudit.invocations {
                            try emit(
                                node: node,
                                worker: worker,
                                type: "command",
                                status: .running,
                                detail:
                                    "Closed Git command admitted for final policy and removal re-inspection.",
                                command:
                                    Body3CommandLogEvidence(
                                        executable:
                                            invocation
                                                .executable,
                                        arguments:
                                            invocation
                                                .arguments,
                                        outcome:
                                            "final confirmation inventory completed"
                                    )
                            )
                        }
                    } catch {
                        outcome = Body3BatchNodeOutcome(
                            status: .refused,
                            detail:
                                "Final confirmation was refused because policy or repository evidence could not be refreshed."
                        )
                        break
                    }
                    let candidateIDs = selections.map(\.candidate.id)
                    let retentionStore =
                        RetentionArtifactStore(
                            state: state,
                            account: effectiveAccount
                        )
                    for selection in selections {
                        guard let prerequisiteIDs =
                                removalSafetyPrerequisites[
                                    selection.candidate.id
                                ],
                              context
                                .prerequisitesSucceeded(
                                    prerequisiteIDs
                                ) else {
                            context.removePrepared(
                                candidateID:
                                    selection.candidate.id
                            )
                            continue
                        }
                        let existing = context.prepared(
                            candidateID: selection.candidate.id
                        )
                        let baseline =
                            existing?.selection ?? selection
                        guard let fresh =
                                context.refreshedSelection(
                                    from: baseline,
                                    protectedPaths:
                                        protectedPaths
                                ) else {
                            context.removePrepared(
                                candidateID:
                                    selection.candidate.id
                            )
                            continue
                        }
                        let retention =
                            context.retentionPreparation(
                                candidateID:
                                    selection.candidate.id
                            )
                        if case let .completed(artifact)? =
                                retention {
                            guard (try? retentionStore.verify(
                                artifact
                            )) == true else {
                                context.removePrepared(
                                    candidateID:
                                        selection.candidate.id
                                )
                                continue
                            }
                        }
                        guard let prepared = try?
                                PreparedRemovalOracle.prepare(
                                    selection: fresh,
                                    retention: retention
                                ) else {
                            context.removePrepared(
                                candidateID:
                                    selection.candidate.id
                            )
                            continue
                        }
                        context.record(
                            prepared,
                            retention: retention
                        )
                    }
                    let prepared = context.prepared(
                        candidateIDs: candidateIDs
                    )
                    guard !prepared.isEmpty else {
                        outcome = Body3BatchNodeOutcome(
                            status: .skipped,
                            detail:
                                "No prepared removal rows remained eligible for final confirmation."
                        )
                        break
                    }
                    let request = Body3ConfirmationRequest(
                        run: plan.run,
                        prepared: prepared,
                        operations: plan.nodes.compactMap {
                            if case let .operation(operation)
                                    = $0.payload {
                                return operation
                            }
                            return nil
                        }
                    )
                    eventSink(Body3CoordinatorEvent(
                        confirmation: request
                    ))
                    switch request.wait(cancellation: token) {
                    case let .confirmed(confirmation):
                        context.record(confirmation)
                        outcome = Body3BatchNodeOutcome(
                            status: .succeeded,
                            detail:
                                "One grouped final confirmation admitted \(confirmation.admitted.count) retained row(s)."
                        )
                    case .cancelled, .pending:
                        outcome = Body3BatchNodeOutcome(
                            status: .cancelled,
                            detail:
                                "Final confirmation was cancelled; source state and completed artifacts were preserved."
                        )
                    }

                case let .removal(candidate):
                    guard let prepared = context.admitted(
                        candidateID: candidate.id
                    ), let confirmation =
                        context.finalConfirmation() else {
                        outcome = Body3BatchNodeOutcome(
                            status: .skipped,
                            detail:
                                "Protected/Skipped — row was deselected in final confirmation."
                        )
                        break
                    }
                    do {
                        let commandAudit = CommandAudit()
                        removalAudit = commandAudit
                        context.record(
                            try freshInventory(
                                candidate.repository.id,
                                commandAudit
                            )
                        )
                        guard let refreshedSelection =
                                context.refreshedSelection(
                                    from:
                                        prepared.selection,
                                    protectedPaths:
                                        protectedPaths
                                ) else {
                            outcome = Body3BatchNodeOutcome(
                                status: .refused,
                                detail:
                                    "Fresh removal evidence was unavailable or risk increased after final confirmation; no command started."
                            )
                            break
                        }
                        let runtimePrepared =
                            try PreparedRemoval(
                                selection:
                                    refreshedSelection,
                                finalClass:
                                    prepared.finalClass,
                                artifact:
                                    prepared.artifact,
                                consequence:
                                    prepared.consequence,
                                forceLevel:
                                    prepared.forceLevel,
                                historyLossAccepted:
                                    prepared
                                        .historyLossAccepted
                            )
                        let removalConfiguration =
                            RemovalTransactionConfiguration(
                                git: gitConfiguration,
                                stateLocation:
                                    coordinatorConfiguration
                                        .stateLocation,
                                awaExecutablePath:
                                    // Unavailable until the private policy-bound
                                    // adapter is integrated. Empty paths are
                                    // rejected before filesystem access.
                                    "",
                                protectedPaths:
                                    protectedPaths,
                                selectedScope: selectedScope
                            )
                        try coordinatorConfiguration
                            .installationAdmission?()
                        let transaction =
                            RemovalTransaction(
                                runner:
                                    DescriptorProcessRunner(
                                        audit: commandAudit,
                                        outputLimit:
                                            DescriptorProcessRunner
                                                .completeRepositoryOutputLimit,
                                        processObserver: {
                                            processObserver(
                                                worker,
                                                $0
                                            )
                                        }
                                    ),
                                configuration:
                                    removalConfiguration,
                                account: effectiveAccount
                            )
                        let result = transaction.execute(
                            prepared: runtimePrepared,
                            confirmation: confirmation,
                            cancellation: token
                        )
                        context.record(result)
                        removalResult = result
                        outcome = Body3BatchNodeOutcome(
                            status: Self.body3Status(
                                result.status
                            ),
                            detail: result.explanation,
                            awaAdvisoryFailure:
                                result.awaDisposition
                                    == .refused
                                    || result.awaDisposition
                                        == .unavailable
                        )
                    } catch {
                        outcome = Body3BatchNodeOutcome(
                            status: .failed,
                            detail:
                                "Fresh installation admission refused cleanup; no removal command started."
                        )
                    }

                case let .residue(candidate):
                    if let result = context.result(
                        candidateID: candidate.id
                    ) {
                        outcome = Body3BatchNodeOutcome(
                            status: .succeeded,
                            detail:
                                result.residue.needsAttention
                                ? "Residue inspection completed: Needs Attention."
                                : "Git, artifact, and AWA residue inspection completed."
                        )
                    } else {
                        outcome = Body3BatchNodeOutcome(
                            status: .skipped,
                            detail:
                                "No admitted removal mutation required residue verification."
                        )
                    }

                case let .policyInvalidation(repositoryID):
                    outcome = Body3BatchNodeOutcome(
                        status: .succeeded,
                        detail:
                            "\(repositoryID) ran last and alone; cached preview and policy/config comparison are invalidated."
                    )
                }

                if let removalResult {
                    if let removalAudit {
                        for invocation in
                            removalAudit.invocations {
                            let matching =
                                removalResult.commands
                                    .first {
                                        $0.executable
                                            == invocation
                                                .executable
                                            && $0.arguments
                                                == invocation
                                                    .arguments
                                    }
                            do {
                                try emit(
                                    node: node,
                                    worker: worker,
                                    type: "command",
                                    status: .running,
                                    detail: matching?
                                        .outcome
                                        ?? "Closed Git removal preflight command admitted.",
                                    command: matching.map(
                                        Body3CommandLogEvidence
                                            .init
                                    ) ?? Body3CommandLogEvidence(
                                        executable:
                                            invocation
                                                .executable,
                                        arguments:
                                            invocation
                                                .arguments,
                                        outcome:
                                            "admitted"
                                    )
                                )
                            } catch {
                                cancellation.cancel()
                            }
                        }
                    }
                    for command in removalResult.commands {
                        if command.executable
                            == DescriptorProcessRunner.gitPath,
                           removalAudit?.invocations
                            .contains(where: {
                                $0.executable
                                    == command.executable
                                    && $0.arguments
                                        == command.arguments
                            }) == true {
                            continue
                        }
                        do {
                            try emit(
                                node: node,
                                worker: worker,
                                type: "command",
                                status: .running,
                                detail: command.outcome,
                                command:
                                    Body3CommandLogEvidence(
                                        command
                                    )
                            )
                        } catch {
                            cancellation.cancel()
                        }
                    }
                }
                if configurationContext?.hasCleanupPending == true || outcome.status == .cleanupPending {
                    let pending = Body3BatchNodeOutcome(status: .cleanupPending,
                        detail: "Cleanup is still pending. Further repository work is blocked.")
                    do { try emit(node: node, worker: worker, type: "node_cleanup_pending",
                        status: pending.status, detail: pending.detail) }
                    catch { cancellation.cancel() }
                    return pending
                }
                do {
                    try emit(
                        node: node,
                        worker: worker,
                        type: "node_terminal",
                        status: outcome.status,
                        detail: outcome.detail,
                        technicalDetail:
                            outcome.technicalDetail,
                        duration:
                            MonotonicInstant.now()
                                .milliseconds(
                                    since: nodeStarted
                                )
                    )
                } catch {
                    cancellation.cancel()
                    return Body3BatchNodeOutcome(
                        status: .failed,
                        detail:
                            "Terminal structured event could not be persisted.",
                        infrastructureFailure:
                            Body3InfrastructureFailure(
                                category: "event-log-write",
                                stableFields: ["latest.log"]
                            )
                    )
                }
                return outcome
            }
        )
        if report.cleanupPending || configurationContext?.hasCleanupPending == true {
            let pending = try log.append(type: "run_cleanup_pending", phase: "Cleanup pending",
                status: .cleanupPending,
                detail: "Command cleanup remains unresolved; retained resources and incomplete artifacts remain protected.",
                report: report)
            eventSink(Body3CoordinatorEvent(record: pending))
            try log.flush()
            return report
        }
        let finalStatus: Body3BatchNodeStatus
        if report.cancelled {
            finalStatus = .cancelled
        } else if report.paused
                    || report.results.contains(where: {
                        $0.status == .failed
                    }) {
            finalStatus = .failed
        } else if report.results.contains(where: {
                    $0.status == .refused
                }) {
            finalStatus = .refused
        } else {
            finalStatus = .succeeded
        }
        let finished = try log.append(
            type: "run_finished",
            phase: "Complete",
            status: finalStatus,
            recovery: report.paused
                ? "Run paused after three matching system failures — running operations were drained. Review the live log, then start a fresh inspection."
                : nil,
            detail: report.paused
                ? "Every node reached a terminal state after infrastructure admission paused."
                : "\(report.results.count) node(s) reached terminal state.",
            report: report
        )
        eventSink(Body3CoordinatorEvent(record: finished))
        try log.flush()
        return report
    }

    private static func body3Sources(
        _ plan: Body3BatchPlan
    ) -> [String: RepositoryCandidate] {
        var result: [String: RepositoryCandidate] = [:]
        for node in plan.nodes {
            switch node.payload {
            case let .operation(operation):
                result[operation.target.canonicalClone.id] =
                    operation.target.canonicalClone
                        .sourceSnapshot
            case let .retention(selection):
                result[selection.candidate.clone.id] =
                    selection.candidate.clone.sourceSnapshot
            case let .removal(candidate),
                 let .residue(candidate):
                result[candidate.clone.id] =
                    candidate.clone.sourceSnapshot
            default:
                continue
            }
        }
        return result
    }

    private static func removalSafetyPrerequisites(
        _ plan: Body3BatchPlan
    ) -> [String: Set<String>] {
        let nodeByID = Dictionary(
            uniqueKeysWithValues: plan.nodes.map {
                ($0.id, $0)
            }
        )
        var result: [String: Set<String>] = [:]
        let selections = plan.nodes.compactMap {
            node -> [RemovalSelection]? in
            if case let .confirmation(rows) =
                    node.payload {
                return rows
            }
            return nil
        }.flatMap { $0 }
        for selection in selections {
            let candidateID =
                selection.candidate.id
            if let retention = plan.nodes.first(
                where: { node in
                    guard case let .retention(row) =
                            node.payload else {
                        return false
                    }
                    return row.candidate.id
                        == candidateID
                }
            ) {
                result[candidateID] = Set(
                    retention.dependencies.map(\.nodeID)
                )
                continue
            }
            guard let removal = plan.nodes.first(
                where: { node in
                    guard case let .removal(candidate)
                            = node.payload else {
                        return false
                    }
                    return candidate.id == candidateID
                        && (
                            node.kind == .worktreeRemoval
                                || node.kind
                                    == .branchRemoval
                        )
                }
            ) else {
                continue
            }
            if removal.kind == .worktreeRemoval {
                result[candidateID] = Set(
                    removal.dependencies.compactMap {
                        dependency in
                        nodeByID[
                            dependency.nodeID
                        ]?.kind
                            == .groupedRemovalConfirmation
                            ? nil : dependency.nodeID
                    }
                )
                continue
            }
            guard let claimID =
                    removal.dependencies.first?
                        .nodeID,
                  let claim = nodeByID[claimID],
                  claim.kind == .claimReinspection else {
                continue
            }
            result[candidateID] = Set(
                claim.dependencies.compactMap {
                    dependency in
                    guard let kind = nodeByID[
                        dependency.nodeID
                    ]?.kind,
                          kind
                            != .groupedRemovalConfirmation,
                          kind != .worktreeRemoval else {
                        return nil
                    }
                    return dependency.nodeID
                }
            )
        }
        return result
    }

    #if SHADOW_SYNC_TESTING
    static func testingRemovalSafetyPrerequisites(
        _ plan: Body3BatchPlan
    ) -> [String: Set<String>] {
        removalSafetyPrerequisites(plan)
    }
    #endif

    private static func body3Outcome(
        _ result: RepositoryResult,
        operationKind: PlannedOperationKind
    ) -> Body3BatchNodeOutcome {
        let status: Body3BatchNodeStatus
        switch result.resultClass {
        case .success: status = .succeeded
        case .warning: status = .refused
        case .failure: status = .failed
        case .cancelled: status = .cancelled
        }
        let infrastructure:
            Body3InfrastructureFailure?
        switch result.failureReason {
        case .dns:
            infrastructure = Body3InfrastructureFailure(
                category: "git-network",
                stableFields: [
                    operationKind.rawValue,
                    FetchFailureReason.dns.rawValue,
                    DescriptorProcessRunner.gitPath,
                    "transport",
                ]
            )
        case .transport, .timeout:
            infrastructure = Body3InfrastructureFailure(
                category: "git-network",
                stableFields: [
                    operationKind.rawValue,
                    result.failureReason?.rawValue
                        ?? FetchFailureReason.other.rawValue,
                    DescriptorProcessRunner.gitPath,
                    "transport",
                ]
            )
        default:
            infrastructure = nil
        }
        return Body3BatchNodeOutcome(
            status: status,
            detail: result.explanation,
            infrastructureFailure: infrastructure,
            technicalDetail: result.technicalDetail
        )
    }

    private static func body3Status(
        _ status: RemovalTerminalStatus
    ) -> Body3BatchNodeStatus {
        switch status {
        case .succeeded: return .succeeded
        case .skipped: return .skipped
        case .refused: return .refused
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }
}
