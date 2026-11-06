import Foundation

/// Authority for the single fixed policy command. Raw code, paths and decoded
/// identifiers cannot construct publisher resources or a host snapshot.
final class PolicyCommandAuthority: @unchecked Sendable {
    let snapshot: HostPolicySnapshot
    let publisher: PublisherPolicyResources
    let graph: QualifiedCommandGraph
    private let cancellation: CancellationToken?

    init(snapshot: HostPolicySnapshot, publisher: PublisherPolicyResources,
         helper: CustodyHelperExecutable, cancellation: CancellationToken? = nil) throws {
        self.snapshot = snapshot; self.publisher = publisher; self.cancellation = cancellation
        let contract = try QualifiedAWAContract.decode(publisher.contract)
        guard contract.releaseRevision == snapshot.binding.releaseRevision,
              contract.moduleSHA256 == snapshot.binding.module.sha256 else { throw PolicyHelperError.unavailable }
        try snapshot.revalidate(); try publisher.revalidate()
        // Absence of a release-qualified graph refuses before reservation or
        // helper spawn, rather than creating a predictable pending transaction.
        graph = try QualifiedCommandGraph.forHelper(kind: .policyClassify, helper: helper, publisher: publisher)
        try revalidate()
    }
    var admissionClosed: Bool { cancellation?.isCancelled == true || cancellation?.areFutureChildAdmissionsClosed == true }
    func revalidate() throws {
        guard !admissionClosed else { throw PolicyHelperError.unavailable }
        try snapshot.revalidate(); try graph.revalidate()
        guard !admissionClosed else { throw PolicyHelperError.unavailable }
    }
    func validate(input: Data, code: Data) throws {
        try PolicyCommandWire.validateRequest(input, bindingSHA256: snapshot.bindingSHA256)
        guard try code == PolicyCommandWire.resources(adapter: publisher.adapter, contract: publisher.contract) else {
            throw PolicyHelperError.unavailable
        }
        try revalidate()
    }
}
