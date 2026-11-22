import CryptoKit
import Darwin
import Foundation

public struct ReleaseIdentity: Codable, Equatable, Sendable {
    public static let schemaName = "shadow-sync-release/v2"
    public static let version = "0.10.0"
    public static let buildNumber = "15"
    public static let minimumSystemVersion = "26.0"
    public static let bundleIdentifier = "com.kleinperkins.shadow-sync"
    /// Public Developer ID publisher identity, independently pinned in source.
    /// Certificate renewals within this team do not change product ownership.
    public static let publisherTeamIdentifier = "J2V7GRV5CM"

    public let schema: String
    public let version: String
    public let buildNumber: String
    public let sourceRevision: String
    public let sourceInputSHA256: String
    public let releaseContractSHA256: String
    public let architecture: String
    public let minimumSystemVersion: String
    public let buildMode: String

    public init(
        version: String = Self.version,
        buildNumber: String = Self.buildNumber,
        sourceRevision: String,
        sourceInputSHA256: String,
        releaseContractSHA256: String,
        architecture: String,
        buildMode: String
    ) throws {
        schema = Self.schemaName
        self.version = version
        self.buildNumber = buildNumber
        self.sourceRevision = sourceRevision
        self.sourceInputSHA256 = sourceInputSHA256
        self.releaseContractSHA256 = releaseContractSHA256
        self.architecture = architecture
        minimumSystemVersion = Self.minimumSystemVersion
        self.buildMode = buildMode
        try validate()
    }

    public init(infoDictionary: [String: Any]) throws {
        func string(_ key: String) throws -> String {
            guard let value = infoDictionary[key] as? String else {
                throw ReleaseIdentityError.missingMetadata(key)
            }
            return value
        }
        guard try string("CFBundleIdentifier") == Self.bundleIdentifier,
              try string("CFBundleExecutable") == "ShadowSync",
              !LegacyInstallationRelease.containsMetadata(in: infoDictionary),
              Set(infoDictionary.keys.filter { $0.hasPrefix("ShadowSync") }) == Set([
                "ShadowSyncReleaseSchema", "ShadowSyncSourceRevision", "ShadowSyncSourceInputSHA256",
                "ShadowSyncReleaseContractSHA256", "ShadowSyncArchitecture", "ShadowSyncBuildMode",
              ]) else {
            throw ReleaseIdentityError.invalidMetadata
        }
        schema = try string("ShadowSyncReleaseSchema")
        version = try string("CFBundleShortVersionString")
        buildNumber = try string("CFBundleVersion")
        sourceRevision = try string("ShadowSyncSourceRevision")
        sourceInputSHA256 = try string("ShadowSyncSourceInputSHA256")
        releaseContractSHA256 = try string("ShadowSyncReleaseContractSHA256")
        architecture = try string("ShadowSyncArchitecture")
        minimumSystemVersion = try string("LSMinimumSystemVersion")
        buildMode = try string("ShadowSyncBuildMode")
        try validate()
    }

    public static func load(bundlePath: String) throws -> ReleaseIdentity {
        let plist = URL(fileURLWithPath: bundlePath)
            .appendingPathComponent("Contents/Info.plist").path
        guard let dictionary = NSDictionary(contentsOfFile: plist) as? [String: Any] else {
            throw ReleaseIdentityError.invalidInfoPlist
        }
        return try ReleaseIdentity(infoDictionary: dictionary)
    }

    public func validate(requireProduction: Bool = false) throws {
        guard schema == Self.schemaName,
              let semanticVersion = Self.semanticVersion(version),
              !semanticVersion.lexicographicallyPrecedes([0, 10, 0]),
              let observedBuild = Self.canonicalInteger(buildNumber),
              observedBuild >= 15,
              minimumSystemVersion == Self.minimumSystemVersion,
              Self.isHex(sourceRevision, count: 40),
              Self.isHex(sourceInputSHA256, count: 64),
              Self.isHex(releaseContractSHA256, count: 64),
              architecture == "arm64",
              ["production", "testing"].contains(buildMode),
              !requireProduction || (
                buildMode == "production"
                    && sourceRevision != String(repeating: "0", count: 40)
                    && sourceInputSHA256 != String(repeating: "0", count: 64)
                    && releaseContractSHA256 != String(repeating: "0", count: 64)
              ) else {
            throw ReleaseIdentityError.invalidMetadata
        }
    }

