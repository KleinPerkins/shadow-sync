import Foundation

/// Read-only metadata for the bounded build-14 migration path. This type cannot
/// become current ReleaseIdentity and does not verify a signature, process,
/// source receipt, state authority or authorization to migrate the installation.
public struct LegacyInstallationRelease: Equatable, Sendable {
    public static let bundleIdentifier = "com.kleinperkins.dev-main-sync"
    public static let schemaName = "dev-main-sync-release/v1"
    public let sourceRevision: String
    public let sourceInputSHA256: String
    public let metadataContractSHA256: String

    static func containsMetadata(in dictionary: [String: Any]) -> Bool {
        dictionary.keys.contains { $0.hasPrefix("DevMainSync") }
    }

    public init(infoDictionary: [String: Any]) throws {
        func string(_ key: String) throws -> String {
            guard let value = infoDictionary[key] as? String else {
                throw ReleaseIdentityError.invalidMetadata
            }
            return value
        }
        guard !infoDictionary.keys.contains(where: { $0.hasPrefix("ShadowSync") }),
              Set(infoDictionary.keys.filter { $0.hasPrefix("DevMainSync") }) == Set([
                "DevMainSyncReleaseSchema", "DevMainSyncArchitecture", "DevMainSyncBuildMode",
                "DevMainSyncSourceRevision", "DevMainSyncSourceInputSHA256", "DevMainSyncMetadataContractSHA256",
              ]),
              try string("CFBundleIdentifier") == Self.bundleIdentifier,
              try string("CFBundleExecutable") == "ShadowSync",
              try string("CFBundleShortVersionString") == "0.9.0",
              try string("CFBundleVersion") == "14",
              try string("LSMinimumSystemVersion") == "26.0",
              try string("DevMainSyncReleaseSchema") == Self.schemaName,
              try string("DevMainSyncArchitecture") == "arm64",
              try string("DevMainSyncBuildMode") == "production" else {
            throw ReleaseIdentityError.invalidMetadata
        }
        sourceRevision = try string("DevMainSyncSourceRevision")
        sourceInputSHA256 = try string("DevMainSyncSourceInputSHA256")
        metadataContractSHA256 = try string("DevMainSyncMetadataContractSHA256")
        for (value, length) in [(sourceRevision, 40), (sourceInputSHA256, 64), (metadataContractSHA256, 64)] {
            guard value.utf8.count == length,
                  value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  value != String(repeating: "0", count: length) else {
                throw ReleaseIdentityError.invalidMetadata
            }
        }
    }
}
