import Foundation

public struct SelectedRepositoryHydrationEvidence:
    Equatable, Sendable {
    public let scope: ValidatedSelectedRepositoryScope
    public let proposals: [CanonicalAuthorityProposal]
    public let authorityFileIdentity: FileIdentity?
    public let hydratedRepositoryIDs: Set<String>
    public let authorityCandidateClones: [LocalClone]
}

public enum SelectedRepositoryHydrationResult: Sendable {
    case onboarding(
        ValidatedSelectedRepositoryScope,
        RepositoryInventory
    )
    case verified(VerifiedSelectedRepositoryInventory)
}

public struct VerifiedRepositoryAuthorityCapability:
    Sendable {
    public let scope: ValidatedSelectedRepositoryScope
    public let verifiedRepositoryIDs: Set<String>
    fileprivate let generationToken: String

    init(
        scope: ValidatedSelectedRepositoryScope,
        inventory: RepositoryInventory
    ) throws {
        let selected = scope.repositoryIDs
        let cards = Set(inventory.cards.map(\.id))
        guard cards == selected,
              inventory.onboardingProposals.isEmpty,
              inventory.cards.allSatisfy({
                  !$0.isWritable || $0.authority.status == .usable
              }),
              inventory.cards.flatMap(\.clones).allSatisfy({
                  scope.admits($0.sourceSnapshot)
              }) else {
            throw GitSafetyError.unsafeRepository(
                "fresh selected hydration did not produce verified authority"
            )
        }
        self.scope = scope
        verifiedRepositoryIDs = cards
        generationToken = RunIdentity.make()
    }

    init(
        scope: ValidatedSelectedRepositoryScope,
        clones: [LocalClone],
        authoritySnapshot: RepositoryAuthoritySnapshot
    ) throws {
        let selected = scope.repositoryIDs
        let grouped = Dictionary(grouping: clones, by: \.repositoryID)
        let records = Dictionary(
            uniqueKeysWithValues:
                authoritySnapshot.usableRecords.map {
                    ($0.repositoryID, $0)
                }
        )
        guard authoritySnapshot.status == .available,
              Set(grouped.keys) == selected,
              clones.allSatisfy({
                  scope.admits($0.sourceSnapshot)
              }),
              selected.allSatisfy({ repositoryID in
                  guard let record = records[repositoryID],
                        let repositoryClones = grouped[repositoryID] else {
                      return false
                  }
                  return repositoryClones.filter(record.matches).count == 1
              }) else {
            throw GitSafetyError.unsafeRepository(
                "fresh selected hydration did not verify current authority"
            )
        }
        self.scope = scope
        verifiedRepositoryIDs = selected
        generationToken = RunIdentity.make()
    }

    public func admits(_ candidate: RepositoryCandidate) -> Bool {
        verifiedRepositoryIDs.contains(candidate.id)
            && scope.admits(candidate)
    }

    public func admits(_ target: DefaultBranchUpdateTarget) -> Bool {
        verifiedRepositoryIDs.contains(target.repository.id)
            && target.canonicalClone.repositoryID
                == target.repository.id
            && admits(target.canonicalClone.sourceSnapshot)
            && target.canonicalClone.isAuthorityEligible
    }

    public func admits(
        repository: RemoteRepository,
        clones: [LocalClone]
    ) -> Bool {
        verifiedRepositoryIDs.contains(repository.id)
            && !clones.isEmpty
            && clones.allSatisfy {
                $0.repositoryID == repository.id
                    && admits($0.sourceSnapshot)
            }
    }

    public func admits(_ operation: PlannedOperation) -> Bool {
        admits(operation.target)
            && operation.isSelectable
    }

    public func admits(_ inventory: RepositoryInventory) -> Bool {
        Set(inventory.cards.map(\.id)) == verifiedRepositoryIDs
            && inventory.onboardingProposals.isEmpty
            && inventory.cards.allSatisfy {
                admits(
                    repository: $0.repository,
                    clones: $0.clones
                )
            }
    }
}

public struct VerifiedSelectedRepositoryInventory: Sendable {
    public let capability: VerifiedRepositoryAuthorityCapability
    public let inventory: RepositoryInventory
}

public struct SelectedRepositorySessionDelta:
    Equatable, Sendable {
    public let reusableRepositoryIDs: Set<String>
    public let repositoryIDsToHydrate: Set<String>
    public let droppedRepositoryIDs: Set<String>
}

