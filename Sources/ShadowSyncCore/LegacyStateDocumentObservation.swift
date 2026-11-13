import Foundation
import ShadowSyncCatalog

/// Unauthenticated historical data only. No case is repository, publisher,
/// installation, lock or mutation authority. Refusal also retains opaque input.
/// There is deliberately no encoder or current-document conversion operation.
enum LegacyStateDocumentObservation: Equatable {
    struct DirectoryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        fileprivate init(device: UInt64, inode: UInt64) {
            self.device = device; self.inode = inode
        }
    }
    struct AuthorityRecord: Equatable {
        let repositoryID: String
        let canonicalRoot: String
        let rootIdentity: DirectoryIdentity
        let commonDirectoryIdentity: DirectoryIdentity
        let updatedAt: String
        fileprivate init(repositoryID: String, canonicalRoot: String, rootIdentity: DirectoryIdentity,
                         commonDirectoryIdentity: DirectoryIdentity, updatedAt: String) {
            self.repositoryID = repositoryID; self.canonicalRoot = canonicalRoot
            self.rootIdentity = rootIdentity; self.commonDirectoryIdentity = commonDirectoryIdentity
            self.updatedAt = updatedAt
        }
    }
    struct AuthorityDocument: Equatable {
        let originalBytes: Data
        let revision: UInt64
        // Retain input order. The historical typed reader sorted its result;
        // observation is not permission to rewrite or sort the original data.
        let records: [AuthorityRecord]
        fileprivate init(originalBytes: Data, revision: UInt64, records: [AuthorityRecord]) {
            self.originalBytes = originalBytes; self.revision = revision; self.records = records
        }
    }
    struct SelectionEntry: Equatable {
        let repositoryID: String
        let governedRoot: String
        // Preserve source spelling, including decomposed Unicode. Validation
        // uses the historical locator's canonical-composition semantics only
        // for its source-defined ordering/duplicate invariants.
        let components: [String]
        fileprivate init(repositoryID: String, governedRoot: String, components: [String]) {
            self.repositoryID = repositoryID; self.governedRoot = governedRoot; self.components = components
        }
    }
    struct SelectionDocument: Equatable {
        let originalBytes: Data
        let documentID: String
        let revision: UInt64
        let entries: [SelectionEntry]
        fileprivate init(originalBytes: Data, documentID: String, revision: UInt64, entries: [SelectionEntry]) {
            self.originalBytes = originalBytes; self.documentID = documentID
            self.revision = revision; self.entries = entries
        }
    }
    case authority(AuthorityDocument)
    case selection(SelectionDocument)
    case refused(originalBytes: Data)

    var originalBytes: Data {
        switch self {
        case .authority(let document): document.originalBytes
        case .selection(let document): document.originalBytes
        case .refused(let bytes): bytes
        }
    }
}

/// Pure byte parsing. Never follows, opens, resolves or otherwise probes input
/// paths/locators. Selection remains a preference, never canonical authority.
enum LegacyStateDocumentObserver {
    static let authoritySchema = "dev-main-sync-repository-authorities/v1"
    static let selectionSchema = "dev-main-sync-repository-selection-preferences/v1"
    // Both historical stores capped document input at exactly one MiB.
    // The closed legacy parser profile changes no existing reader budget.
    // Integer tokens only: historical Foundation decoding could accept some
    // decimal/exponent spellings such as 1.0 or 1e0. Those are conservatively
    // refused and preserved, never normalized to a new document.
    static let maximumBytes = 1_048_576

    static func observe(_ bytes: Data) -> LegacyStateDocumentObservation {
        do { return try parse(bytes) }
        catch { return .refused(originalBytes: bytes) }
    }

