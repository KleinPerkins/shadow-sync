import Foundation

/// Explicit validation policy, never a decoded flag or installation authority.
/// Every ordinary constructor/decoder defaults to production. Fixture profiles
/// exist only in the separately compiled signed-fixture executable and retain
/// their actual source/root/guardian owner through every validation.
enum InstallationValidationProfile: Equatable {
    case production
    #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
    case signedFixture(SignedInstallationFixtureContext.ReleaseProfile)
    #endif

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.production, .production): return true
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        case let (.signedFixture(a), .signedFixture(b)): return a === b
        default: return false
        #endif
        }
    }
    func validate(_ release: ReleaseIdentity) throws {
        switch self {
        case .production: try release.validate(requireProduction: true)
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        case let .signedFixture(profile): try profile.validate(release)
        #endif
        }
    }
    func validateCandidate(_ candidate: InstallationCandidate) throws {
        try validate(candidate.release)
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        if case let .signedFixture(profile) = self { try profile.validateCandidate(candidate) }
        #endif
    }
    func revalidate() throws {
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        if case let .signedFixture(profile) = self { try profile.revalidate() }
        #endif
    }
    var destinationAccount: EffectiveAccount { get throws {
        switch self {
        case .production: return try EffectiveAccount.current()
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        case let .signedFixture(profile): return try profile.destinationAccount
        #endif
        }
    } }
    var stateLocation: StateLocation { get throws {
        switch self {
        case .production: return try StateLocation.production()
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        case let .signedFixture(profile): return try profile.location
        #endif
        }
    } }
    func bindInstallationSlots(transactionID: String) throws {
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        if case let .signedFixture(profile) = self { try profile.bindInstallationSlots(transactionID: transactionID) }
        #endif
    }
    func inspectBundle(_ path: String) throws -> BundleArtifactIdentity {
        switch self {
        case .production: return try BundleArtifactIdentity.inspect(bundlePath: path, requireProduction: true)
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        case .signedFixture: return try BundleArtifactIdentity.inspect(bundlePath: path, installationProfile: self)
        #endif
        }
    }
    func validateBundlePath(_ path: String) throws {
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        if case let .signedFixture(profile) = self { try profile.validateBundlePath(path) }
        #endif
    }
    func validateDestinationAccount(_ account: EffectiveAccount, publisher: EffectiveAccount) throws {
        switch self {
        case .production:
            guard account == publisher, account == (try EffectiveAccount.current()) else { throw CustodyRecordError.fenced }
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        case let .signedFixture(profile): try profile.validateDestinationAccount(account, publisher: publisher)
        #endif
        }
    }
    func validateLocation(_ location: StateLocation) throws {
        switch self {
        case .production:
            guard location == (try StateLocation.production()) else { throw CustodyRecordError.fenced }
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        case let .signedFixture(profile): try profile.validateLocation(location)
        #endif
        }
    }
    func validateStateDescriptor(_ descriptor: Int32) throws {
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        if case let .signedFixture(profile) = self { try profile.validateStateDescriptor(descriptor) }
        #endif
    }
    /// A production caller cannot acquire fixture resources merely because they
    /// happen to exist in a signed bundle. The layout itself selects this roster.
    var additionalBundleResources: Set<String> {
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        if case .signedFixture = self {
            return ["Contents/Resources/signed-installation-fixture.json", "Contents/Resources/signed-installation-graph.json"]
        }
        #endif
        return []
    }
}
