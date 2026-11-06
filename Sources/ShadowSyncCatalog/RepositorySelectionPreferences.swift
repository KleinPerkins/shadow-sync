import Foundation

public let shadowSyncSelectionPreferenceSchema =
    "shadow-sync-repository-selection-preferences/v1"

public enum RepositorySelectionValueError: Error, Equatable, Sendable {
    case invalidRepositoryID
    case invalidLocator
    case invalidDocument
}

public struct RepositorySelectionLocator:
    Codable, Equatable, Hashable, Sendable, Comparable {
    public let governedRoot: String
    public let components: [String]

    public init(governedRoot: String, components: [String]) throws {
        guard Self.validRoot(governedRoot),
              !components.isEmpty,
              components.count <= 4,
              components.allSatisfy(Self.validComponent) else {
            throw RepositorySelectionValueError.invalidLocator
        }
        self.governedRoot = governedRoot
        // Selection authority is lexical. Do not rewrite a spelling after its
        // exact bytes have been classified by the owner policy.
        self.components = components
    }

    public var relativePath: String {
        components.joined(separator: "/")
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.governedRoot.utf8.elementsEqual(rhs.governedRoot.utf8)
            && lhs.components.count == rhs.components.count
            && zip(lhs.components, rhs.components).allSatisfy {
                $0.utf8.elementsEqual($1.utf8)
            }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Array(governedRoot.utf8))
        hasher.combine(components.count)
        for component in components { hasher.combine(Array(component.utf8)) }
    }

    public static func < (
        lhs: RepositorySelectionLocator,
        rhs: RepositorySelectionLocator
    ) -> Bool {
        if !lhs.governedRoot.utf8.elementsEqual(rhs.governedRoot.utf8) {
            return lhs.governedRoot.utf8.lexicographicallyPrecedes(
                rhs.governedRoot.utf8
            )
        }
        return lhs.relativePath.utf8.lexicographicallyPrecedes(
            rhs.relativePath.utf8
        )
    }

    private static func validRoot(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && !value.hasPrefix("/")
            && value.rangeOfCharacter(from: .controlCharacters) == nil
            && !value.contains("\\")
            && !value.contains("\0")
    }

    private static func validComponent(_ value: String) -> Bool {
        return !value.isEmpty
            && value.utf8.count <= 255
            && value != "."
            && value != ".."
            && !value.hasPrefix(".")
            && !value.contains("/")
            && !value.contains("\\")
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private enum CodingKeys: String, CodingKey {
        case governedRoot
        case components
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.allKeys.count == 2 else {
            throw RepositorySelectionValueError.invalidLocator
        }
        try self.init(
            governedRoot: values.decode(String.self, forKey: .governedRoot),
            components: values.decode([String].self, forKey: .components)
        )
    }
}

public struct RepositorySelectionPreferenceEntry:
    Codable, Equatable, Hashable, Sendable, Comparable {
    public let repositoryID: String
    public let locator: RepositorySelectionLocator

    public init(
        repositoryID: String,
        locator: RepositorySelectionLocator
    ) throws {
        guard Self.validRepositoryID(repositoryID) else {
            throw RepositorySelectionValueError.invalidRepositoryID
        }
        self.repositoryID = repositoryID
        self.locator = locator
    }

    public static func < (
        lhs: RepositorySelectionPreferenceEntry,
        rhs: RepositorySelectionPreferenceEntry
    ) -> Bool {
        lhs.repositoryID == rhs.repositoryID
            ? lhs.locator < rhs.locator
            : lhs.repositoryID.utf8.lexicographicallyPrecedes(
                rhs.repositoryID.utf8
            )
    }

    public static func validRepositoryID(_ value: String) -> Bool {
        if value.hasPrefix("local-") {
            return value.count == 70
                && value.dropFirst(6).allSatisfy(\.isHexDigit)
                && value == value.lowercased()
        }
        guard value == value.lowercased(),
              value.utf8.count <= 256,
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              !value.contains("@"),
              !value.contains(":"),
              !value.contains("\\"),
              !value.contains("..") else {
            return false
        }
        let pieces = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return pieces.count == 2
            && pieces.allSatisfy {
                !$0.isEmpty
                    && $0.allSatisfy {
                        $0.isLetter || $0.isNumber
                            || $0 == "-" || $0 == "_" || $0 == "."
                    }
            }
    }

    private enum CodingKeys: String, CodingKey {
        case repositoryID
        case locator
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.allKeys.count == 2 else {
            throw RepositorySelectionValueError.invalidDocument
        }
        try self.init(
            repositoryID: values.decode(String.self, forKey: .repositoryID),
            locator: values.decode(
                RepositorySelectionLocator.self,
                forKey: .locator
            )
        )
    }
}

