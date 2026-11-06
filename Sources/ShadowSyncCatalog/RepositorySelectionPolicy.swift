import Foundation

public enum RepositorySelectionPolicyDisposition:
    String, Codable, Equatable, Sendable {
    case writable
    case excluded
    case readOnlyReference
    case artifact
    case permanentNoTouch

    public var isSelectable: Bool {
        self == .writable
    }

    public var disabledReason: String? {
        switch self {
        case .writable:
            return nil
        case .excluded:
            return "Excluded by the current host policy."
        case .readOnlyReference:
            return "Read-only reference; operations are unavailable."
        case .artifact:
            return "Generated or temporary artifacts are not repositories."
        case .permanentNoTouch:
            return "Permanently protected; ShadowSync cannot operate here."
        }
    }
}

public struct RepositorySelectionPolicy: Equatable, Sendable {
    public let shelfPaths: [[String]]
    public let excludedPaths: [String]
    public let readOnlyPaths: [String]
    public let artifactPaths: [String]
    public let writablePaths: [String]
    public let permanentNoTouchRepositoryIDs: Set<String>
    public let digest: String

    public init(
        shelfPaths: [[String]],
        excludedPaths: [String],
        readOnlyPaths: [String],
        artifactPaths: [String],
        writablePaths: [String] = [],
        permanentNoTouchRepositoryIDs: Set<String>,
        digest: String
    ) throws {
        guard !shelfPaths.isEmpty,
              shelfPaths.count <= 33, // At most32 projected shelves plus the governed-root role.
              shelfPaths.allSatisfy({
                  !$0.isEmpty && $0.count <= 3
                      && $0.allSatisfy(Self.validComponent)
              }),
              (excludedPaths + readOnlyPaths + artifactPaths
                + writablePaths)
                .allSatisfy(Self.validPattern),
              digest.count == 64,
              digest.allSatisfy(\.isHexDigit) else {
            throw RepositorySelectionValueError.invalidDocument
        }
        self.shelfPaths = shelfPaths
        self.excludedPaths = excludedPaths.sorted()
        self.readOnlyPaths = readOnlyPaths.sorted()
        self.artifactPaths = artifactPaths.sorted()
        self.writablePaths = writablePaths.sorted()
        self.permanentNoTouchRepositoryIDs =
            Set(permanentNoTouchRepositoryIDs.map {
                $0.lowercased()
            })
        self.digest = digest.lowercased()
    }

    public func disposition(
        relativePath: String,
        repositoryID: String? = nil
    ) -> RepositorySelectionPolicyDisposition {
        if let repositoryID,
           permanentNoTouchRepositoryIDs.contains(repositoryID.lowercased()) {
            return .permanentNoTouch
        }
        if artifactPaths.contains(where: {
            Self.matches(relativePath, pattern: $0)
        }) {
            return .artifact
        }
        if writablePaths.contains(relativePath) {
            return .writable
        }
        if readOnlyPaths.contains(where: {
            Self.matches(relativePath, pattern: $0)
        }) {
            return .readOnlyReference
        }
        if excludedPaths.contains(where: {
            Self.matches(relativePath, pattern: $0)
        }) {
            return .excluded
        }
        return .writable
    }

    public func isArtifactOrHiddenPrefix(_ components: [String]) -> Bool {
        guard !components.contains(where: { $0.hasPrefix(".") }) else {
            return true
        }
        let path = components.joined(separator: "/")
        return disposition(relativePath: path) == .artifact
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.hasPrefix(".")
            && !value.contains("/")
            && !value.contains("\\")
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func validPattern(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              !value.contains("\\"),
              !value.contains("//"),
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            return false
        }
        let trimmed = value.hasSuffix("/*")
            ? String(value.dropLast(2)) : value
        return trimmed == "."
            || trimmed.split(separator: "/").allSatisfy {
                validComponent(String($0))
            }
    }

    private static func matches(_ path: String, pattern: String) -> Bool {
        if pattern == "." {
            return path == "."
        }
        if pattern.hasSuffix("/*") {
            let prefix = String(pattern.dropLast(2))
            return path == prefix || path.hasPrefix(prefix + "/")
        }
        return path == pattern
    }
}
