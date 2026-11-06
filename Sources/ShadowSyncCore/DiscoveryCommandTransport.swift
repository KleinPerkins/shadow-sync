import Foundation

/// A phase-bound caller adapter. Only a live custody context and verified
/// publisher construct it; saved selections or sealed intent do not.
final class DiscoveryCommandTransport {
    private weak var context: CommandCustodyContext?
    private let publisher: PublisherPolicyResources
    private let cancellation: CancellationToken
    init(context: CommandCustodyContext, publisher: PublisherPolicyResources, cancellation: CancellationToken) {
        self.context = context; self.publisher = publisher; self.cancellation = cancellation
    }
    func execute(policy: RepositoryDiscoveryCommandPolicy, candidate: RepositoryCandidate) throws -> CustodyRegistryResult {
        guard let context, !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else {
            throw SelectedRepositoryScopeError.policyUnavailable
        }
        try context.validatePhaseAdmission(account: policy.account); try policy.requireCandidate(candidate)
        let command = try context.prepareDiscovery(policy: policy, candidate: candidate,
                                                   publisher: publisher, cancellation: cancellation)
        let handle = try RetainedCleanupRegistry.shared.start(command)
        let observer = cancellation.observeCustodyCancellation(handle)
        defer { cancellation.removeCustodyCancellation(observer) }
        let result = handle.wait()
        if result.phase == .cleanupPending {
            context.close(); cancellation.closeFutureChildAdmissions()
            throw SelectedRepositoryScopeError.cleanupPending
        }
        guard !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else {
            throw SelectedRepositoryScopeError.policyUnavailable
        }
        try context.validatePhaseAdmission(account: policy.account); try policy.validate()
        return result
    }
}