public struct RepositorySelectionPreferenceDocument:
    Codable, Equatable, Sendable {
    public let schema: String
    public let documentID: String
    public let revision: UInt64
    public let entries: [RepositorySelectionPreferenceEntry]

    public init(
        documentID: String,
        revision: UInt64,
        entries: [RepositorySelectionPreferenceEntry]
    ) throws {
        let canonicalUUID = UUID(uuidString: documentID)?
            .uuidString.lowercased()
        guard canonicalUUID == documentID,
              revision > 0,
              entries == entries.sorted(),
              Set(entries.map(\.repositoryID)).count == entries.count,
              Set(entries.map(\.locator)).count == entries.count else {
            throw RepositorySelectionValueError.invalidDocument
        }
        schema = shadowSyncSelectionPreferenceSchema
        self.documentID = documentID
        self.revision = revision
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case documentID
        case revision
        case entries
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.allKeys.count == 4,
              try values.decode(String.self, forKey: .schema)
                == shadowSyncSelectionPreferenceSchema else {
            throw RepositorySelectionValueError.invalidDocument
        }
        try self.init(
            documentID: values.decode(String.self, forKey: .documentID),
            revision: values.decode(UInt64.self, forKey: .revision),
            entries: values.decode(
                [RepositorySelectionPreferenceEntry].self,
                forKey: .entries
            )
        )
    }
}

public struct RepositorySelectionIntent: Equatable, Sendable {
    public let generation: UInt64
    public let policyDigest: String
    public let rootIdentities:
        [String: RepositorySelectionCatalogIdentity]
    public let repositoryIdentities:
        [RepositorySelectionPreferenceEntry:
            RepositorySelectionCatalogIdentity]
    public let entries: [RepositorySelectionPreferenceEntry]

    public init(
        catalog: RepositorySelectionCatalog,
        entries: [RepositorySelectionPreferenceEntry]
    ) throws {
        guard !entries.isEmpty,
              entries == entries.sorted(),
              Set(entries.map(\.repositoryID)).count == entries.count,
              Set(entries.map(\.locator)).count == entries.count,
              entries.allSatisfy({ entry in
                  catalog.candidates.contains {
                      $0.id == entry.repositoryID
                          && $0.locator == entry.locator
                          && $0.isVisible
                          && $0.isEligible
                          && $0.catalogGeneration
                              == catalog.generation
                          && catalog.rootIdentities[
                              entry.locator.governedRoot
                          ] == $0.catalogRootIdentity
                  }
              }) else {
            throw RepositorySelectionValueError.invalidDocument
        }
        generation = catalog.generation
        policyDigest = catalog.policyDigest
        rootIdentities = catalog.rootIdentities
        let selectedIdentities = try entries.map { entry in
                guard let candidate = catalog.candidates.first(where: {
                    $0.id == entry.repositoryID
                        && $0.locator == entry.locator
                }),
                let identity = candidate.catalogRepositoryIdentity else {
                    throw RepositorySelectionValueError.invalidDocument
                }
                return (entry, identity)
        }
        repositoryIdentities = Dictionary(
            uniqueKeysWithValues: selectedIdentities
        )
        self.entries = entries
    }
}