public struct SelectedRepositorySessionPlan:
    Equatable, Sendable {
    public let delta: SelectedRepositorySessionDelta
    public let hydrationScope:
        ValidatedSelectedRepositoryScope?
}

public struct AuthorizedOperationEnvelope: Sendable {
    public let operation: PlannedOperation
    public let scope: ValidatedSelectedRepositoryScope
    fileprivate let capabilityGeneration: String

    public init(
        operation: PlannedOperation,
        capability: VerifiedRepositoryAuthorityCapability
    ) throws {
        guard capability.admits(operation) else {
            throw GitSafetyError.unsafeRepository(
                "operation lacks fresh selected authority"
            )
        }
        self.operation = operation
        scope = try capability.scope.exactRepositoryScope(
            repositoryID: operation.target.repository.id
        )
        capabilityGeneration = capability.generationToken
    }
}

public struct AuthorizedBody3Plan: Sendable {
    public let plan: Body3BatchPlan
    public let scope: ValidatedSelectedRepositoryScope
    fileprivate let capabilityGeneration: String

    public init(
        plan: Body3BatchPlan,
        capability: VerifiedRepositoryAuthorityCapability
    ) throws {
        func admits(_ candidate: RemovalCandidate) -> Bool {
            capability.verifiedRepositoryIDs.contains(
                candidate.repository.id
            )
                && candidate.clone.repositoryID
                    == candidate.repository.id
                && capability.admits(
                    candidate.clone.sourceSnapshot
                )
        }
        let admitted = plan.nodes.allSatisfy { node in
            switch node.payload {
            case let .operation(operation):
                return capability.admits(operation)
            case let .removal(candidate),
                 let .residue(candidate):
                return admits(candidate)
            case let .retention(selection):
                return admits(selection.candidate)
            case let .confirmation(selections):
                return !selections.isEmpty
                    && selections.allSatisfy {
                        admits($0.candidate)
                    }
            case let .reinspection(repositoryID, _, _),
                 let .policyInvalidation(repositoryID):
                return capability.verifiedRepositoryIDs.contains(
                    repositoryID
                )
            }
        }
        let role = try capability.scope.requireGovernedRootRole()
        guard plan.isStructurallyValid, admitted,
              Body3BatchPlanner.matchesPolicyBoundary(plan, governedRoot: role) else {
            throw GitSafetyError.unsafeRepository(
                "Body 3 plan lacks verified selected authority"
            )
        }
        self.plan = plan
        scope = capability.scope
        capabilityGeneration = capability.generationToken
    }
}

