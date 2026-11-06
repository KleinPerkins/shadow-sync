@testable import ShadowSyncCore

#if SHADOW_SYNC_TESTING
func compileTestingSeams(root: String, remote: String) throws {
    let origin = "git@github.com:fixture-owner/fixture-repo.git"
    _ = try StateLocation.isolated(root: root)
    _ = try EffectiveAccount.isolated(homeDirectory: root)
    _ = try TransportMapping(
        logicalURL: origin,
        localRepositoryPath: remote,
        containmentRoot: root
    )
}
#else
func compileProductionSurface() {
    _ = GitHubIdentity.parse("git@github.com:fixture-owner/fixture-repo.git")
    _ = CancellationToken()
}
#endif