    public func sameInstallContract(as other: ReleaseIdentity) -> Bool {
        // Exact revision is part of distributed provenance even if source bytes
        // happen to agree. A matching metadata record is not publisher proof.
        self == other
    }

    /// Metadata ordering only. The caller must separately authenticate publisher,
    /// artifact bytes and channel authorization before installing an update.
    public func isForwardVersion(from installed: ReleaseIdentity) -> Bool {
        guard (try? validate(requireProduction: true)) != nil,
              (try? installed.validate(requireProduction: true)) != nil,
              let candidateBuild = Self.canonicalInteger(buildNumber),
              let installedBuild = Self.canonicalInteger(installed.buildNumber),
              let candidateVersion = Self.semanticVersion(version),
              let installedVersion = Self.semanticVersion(installed.version) else { return false }
        return candidateBuild > installedBuild
            && !candidateVersion.lexicographicallyPrecedes(installedVersion)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, version, buildNumber, sourceRevision, sourceInputSHA256
        case releaseContractSHA256, architecture, minimumSystemVersion, buildMode
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let observed = try decoder.container(keyedBy: AnyKey.self)
        guard Set(observed.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw ReleaseIdentityError.invalidMetadata
        }
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        schema = try fields.decode(String.self, forKey: .schema)
        version = try fields.decode(String.self, forKey: .version)
        buildNumber = try fields.decode(String.self, forKey: .buildNumber)
        sourceRevision = try fields.decode(String.self, forKey: .sourceRevision)
        sourceInputSHA256 = try fields.decode(String.self, forKey: .sourceInputSHA256)
        releaseContractSHA256 = try fields.decode(String.self, forKey: .releaseContractSHA256)
        architecture = try fields.decode(String.self, forKey: .architecture)
        minimumSystemVersion = try fields.decode(String.self, forKey: .minimumSystemVersion)
        buildMode = try fields.decode(String.self, forKey: .buildMode)
        try validate()
    }

    /// Use for a standalone JSON metadata boundary; validates duplicate keys
    /// before Foundation's keyed decoder can collapse them.
    public static func decode(_ data: Data) throws -> ReleaseIdentity {
        guard data.count <= 16_384 else { throw ReleaseIdentityError.invalidMetadata }
        var parser = try PolicyWireParser(data, profile: .configuration)
        _ = try parser.parse().object(keys: Set(CodingKeys.allCases.map(\.rawValue)))
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private static func canonicalInteger(_ value: String) -> UInt64? {
        // Bound inputs independently of the producing build. Future releases
        // remain readable; distribution allocates each build exactly once.
        guard !value.isEmpty, value.utf8.count <= 10,
              value == "0" || value.first != "0",
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              let integer = UInt64(value), integer <= 2_147_483_647 else { return nil }
        return integer
    }

    private static func semanticVersion(_ value: String) -> [UInt64]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { canonicalInteger(String($0)) }
        return numbers.count == 3 ? numbers : nil
    }