    private static func parse(_ bytes: Data) throws -> LegacyStateDocumentObservation {
        var parser = try PolicyWireParser(bytes, profile: .legacyStateDocument)
        let value = try parser.parse()
        guard case .object(let header) = value else { throw Invalid.document }
        if header["schema"] == .string(authoritySchema) {
            let object = try value.object(keys: ["schema", "revision", "records"])
            let revision = try authorityInteger(object["revision"])
            let records = try array(object["records"]).map { value in
                let row = try value.object(keys: ["repositoryID", "canonicalRoot", "rootIdentity",
                                                  "commonDirectoryIdentity", "updatedAt"])
                let id = try string(row["repositoryID"]), root = try string(row["canonicalRoot"])
                let updatedAt = try string(row["updatedAt"])
                // Same lexical checks as the source document; do not invent
                // stricter filesystem normalization or a timestamp grammar.
                guard id == id.lowercased(),
                      GitHubIdentity.parse("git@github.com:\(id).git")?.canonicalName == id,
                      root.hasPrefix("/"), !root.contains("\n"), !root.contains("\r"), !root.contains("\0"),
                      !updatedAt.isEmpty else { throw Invalid.document }
                return LegacyStateDocumentObservation.AuthorityRecord(repositoryID: id, canonicalRoot: root,
                    rootIdentity: try identity(row["rootIdentity"]),
                    commonDirectoryIdentity: try identity(row["commonDirectoryIdentity"]), updatedAt: updatedAt)
            }
            guard Set(records.map(\.repositoryID)).count == records.count else { throw Invalid.document }
            return .authority(.init(originalBytes: bytes, revision: revision, records: records))
        } else if header["schema"] == .string(selectionSchema) {
            let object = try value.object(keys: ["schema", "documentID", "revision", "entries"])
            let documentID = try string(object["documentID"]), revision = try unsigned(object["revision"])
            guard UUID(uuidString: documentID)?.uuidString.lowercased() == documentID,
                  revision > 0 else { throw Invalid.document }
            var validated: [LegacySelectionKey] = []
            let entries = try array(object["entries"]).map { value in
                let row = try value.object(keys: ["repositoryID", "locator"])
                let locator = try row["locator"]?.object(keys: ["governedRoot", "components"])
                guard let locator else { throw Invalid.document }
                let id = try string(row["repositoryID"]), root = try string(locator["governedRoot"])
                let components = try array(locator["components"]).map { try string($0) }
                // Historical comparison is separate from today's bytewise
                // locator policy. Only this private key is normalized; the
                // returned observation and original bytes stay untouched.
                validated.append(try LegacySelectionKey(repositoryID: id,
                    locator: LegacyLocatorKey(governedRoot: root, components: components)))
                return LegacyStateDocumentObservation.SelectionEntry(repositoryID: id,
                    governedRoot: root, components: components)
            }
            guard validated == validated.sorted(),
                  Set(validated.map(\.repositoryID)).count == validated.count,
                  Set(validated.map(\.locator)).count == validated.count else { throw Invalid.document }
            return .selection(.init(originalBytes: bytes, documentID: documentID, revision: revision, entries: entries))
        } else { throw Invalid.document }
    }

    // These private values reproduce historical syntax and comparison only.
    // They cannot be passed to current selection, policy or admission APIs.
    private struct LegacyLocatorKey: Hashable, Comparable {
        let governedRoot: String
        let components: [String]

        init(governedRoot: String, components: [String]) throws {
            guard !governedRoot.isEmpty, governedRoot.utf8.count <= 128,
                  !governedRoot.hasPrefix("/"),
                  governedRoot.rangeOfCharacter(from: .controlCharacters) == nil,
                  !governedRoot.contains("\\"), !governedRoot.contains("\0"),
                  !components.isEmpty, components.count <= 4 else { throw Invalid.document }
            let normalized = components.map { $0.precomposedStringWithCanonicalMapping }
            guard normalized.allSatisfy({ value in
                !value.isEmpty && value.utf8.count <= 255
                    && value != "." && value != ".." && !value.hasPrefix(".")
                    && !value.contains("/") && !value.contains("\\")
                    && value.rangeOfCharacter(from: .controlCharacters) == nil
            }) else { throw Invalid.document }
            self.governedRoot = governedRoot
            self.components = normalized
        }

        // Synthesized String equality/hash use canonical equivalence, as did
        // the historical value. Root length still uses its original bytes.
        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.governedRoot != rhs.governedRoot {
                return lhs.governedRoot.utf8.lexicographicallyPrecedes(rhs.governedRoot.utf8)
            }
            return lhs.components.joined(separator: "/").utf8.lexicographicallyPrecedes(
                rhs.components.joined(separator: "/").utf8)
        }
    }

    private struct LegacySelectionKey: Equatable, Comparable {
        let repositoryID: String
        let locator: LegacyLocatorKey

        init(repositoryID: String, locator: LegacyLocatorKey) throws {
            // This lexical ID predicate is unchanged from the historical one.
            guard RepositorySelectionPreferenceEntry.validRepositoryID(repositoryID) else {
                throw Invalid.document
            }
            self.repositoryID = repositoryID
            self.locator = locator
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.repositoryID == rhs.repositoryID
                ? lhs.locator < rhs.locator
                : lhs.repositoryID.utf8.lexicographicallyPrecedes(rhs.repositoryID.utf8)
        }
    }

    private enum Invalid: Error { case document }
    private static func string(_ value: PolicyWireValue?) throws -> String {
        guard case .string(let text) = value else { throw Invalid.document }; return text
    }
    private static func array(_ value: PolicyWireValue?) throws -> [PolicyWireValue] {
        guard case .array(let items) = value else { throw Invalid.document }; return items
    }
    private static func unsigned(_ value: PolicyWireValue?) throws -> UInt64 {
        guard case .unsigned(let number) = value else { throw Invalid.document }; return number
    }
    private static func authorityInteger(_ value: PolicyWireValue?) throws -> UInt64 {
        let number = try unsigned(value)
        // The historical raw check rejected negative NSNumber.int64Value;
        // typed UInt64 decoding and this strict integer grammar also apply.
        guard number <= UInt64(Int64.max) else { throw Invalid.document }; return number
    }
    private static func identity(_ value: PolicyWireValue?) throws -> LegacyStateDocumentObservation.DirectoryIdentity {
        guard let value else { throw Invalid.document }
        let object = try value.object(keys: ["device", "inode"])
        return .init(device: try authorityInteger(object["device"]), inode: try authorityInteger(object["inode"]))
    }
}