public final class SelectedRepositoryHydrator:
    @unchecked Sendable {
    private let executablePath: String
    private let cancellation: CancellationToken
    private let lifecycleObserver:
        (@Sendable (RepositoryInventoryLifecycleEvent) -> Void)?

    public init(
        executablePath: String,
        cancellation: CancellationToken = CancellationToken(),
        lifecycleObserver:
            (@Sendable (RepositoryInventoryLifecycleEvent) -> Void)? = nil
    ) {
        self.executablePath = executablePath
        self.cancellation = cancellation
        self.lifecycleObserver = lifecycleObserver
    }

    public func hydrateEvidence(
        scope: ValidatedSelectedRepositoryScope
    ) throws -> SelectedRepositoryHydrationEvidence {
        try RepositoryInventoryDiscovery(
            executablePath: executablePath,
            cancellation: cancellation,
            lifecycleObserver: lifecycleObserver
        ).discoverHydrationEvidence(scope: scope)
    }

    public func hydrateVerified(
        scope: ValidatedSelectedRepositoryScope
    ) throws -> VerifiedSelectedRepositoryInventory {
        let inventory = try RepositoryInventoryDiscovery(
            executablePath: executablePath,
            cancellation: cancellation,
            lifecycleObserver: lifecycleObserver
        ).discoverInventory(scope: scope)
        let capability =
            try VerifiedRepositoryAuthorityCapability(
                scope: scope,
                inventory: inventory
            )
        return VerifiedSelectedRepositoryInventory(
            capability: capability,
            inventory: inventory
        )
    }

    public func hydrateOnce(
        scope: ValidatedSelectedRepositoryScope
    ) throws -> SelectedRepositoryHydrationResult {
        try RepositoryInventoryDiscovery(
            executablePath: executablePath,
            cancellation: cancellation,
            lifecycleObserver: lifecycleObserver
        ).discoverSelectedHydration(scope: scope)
    }

    public func reconcileSession(
        scope: ValidatedSelectedRepositoryScope,
        retainedInventory: RepositoryInventory?,
        retainedCapability:
            VerifiedRepositoryAuthorityCapability?
    ) throws -> SelectedRepositoryHydrationResult {
        guard let retainedInventory,
              let retainedCapability,
              retainedCapability.admits(retainedInventory) else {
            return try hydrateOnce(scope: scope)
        }

        let plan = Self.sessionPlan(
            scope: scope,
            retainedScope: retainedCapability.scope,
            retainedRepositoryIDs:
                Set(retainedInventory.cards.map(\.id))
        )
        let delta = plan.delta
        let reusableIDs = delta.reusableRepositoryIDs

        guard let hydrationScope = plan.hydrationScope else {
            let inventory = Self.mergeSessionInventory(
                scope: scope,
                reusableRepositoryIDs: reusableIDs,
                retainedInventory: retainedInventory,
                freshInventory: nil
            )
            return .verified(
                VerifiedSelectedRepositoryInventory(
                    capability:
                        try VerifiedRepositoryAuthorityCapability(
                            scope: scope,
                            inventory: inventory
                        ),
                    inventory: inventory
                )
            )
        }

        let fresh = try RepositoryInventoryDiscovery(
            executablePath: executablePath,
            cancellation: cancellation,
            lifecycleObserver: lifecycleObserver
        ).discoverSelectedHydration(scope: hydrationScope)
        switch fresh {
        case let .onboarding(_, inventory):
            return .onboarding(
                scope,
                Self.mergeSessionInventory(
                    scope: scope,
                    reusableRepositoryIDs: reusableIDs,
                    retainedInventory: retainedInventory,
                    freshInventory: inventory
                )
            )
        case let .verified(verified):
            let inventory = Self.mergeSessionInventory(
                scope: scope,
                reusableRepositoryIDs: reusableIDs,
                retainedInventory: retainedInventory,
                freshInventory: verified.inventory
            )
            return .verified(
                VerifiedSelectedRepositoryInventory(
                    capability:
                        try VerifiedRepositoryAuthorityCapability(
                            scope: scope,
                            inventory: inventory
                        ),
                    inventory: inventory
                )
            )
        }
    }

    public func hydrateVerifiedSession(
        scope: ValidatedSelectedRepositoryScope,
        plan: SelectedRepositorySessionPlan,
        retainedInventory: RepositoryInventory?
    ) throws -> VerifiedSelectedRepositoryInventory {
        let selected = scope.repositoryIDs
        let expectedHydrationIDs: Set<String>? =
            plan.delta.repositoryIDsToHydrate.isEmpty
                ? nil
                : plan.delta.repositoryIDsToHydrate
        guard plan.delta.reusableRepositoryIDs
                .union(plan.delta.repositoryIDsToHydrate)
                == selected,
              plan.delta.reusableRepositoryIDs.isDisjoint(
                  with: plan.delta.repositoryIDsToHydrate
              ),
              plan.hydrationScope?.repositoryIDs
                == expectedHydrationIDs else {
            throw GitSafetyError.unsafeRepository(
                "selected session hydration plan changed"
            )
        }
        guard let hydrationScope = plan.hydrationScope else {
            guard let retainedInventory else {
                throw GitSafetyError.unsafeRepository(
                    "selected session evidence is unavailable"
                )
            }
            return try Self.verifyFreshInventory(
                scope: scope,
                inventory: retainedInventory
            )
        }
        let fresh = try hydrateVerified(
            scope: hydrationScope
        )
        if plan.delta.reusableRepositoryIDs.isEmpty {
            guard hydrationScope == scope else {
                throw GitSafetyError.unsafeRepository(
                    "selected session hydration scope is incomplete"
                )
            }
            return fresh
        }
        guard let retainedInventory else {
            throw GitSafetyError.unsafeRepository(
                "retained selected evidence is unavailable"
            )
        }
        let merged = Self.mergeSessionInventory(
            scope: scope,
            reusableRepositoryIDs:
                plan.delta.reusableRepositoryIDs,
            retainedInventory: retainedInventory,
            freshInventory: fresh.inventory
        )
        return try Self.verifyFreshInventory(
            scope: scope,
            inventory: merged
        )
    }

    static func mergeSessionInventory(
        scope: ValidatedSelectedRepositoryScope,
        reusableRepositoryIDs: Set<String>,
        retainedInventory: RepositoryInventory,
        freshInventory: RepositoryInventory?
    ) -> RepositoryInventory {
        let retainedCards = Dictionary(
            uniqueKeysWithValues:
                retainedInventory.cards.map {
                    ($0.id, $0)
                }
        )
        let freshCards = Dictionary(
            uniqueKeysWithValues:
                (freshInventory?.cards ?? []).map {
                    ($0.id, $0)
                }
        )
        let cards = scope.repositories.compactMap {
            freshCards[$0.repositoryID]
                ?? (
                    reusableRepositoryIDs.contains(
                        $0.repositoryID
                    )
                        ? retainedCards[$0.repositoryID]
                        : nil
                )
        }
        return RepositoryInventory(
            cards: cards,
            onboardingProposals:
                freshInventory?.onboardingProposals ?? [],
            authorityFileIdentity:
                freshInventory?.authorityFileIdentity
                    ?? retainedInventory.authorityFileIdentity
        )
    }

    public static func sessionPlan(
        scope: ValidatedSelectedRepositoryScope,
        retainedScope:
            ValidatedSelectedRepositoryScope?,
        retainedRepositoryIDs: Set<String>
    ) -> SelectedRepositorySessionPlan {
        let delta = sessionDelta(
            scope: scope,
            retainedScope: retainedScope,
            retainedRepositoryIDs:
                retainedRepositoryIDs
        )
        let hydrationRepositories =
            scope.repositories.filter {
                delta.repositoryIDsToHydrate.contains(
                    $0.repositoryID
                )
            }
        let hydrationScope =
            hydrationRepositories.isEmpty
                ? nil
                : ValidatedSelectedRepositoryScope(
                    selectionGeneration:
                        scope.selectionGeneration,
                    policyDigest: scope.policyDigest,
                    catalogGeneration:
                        scope.catalogGeneration,
                    repositories:
                        hydrationRepositories,
                    governedRootRole: scope.governedRootRole
                )
        return SelectedRepositorySessionPlan(
            delta: delta,
            hydrationScope: hydrationScope
        )
    }

    public static func sessionDelta(
        scope: ValidatedSelectedRepositoryScope,
        retainedScope:
            ValidatedSelectedRepositoryScope?,
        retainedRepositoryIDs: Set<String>
    ) -> SelectedRepositorySessionDelta {
        guard let retainedScope else {
            return SelectedRepositorySessionDelta(
                reusableRepositoryIDs: [],
                repositoryIDsToHydrate:
                    scope.repositoryIDs,
                droppedRepositoryIDs: []
            )
        }
        let previousBindings = Dictionary(
            uniqueKeysWithValues:
                retainedScope.repositories.map {
                    ($0.repositoryID, $0)
                }
        )
        let canReusePolicy =
            retainedScope.policyDigest
                == scope.policyDigest
                && retainedScope.governedRootRole == scope.governedRootRole
        let reusable = Set(
            scope.repositories.compactMap {
                repository -> String? in
                guard canReusePolicy,
                      previousBindings[
                          repository.repositoryID
                      ] == repository,
                      retainedRepositoryIDs.contains(
                          repository.repositoryID
                      ) else {
                    return nil
                }
                return repository.repositoryID
            }
        )
        return SelectedRepositorySessionDelta(
            reusableRepositoryIDs: reusable,
            repositoryIDsToHydrate:
                scope.repositoryIDs.subtracting(reusable),
            droppedRepositoryIDs:
                retainedScope.repositoryIDs.subtracting(
                    scope.repositoryIDs
                )
        )
    }

    public static func verifyFreshInventory(
        scope: ValidatedSelectedRepositoryScope,
        inventory: RepositoryInventory
    ) throws -> VerifiedSelectedRepositoryInventory {
        VerifiedSelectedRepositoryInventory(
            capability:
                try VerifiedRepositoryAuthorityCapability(
                    scope: scope,
                    inventory: inventory
                ),
            inventory: inventory
        )
    }
}
