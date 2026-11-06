import Foundation

/// Bound configuration, never repository-access authority. It is deliberately
/// not Codable: a request, saved plan or display label cannot create this role.
public struct GovernedRootRole: Equatable, Sendable {
    public let repositoryID: String
    public let policyDigest: String

    init(snapshot: HostPolicySnapshot) throws {
        try snapshot.revalidate()
        repositoryID = snapshot.projection.rootRepositoryID
        policyDigest = snapshot.admissionSHA256
    }

    private init(repositoryID: String, policyDigest: String) {
        self.repositoryID = repositoryID
        self.policyDigest = policyDigest
    }

    #if SHADOW_SYNC_TESTING
    public static func testing(
        repositoryID: String = "fixture-owner/governed-root",
        policyDigest: String = String(repeating: "0", count: 64)
    ) -> GovernedRootRole {
        GovernedRootRole(repositoryID: repositoryID, policyDigest: policyDigest)
    }
    #endif
}