    private static func isHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public struct BundleArtifactIdentity: Equatable, Sendable {
    public let release: ReleaseIdentity
    public let canonicalSHA256: String
    public let inventory: [String]

    public static func inspect(
        bundlePath: String,
        requireProduction: Bool = false
    ) throws -> BundleArtifactIdentity {
        try inspect(bundlePath: bundlePath, requireProduction: requireProduction, layoutOverride: nil)
    }

    private static func inspect(bundlePath: String, requireProduction: Bool,
                                layoutOverride: PublisherBundleLayout?) throws -> BundleArtifactIdentity {
        var rootInfo = stat()
        guard lstat(bundlePath, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              rootInfo.st_uid == geteuid(),
              rootInfo.st_flags == 0,
              hasOnlyPermittedXattrs(bundlePath) else {
            throw ReleaseIdentityError.unsafeBundle(bundlePath)
        }
        let release = try ReleaseIdentity.load(bundlePath: bundlePath)
        try release.validate(requireProduction: requireProduction)
        let publisherLayout = try layoutOverride ?? PublisherBundleLayout.captureIfPresent(bundlePath)
        #if !SHADOW_SYNC_TESTING
        guard !requireProduction || publisherLayout != nil else { throw ReleaseIdentityError.unsafeBundle(bundlePath) }
        #endif
        _ = try publisherLayout?.validateNode("")
        var observed: Set<String> = [""]

        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: bundlePath),
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            throw ReleaseIdentityError.unsafeBundle(bundlePath)
        }
        var records: [String] = [
            "d\u{0}.\u{0}\(rootInfo.st_mode & 0o7777)\u{0}0\u{0}-",
        ]
        let root = bundlePath + "/"
        for case let url as URL in enumerator {
            let path = url.path
            guard path.hasPrefix(root) else {
                throw ReleaseIdentityError.unsafeBundle(path)
            }
            let relative = String(path.dropFirst(root.count))
            guard !relative.isEmpty, !relative.contains("\n"), !relative.contains("\0") else {
                throw ReleaseIdentityError.unsafeBundle(relative)
            }
            var info = stat()
            guard lstat(path, &info) == 0,
                  info.st_uid == geteuid(),
                  info.st_flags == 0,
                  hasOnlyPermittedXattrs(path) else {
                throw ReleaseIdentityError.unsafeBundle(relative)
            }
            let target = try publisherLayout?.validateNode(relative)
            guard observed.insert(relative).inserted else { throw ReleaseIdentityError.unsafeBundle(relative) }
            let type = info.st_mode & S_IFMT
            let mode = info.st_mode & 0o7777
            if type == S_IFDIR {
                records.append("d\u{0}\(relative)\u{0}\(mode)\u{0}0\u{0}-")
            } else if type == S_IFREG, info.st_nlink == 1 {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let digest = SHA256.hash(data: data).hex
                records.append("f\u{0}\(relative)\u{0}\(mode)\u{0}\(info.st_size)\u{0}\(digest)")
            } else if type == S_IFLNK, let target {
                let bytes = Data(target.utf8)
                records.append("l\u{0}\(relative)\u{0}\(mode)\u{0}\(bytes.count)\u{0}\(SHA256.hash(data: bytes).hex)")
            } else {
                throw ReleaseIdentityError.unsafeBundle(relative)
            }
        }
        try publisherLayout?.requireComplete(observed)
        try publisherLayout?.revalidate()
        records.sort()
        let bytes = Data((records.joined(separator: "\u{0}") + "\u{0}").utf8)
        return BundleArtifactIdentity(
            release: release,
            canonicalSHA256: SHA256.hash(data: bytes).hex,
            inventory: records
        )
    }

    #if SHADOW_SYNC_TESTING
    static func testingInspect(bundlePath: String, layout: PolicyRuntimeLayout) throws -> BundleArtifactIdentity {
        try inspect(bundlePath: bundlePath, requireProduction: true,
                    layoutOverride: PublisherBundleLayout.testing(bundlePath: bundlePath, layout: layout))
    }
    #endif

    static func hasOnlyPermittedXattrs(_ path: String) -> Bool {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return false }
        if size == 0 { return true }
        var bytes = [CChar](repeating: 0, count: size)
        let read = bytes.withUnsafeMutableBufferPointer {
            listxattr(path, $0.baseAddress, size, XATTR_NOFOLLOW)
        }
        guard read == size else { return false }
        let names = bytes.split(separator: 0).map {
            String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return !names.isEmpty && Set(names).isSubset(of: ["com.apple.provenance", "com.apple.quarantine"])
    }
}

public enum ReleaseIdentityError: Error, CustomStringConvertible {
    case missingMetadata(String)
    case invalidMetadata
    case invalidInfoPlist
    case unsafeBundle(String)

    public var description: String {
        switch self {
        case let .missingMetadata(key): return "release metadata is missing \(key)"
        case .invalidMetadata: return "release metadata is invalid"
        case .invalidInfoPlist: return "release Info.plist is invalid"
        case let .unsafeBundle(path): return "release bundle inventory is unsafe: \(path)"
        }
    }
}

private extension Digest {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
