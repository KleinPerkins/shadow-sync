import CryptoKit
import Darwin
import Foundation

public struct RepositorySelectionCatalogLimits: Equatable, Sendable {
    public let governedRoots: Int
    public let relativeDepth: Int
    public let directoryEntries: Int
    public let directoriesOpened: Int
    public let filesOpened: Int
    public let aggregateBytes: Int
    public let directConfigBytes: Int
    public let candidateRows: Int
    public let elapsedNanoseconds: UInt64

    public init(
        governedRoots: Int = 8,
        relativeDepth: Int = 4,
        directoryEntries: Int = 4_096,
        directoriesOpened: Int = 1_024,
        filesOpened: Int = 512,
        aggregateBytes: Int = 2_097_152,
        directConfigBytes: Int = 65_536,
        candidateRows: Int = 512,
        elapsedNanoseconds: UInt64 = 750_000_000
    ) {
        self.governedRoots = governedRoots
        self.relativeDepth = relativeDepth
        self.directoryEntries = directoryEntries
        self.directoriesOpened = directoriesOpened
        self.filesOpened = filesOpened
        self.aggregateBytes = aggregateBytes
        self.directConfigBytes = directConfigBytes
        self.candidateRows = candidateRows
        self.elapsedNanoseconds = elapsedNanoseconds
    }
}

public struct RepositorySelectionCatalogIdentity:
    Codable, Equatable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let owner: UInt32

    public init(device: UInt64, inode: UInt64, owner: UInt32) {
        self.device = device
        self.inode = inode
        self.owner = owner
    }

    init(_ info: stat) {
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
        owner = UInt32(info.st_uid)
    }
}

public struct RepositorySelectionCatalogRoot: Sendable {
    public let logicalKey: String
    public let descriptor: Int32
    public let identity: RepositorySelectionCatalogIdentity

    public init(
        logicalKey: String,
        descriptor: Int32,
        identity: RepositorySelectionCatalogIdentity
    ) throws {
        guard !logicalKey.isEmpty,
              !logicalKey.hasPrefix("/"),
              !logicalKey.contains("\0"),
              descriptor >= 0 else {
            throw RepositorySelectionValueError.invalidLocator
        }
        self.logicalKey = logicalKey
        self.descriptor = descriptor
        self.identity = identity
    }
}

public enum RepositorySelectionOriginHintSource:
    String, Codable, Equatable, Sendable {
    case directConfig
    case unavailable
}

public enum RepositorySelectionSection:
    String, Codable, Equatable, Sendable {
    case available
    case canonicalRootRequired
    case unavailable
    case excluded
    case protected
}

public struct RepositorySelectionAlternative:
    Equatable, Sendable {
    public let locator: RepositorySelectionLocator
    public let compactLocation: String
    public let repositoryIdentity: RepositorySelectionCatalogIdentity
    public let commonDirectoryIdentity: RepositorySelectionCatalogIdentity
    public let rawOrigin: String
}

public struct RepositorySelectionCandidate:
    Equatable, Identifiable, Sendable {
    public let id: String
    public let locator: RepositorySelectionLocator
    public let displayLabel: String
    public let compactLocation: String
    public let policyDisposition: RepositorySelectionPolicyDisposition
    public let isVisible: Bool
    public let isEligible: Bool
    public let disabledReason: String?
    public let advisoryOrigin: String?
    public let advisoryOriginSource: RepositorySelectionOriginHintSource
    public let catalogRootIdentity: RepositorySelectionCatalogIdentity
    public let catalogRepositoryIdentity:
        RepositorySelectionCatalogIdentity?
    public let catalogGeneration: UInt64
    public let isDefaultSelected: Bool
    public let section: RepositorySelectionSection
    public let alternatives: [RepositorySelectionAlternative]
    public let canonicalRootRequired: Bool

    public var preferenceEntry: RepositorySelectionPreferenceEntry {
        get throws {
            try RepositorySelectionPreferenceEntry(
                repositoryID: id,
                locator: locator
            )
        }
    }
}

public struct RepositorySelectionCatalogCounters:
    Equatable, Sendable {
    public internal(set) var directoryEntries = 0
    public internal(set) var directoriesOpened = 0
    public internal(set) var filesOpened = 0
    public internal(set) var aggregateBytes = 0
    public internal(set) var candidateRows = 0
}

public struct RepositorySelectionCatalog: Equatable, Sendable {
    public let generation: UInt64
    public let policyDigest: String
    public let rootIdentities:
        [String: RepositorySelectionCatalogIdentity]
    public let candidates: [RepositorySelectionCandidate]
    public let unresolvedDefaults: [RepositorySelectionPreferenceEntry]
    public let counters: RepositorySelectionCatalogCounters
    public let elapsedNanoseconds: UInt64
}

public enum RepositorySelectionCatalogDegradation:
    String, Equatable, Sendable {
    case tooManyRoots
    case depthLimit
    case directoryEntryLimit
    case directoryOpenLimit
    case fileOpenLimit
    case aggregateByteLimit
    case rowLimit
    case deadline
    case policyUnavailable
    case cleanupPending
    case rootChanged
    case unsafeEntry

    public var operatorExplanation: String {
        switch self {
        case .tooManyRoots:
            return "Too many governed roots are configured."
        case .depthLimit:
            return "A configured shelf exceeds the safe traversal depth."
        case .directoryEntryLimit:
            return "The repository catalog contains too many directory entries."
        case .directoryOpenLimit:
            return "The repository catalog requires too many directory opens."
        case .fileOpenLimit:
            return "The repository catalog requires too many file opens."
        case .aggregateByteLimit:
            return "The repository catalog configuration is too large."
        case .rowLimit:
            return "The repository catalog contains too many rows."
        case .deadline:
            return "The repository catalog did not finish within its safety deadline."
        case .cleanupPending:
            return "Repository policy work is still stopping. Wait for recovery before continuing."
        case .policyUnavailable:
            return "The current repository policy could not be read safely."
        case .rootChanged:
            return "A governed repository root changed while it was catalogued."
        case .unsafeEntry:
            return "An unsafe repository entry prevented a complete catalog."
        }
    }
}

public struct RepositorySelectionCatalogResult: Equatable, Sendable {
    public let catalog: RepositorySelectionCatalog
    public let degradedReason: RepositorySelectionCatalogDegradation?

    public var isComplete: Bool {
        degradedReason == nil
    }
}

#if SHADOW_SYNC_TESTING
public extension RepositorySelectionCatalogResult {
    static func testingChooser(rowCount: Int) throws
        -> RepositorySelectionCatalogResult {
        guard (1...512).contains(rowCount) else {
            throw RepositorySelectionValueError.invalidDocument
        }
        let identity = RepositorySelectionCatalogIdentity(
            device: 1,
            inode: 1,
            owner: UInt32(geteuid())
        )
        let candidates = try (0..<rowCount).map { index in
            let locator = try RepositorySelectionLocator(
                governedRoot: "fixture",
                components: [
                    "personal",
                    String(format: "repository-%03d", index),
                ]
            )
            return RepositorySelectionCandidate(
                id: String(format: "fixture/repository-%03d", index),
                locator: locator,
                displayLabel:
                    String(format: "fixture/repository-%03d", index),
                compactLocation:
                    "fixture/" + locator.relativePath,
                policyDisposition: .writable,
                isVisible: true,
                isEligible: true,
                disabledReason: nil,
                advisoryOrigin:
                    "git@github.com:fixture/"
                    + String(format: "repository-%03d.git", index),
                advisoryOriginSource: .directConfig,
                catalogRootIdentity: identity,
                catalogRepositoryIdentity: identity,
                catalogGeneration: 1,
                isDefaultSelected: index == 0,
                section: .available,
                alternatives: [
                    RepositorySelectionAlternative(
                        locator: locator,
                        compactLocation:
                            "fixture/" + locator.relativePath,
                        repositoryIdentity: identity,
                        commonDirectoryIdentity: identity,
                        rawOrigin:
                            "git@github.com:fixture/"
                                + String(
                                    format: "repository-%03d.git",
                                    index
                                )
                    ),
                ],
                canonicalRootRequired: false
            )
        }
        return RepositorySelectionCatalogResult(
            catalog: RepositorySelectionCatalog(
                generation: 1,
                policyDigest: String(repeating: "0", count: 64),
                rootIdentities: ["fixture": identity],
                candidates: candidates,
                unresolvedDefaults: [],
                counters: RepositorySelectionCatalogCounters(),
                elapsedNanoseconds: 0
            ),
            degradedReason: nil
        )
    }

    static func testingV02Chooser(
        canonicalResolved: Bool = false,
        defaultSelected: Bool = false
    )
        throws -> RepositorySelectionCatalogResult {
        let identity = RepositorySelectionCatalogIdentity(
            device: 1,
            inode: 1,
            owner: UInt32(geteuid())
        )
        func locator(_ name: String)
            throws -> RepositorySelectionLocator {
            try RepositorySelectionLocator(
                governedRoot: "fixture",
                components: ["personal", name]
            )
        }
        func alternative(
            _ name: String,
            inode: UInt64
        ) throws -> RepositorySelectionAlternative {
            RepositorySelectionAlternative(
                locator: try locator(name),
                compactLocation: "fixture/personal/\(name)",
                repositoryIdentity:
                    RepositorySelectionCatalogIdentity(
                        device: 1,
                        inode: inode,
                        owner: UInt32(geteuid())
                    ),
                commonDirectoryIdentity:
                    RepositorySelectionCatalogIdentity(
                        device: 1,
                        inode: inode + 100,
                        owner: UInt32(geteuid())
                    ),
                rawOrigin:
                    "git@github.com:fixture/duplicate.git"
            )
        }
        let alternatives = try [
            alternative("duplicate-a", inode: 10),
            alternative("duplicate-b", inode: 11),
        ]
        let duplicate = RepositorySelectionCandidate(
            id: "fixture/duplicate",
            locator: alternatives[
                canonicalResolved ? 1 : 0
            ].locator,
            displayLabel: "fixture/duplicate",
            compactLocation: alternatives[
                canonicalResolved ? 1 : 0
            ].compactLocation,
            policyDisposition: .writable,
            isVisible: true,
            isEligible: true,
            disabledReason: nil,
            advisoryOrigin:
                "git@github.com:fixture/duplicate.git",
            advisoryOriginSource: .directConfig,
            catalogRootIdentity: identity,
            catalogRepositoryIdentity:
                alternatives[canonicalResolved ? 1 : 0]
                    .repositoryIdentity,
            catalogGeneration: 1,
            isDefaultSelected: defaultSelected,
            section: canonicalResolved
                ? .available : .canonicalRootRequired,
            alternatives: alternatives,
            canonicalRootRequired: !canonicalResolved
        )
        let unavailableLocator = try locator("unavailable")
        let unavailable = RepositorySelectionCandidate(
            id: "local-" + String(repeating: "a", count: 64),
            locator: unavailableLocator,
            displayLabel: "Unavailable repository",
            compactLocation:
                "fixture/personal/unavailable",
            policyDisposition: .writable,
            isVisible: true,
            isEligible: false,
            disabledReason: "Origin identity is unavailable.",
            advisoryOrigin: nil,
            advisoryOriginSource: .unavailable,
            catalogRootIdentity: identity,
            catalogRepositoryIdentity: identity,
            catalogGeneration: 1,
            isDefaultSelected: false,
            section: .unavailable,
            alternatives: [],
            canonicalRootRequired: false
        )
        return RepositorySelectionCatalogResult(
            catalog: RepositorySelectionCatalog(
                generation: 1,
                policyDigest: String(repeating: "0", count: 64),
                rootIdentities: ["fixture": identity],
                candidates: [duplicate, unavailable],
                unresolvedDefaults: [],
                counters: RepositorySelectionCatalogCounters(),
                elapsedNanoseconds: 0
            ),
            degradedReason: nil
        )
    }
}
#endif

public struct RepositorySelectionCatalogConfiguration: Sendable {
    public let roots: [RepositorySelectionCatalogRoot]
    public let policy: RepositorySelectionPolicy
    public let preferences: RepositorySelectionPreferenceDocument?
    public let canonicalLocators:
        [String: RepositorySelectionLocator]
    public let sessionEntries:
        [RepositorySelectionPreferenceEntry]
    public let generation: UInt64
    public let limits: RepositorySelectionCatalogLimits
    public let deadlineUptimeNanoseconds: UInt64
    public let admission: RepositorySelectionPathAdmission
    /// A home descriptor may be only an anchor for projected shelves. It does
    /// not grant authority to inspect a repository at the anchor itself.
    public let inspectRootRepository: Bool

    public init(
        roots: [RepositorySelectionCatalogRoot],
        policy: RepositorySelectionPolicy,
        preferences: RepositorySelectionPreferenceDocument?,
        canonicalLocators:
            [String: RepositorySelectionLocator] = [:],
        sessionEntries:
            [RepositorySelectionPreferenceEntry] = [],
        generation: UInt64,
        limits: RepositorySelectionCatalogLimits =
            RepositorySelectionCatalogLimits(),
        deadlineUptimeNanoseconds: UInt64? = nil,
        admission: RepositorySelectionPathAdmission = .unavailable,
        inspectRootRepository: Bool = true
    ) {
        self.roots = roots
        self.admission = admission
        self.inspectRootRepository = inspectRootRepository
        self.policy = policy
        self.preferences = preferences
        self.canonicalLocators = canonicalLocators
        self.sessionEntries = sessionEntries.sorted()
        self.generation = generation
        self.limits = limits
        let now = DispatchTime.now().uptimeNanoseconds
        self.deadlineUptimeNanoseconds =
            deadlineUptimeNanoseconds
                ?? now &+ limits.elapsedNanoseconds
    }
}

public enum RepositorySelectionCatalogDiscovery {
    public static func discoverCatalog(
        configuration: RepositorySelectionCatalogConfiguration
    ) -> RepositorySelectionCatalogResult {
        CatalogBuilder(configuration: configuration).run()
    }
}

private final class CatalogBuilder {
    private let configuration: RepositorySelectionCatalogConfiguration
    private let started = DispatchTime.now().uptimeNanoseconds
    private var counters = RepositorySelectionCatalogCounters()
    private var candidates: [RepositorySelectionCandidate] = []
    private var degradation: RepositorySelectionCatalogDegradation?

    init(configuration: RepositorySelectionCatalogConfiguration) {
        self.configuration = configuration
    }

    func run() -> RepositorySelectionCatalogResult {
        guard configuration.roots.count
                <= configuration.limits.governedRoots else {
            degradation = .tooManyRoots
            return result()
        }
        guard Set(configuration.roots.map(\.logicalKey)).count
                == configuration.roots.count else {
            degradation = .unsafeEntry
            return result()
        }
        for root in configuration.roots where degradation == nil {
            inspect(root)
        }
        candidates = consolidate(candidates)
        candidates.sort {
            if $0.locator != $1.locator {
                return $0.locator < $1.locator
            }
            return $0.id.utf8.lexicographicallyPrecedes($1.id.utf8)
        }
        let found = Set(candidates.map(\.id))
        let desired = Set(
            (configuration.preferences?.entries ?? [])
                + configuration.sessionEntries
        )
        let unresolved = desired.filter {
            !found.contains($0.repositoryID)
        }.sorted()
        return result(unresolved: unresolved)
    }

    private func consolidate(
        _ physical: [RepositorySelectionCandidate]
    ) -> [RepositorySelectionCandidate] {
        let grouped = Dictionary(grouping: physical, by: \.id)
        let defaultIDs = Set(
            configuration.preferences?.entries.map(\.repositoryID)
                ?? []
        )
        return grouped.keys.sorted().compactMap { repositoryID in
            guard let matches = grouped[repositoryID]?.sorted(by: {
                $0.locator < $1.locator
            }),
            let first = matches.first else {
                return nil
            }
            // Hard-no-touch rows intentionally have no origin metadata. Preserve
            // their lexical label and protected presentation without hydration.
            if first.policyDisposition == .permanentNoTouch,
               first.catalogRepositoryIdentity == nil { return first }
            guard first.advisoryOriginSource == .directConfig else {
                return RepositorySelectionCandidate(
                    id: first.id,
                    locator: first.locator,
                    displayLabel: "Unavailable repository",
                    compactLocation: first.compactLocation,
                    policyDisposition: first.policyDisposition,
                    isVisible: first.isVisible,
                    isEligible: false,
                    disabledReason:
                        first.disabledReason
                            ?? "Origin identity is unavailable.",
                    advisoryOrigin: nil,
                    advisoryOriginSource: .unavailable,
                    catalogRootIdentity:
                        first.catalogRootIdentity,
                    catalogRepositoryIdentity:
                        first.catalogRepositoryIdentity,
                    catalogGeneration: first.catalogGeneration,
                    isDefaultSelected: false,
                    section: .unavailable,
                    alternatives: first.alternatives,
                    canonicalRootRequired: false
                )
            }
            let selectable = matches.filter(\.isEligible)
            let configuredCanonical =
                configuration.canonicalLocators[repositoryID]
            let canonical = configuredCanonical.flatMap { expected in
                selectable.first { $0.locator == expected }
            }
            let chosen =
                canonical ?? selectable.first ?? first
            let needsCanonical =
                canonical == nil
                && (
                    selectable.count > 1
                        || configuredCanonical != nil
                )
            let alternatives = matches.flatMap(\.alternatives)
            return RepositorySelectionCandidate(
                id: repositoryID,
                locator: chosen.locator,
                displayLabel: repositoryID,
                compactLocation: chosen.compactLocation,
                policyDisposition: chosen.policyDisposition,
                isVisible: matches.contains(where: \.isVisible),
                isEligible: !selectable.isEmpty,
                disabledReason: chosen.disabledReason,
                advisoryOrigin: chosen.advisoryOrigin,
                advisoryOriginSource: .directConfig,
                catalogRootIdentity:
                    chosen.catalogRootIdentity,
                catalogRepositoryIdentity:
                    chosen.catalogRepositoryIdentity,
                catalogGeneration: chosen.catalogGeneration,
                isDefaultSelected:
                    defaultIDs.contains(repositoryID),
                section: needsCanonical
                    ? .canonicalRootRequired
                    : selectable.isEmpty
                        ? chosen.section
                        : section(
                        disposition: chosen.policyDisposition,
                        hasOrigin: true
                    ),
                alternatives: alternatives,
                canonicalRootRequired: needsCanonical
            )
        }
    }

    private func section(
        disposition: RepositorySelectionPolicyDisposition,
        hasOrigin: Bool
    ) -> RepositorySelectionSection {
        switch disposition {
        case .writable:
            return hasOrigin ? .available : .unavailable
        case .readOnlyReference:
            return .unavailable
        case .excluded, .artifact:
            return .excluded
        case .permanentNoTouch:
            return .protected
        }
    }

    private func result(
        unresolved: [RepositorySelectionPreferenceEntry] = []
    ) -> RepositorySelectionCatalogResult {
        let now = DispatchTime.now().uptimeNanoseconds
        return RepositorySelectionCatalogResult(
            catalog: RepositorySelectionCatalog(
                generation: configuration.generation,
                policyDigest: configuration.policy.digest,
                rootIdentities:
                    configuration.roots.reduce(into: [:]) {
                        identities, root in
                        if identities[root.logicalKey] == nil {
                            identities[root.logicalKey] = root.identity
                        }
                    },
                candidates: candidates,
                unresolvedDefaults: unresolved,
                counters: counters,
                elapsedNanoseconds: now >= started ? now - started : 0
            ),
            degradedReason: degradation
        )
    }

    private func inspect(_ root: RepositorySelectionCatalogRoot) {
        guard allowed(root: root, components: []) else { return }
        var rootInfo = stat()
        guard fstat(root.descriptor, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              rootInfo.st_uid == geteuid(),
              RepositorySelectionCatalogIdentity(rootInfo) == root.identity else {
            degrade(.rootChanged)
            return
        }
        counters.directoriesOpened += 1
        guard checkDirectoryLimit() else { return }
        if configuration.inspectRootRepository, case let .primary(commonIdentity) =
                repositoryMarker(root.descriptor, components: [], root: root) {
            inspectCandidate(
                descriptor: root.descriptor,
                components: [],
                root: root,
                commonDirectoryIdentity: commonIdentity
            )
        }
        for shelf in configuration.policy.shelfPaths
        where degradation == nil {
            guard shelf.count + 1 <= configuration.limits.relativeDepth else {
                degrade(.depthLimit)
                break
            }
            guard let shelfDescriptor = traverse(
                root.descriptor,
                components: shelf,
                authorityRoot: root
            ) else {
                continue
            }
            defer { close(shelfDescriptor) }
            let shelfMarker = repositoryMarker(shelfDescriptor, components: shelf, root: root)
            if case .protected = shelfMarker { continue }
            if case let .primary(commonIdentity) = shelfMarker {
                inspectCandidate(
                    descriptor: shelfDescriptor,
                    components: shelf,
                    root: root,
                    commonDirectoryIdentity: commonIdentity
                )
                continue
            }
            guard let names = directoryNames(shelfDescriptor) else {
                degrade(.unsafeEntry)
                continue
            }
            let visibleNames = names.filter { name in
                !name.hasPrefix(".") && !configuration.policy.isArtifactOrHiddenPrefix(shelf + [name])
            }
            // One ordered bounded batch per at most 64 discovered lexical names.
            // Protected rows use only directory-entry text; no candidate metadata.
            for offset in stride(from: 0, to: visibleNames.count, by: 64) where degradation == nil {
                let batch = Array(visibleNames[offset..<min(offset + 64, visibleNames.count)])
                guard let decisions = classify(root: root, components: batch.map { shelf + [$0] }) else { break }
                for (name, decision) in zip(batch, decisions) where degradation == nil {
                let components = shelf + [name]
                if case .protected = decision {
                    appendProtected(components: components, root: root)
                    continue
                }
                guard validateAdmission() else { break }
                let child = openat(
                    shelfDescriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                if child < 0 {
                    if errno == ELOOP {
                        appendUnsafe(
                            components: components,
                            root: root,
                            reason: "Symbolic-link repository entries are unsafe."
                        )
                    }
                    continue
                }
                counters.directoriesOpened += 1
                guard checkDirectoryLimit() else {
                    close(child)
                    break
                }
                defer { close(child) }
                switch repositoryMarker(child, components: components, root: root) {
                case let .primary(commonIdentity):
                    inspectCandidate(
                        descriptor: child,
                        components: components,
                        root: root,
                        commonDirectoryIdentity: commonIdentity
                    )
                case .linked, .protected:
                    break
                case .unsafe:
                    appendUnsafe(
                        components: components,
                        root: root,
                        reason:
                            "Repository metadata is not a regular file or directory."
                    )
                case .absent:
                    break
                }
                }
            }
        }
        guard validateAdmission() else { return }
        var finalInfo = stat()
        if fstat(root.descriptor, &finalInfo) != 0
            || RepositorySelectionCatalogIdentity(finalInfo) != root.identity {
            degrade(.rootChanged)
        }
    }

    private func traverse(
        _ root: Int32,
        components: [String],
        authorityRoot: RepositorySelectionCatalogRoot
    ) -> Int32? {
        var current = dup(root)
        guard current >= 0 else {
            degrade(.unsafeEntry)
            return nil
        }
        for (index, component) in components.enumerated() {
            guard allowed(root: authorityRoot, components: Array(components.prefix(index + 1))) else {
                close(current)
                return nil
            }
            let next = openat(
                current,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            close(current)
            guard next >= 0 else {
                return nil
            }
            current = next
            counters.directoriesOpened += 1
            guard checkDirectoryLimit() else {
                close(current)
                return nil
            }
        }
        return current
    }

    private func directoryNames(_ descriptor: Int32) -> [String]? {
        guard checkDeadline(), let directory = fdopendir(dup(descriptor)) else {
            return nil
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            counters.directoryEntries += 1
            guard counters.directoryEntries
                    <= configuration.limits.directoryEntries else {
                degrade(.directoryEntryLimit)
                return names
            }
            guard checkDeadline() else { return names }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) {
                    String(validatingCString: $0)
                }
            }
            guard let name else {
                degrade(.unsafeEntry)
                return nil
            }
            if name != "." && name != ".." {
                names.append(name)
            }
        }
        return names.sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
    }

    private enum RepositoryMarker {
        case absent
        case primary(RepositorySelectionCatalogIdentity)
        case linked
        case protected
        case unsafe
    }

    private func repositoryMarker(
        _ descriptor: Int32, components: [String], root: RepositorySelectionCatalogRoot
    ) -> RepositoryMarker {
        guard metadataAllowed(root: root, repository: components, paths: [[".git"]]),
              validateAdmission() else { return .protected }
        var info = stat()
        guard fstatat(
            descriptor,
            ".git",
            &info,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            return errno == ENOENT ? .absent : .unsafe
        }
        let type = info.st_mode & S_IFMT
        if type == S_IFREG {
            return .linked
        }
        guard type == S_IFDIR else {
            return .unsafe
        }
        let git = openat(
            descriptor,
            ".git",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard git >= 0 else {
            return .unsafe
        }
        defer { close(git) }
        var gitInfo = stat()
        guard fstat(git, &gitInfo) == 0,
              (gitInfo.st_mode & S_IFMT) == S_IFDIR,
              gitInfo.st_uid == geteuid() else {
            return .unsafe
        }
        return .primary(
            RepositorySelectionCatalogIdentity(gitInfo)
        )
    }

    private func inspectCandidate(
        descriptor: Int32,
        components: [String],
        root: RepositorySelectionCatalogRoot,
        commonDirectoryIdentity:
            RepositorySelectionCatalogIdentity
    ) {
        guard checkRowLimit() else { return }
        let locator: RepositorySelectionLocator
        do {
            locator = try RepositorySelectionLocator(
                governedRoot: root.logicalKey,
                components: components
            )
        } catch {
            degrade(.unsafeEntry)
            return
        }
        // A checkout's admission does not admit its metadata descendants.
        // Classify the entire fixed read set before opening any of those files.
        let metadata = [[".git"], [".git", "config"], [".git", "refs"],
                        [".git", "refs", "remotes"], [".git", "refs", "remotes", "origin"],
                        [".git", "refs", "remotes", "origin", "HEAD"]]
        guard metadataAllowed(root: root, repository: components, paths: metadata),
              validateAdmission() else { return }
        let origin = directOrigin(descriptor)
        guard degradation == nil, validateAdmission() else { return }
        var repositoryInfo = stat()
        guard fstat(descriptor, &repositoryInfo) == 0,
              (repositoryInfo.st_mode & S_IFMT) == S_IFDIR,
              repositoryInfo.st_uid == geteuid() else {
            degrade(.rootChanged)
            return
        }
        var namedRepositoryInfo = stat()
        let relativePath =
            components.isEmpty ? "." : components.joined(separator: "/")
        guard fstatat(
            root.descriptor,
            relativePath,
            &namedRepositoryInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
        namedRepositoryInfo.st_dev == repositoryInfo.st_dev,
        namedRepositoryInfo.st_ino == repositoryInfo.st_ino,
        (namedRepositoryInfo.st_mode & S_IFMT) == S_IFDIR else {
            degrade(.rootChanged)
            return
        }
        let repositoryIdentity =
            RepositorySelectionCatalogIdentity(repositoryInfo)
        let advisoryID = origin.flatMap(repositoryID)
        let id = advisoryID ?? localID(
            root: root.logicalKey,
            path: locator.relativePath
        )
        let disposition = configuration.policy.disposition(
            relativePath: locator.relativePath,
            repositoryID: advisoryID
        )
        let remoteDefaultAvailable =
            localRemoteDefaultAvailable(descriptor)
        guard degradation == nil, validateAdmission() else { return }
        let selectable = disposition.isSelectable
            && advisoryID != nil
            && remoteDefaultAvailable
        let unavailableReason: String?
        if advisoryID == nil {
            unavailableReason = "Origin identity is unavailable."
        } else if !remoteDefaultAvailable {
            unavailableReason =
                "Remote-default metadata is unavailable."
        } else {
            unavailableReason = nil
        }
        let defaults = Set(configuration.preferences?.entries ?? [])
        candidates.append(
            RepositorySelectionCandidate(
                id: id,
                locator: locator,
                displayLabel: advisoryID
                    ?? components.last
                    ?? locator.relativePath,
                compactLocation:
                    components.isEmpty
                        ? root.logicalKey
                        : "\(root.logicalKey)/\(locator.relativePath)",
                policyDisposition: disposition,
                isVisible: disposition != .artifact,
                isEligible: selectable,
                disabledReason:
                    disposition.disabledReason ?? unavailableReason,
                advisoryOrigin: origin,
                advisoryOriginSource:
                    origin == nil ? .unavailable : .directConfig,
                catalogRootIdentity: root.identity,
                catalogRepositoryIdentity: repositoryIdentity,
                catalogGeneration: configuration.generation,
                isDefaultSelected: defaults.contains(
                    (try? RepositorySelectionPreferenceEntry(
                        repositoryID: id,
                        locator: locator
                    )) ?? impossibleEntry(locator)
                ),
                section: section(
                    disposition: disposition,
                    hasOrigin: advisoryID != nil
                        && remoteDefaultAvailable
                ),
                alternatives: [
                    RepositorySelectionAlternative(
                        locator: locator,
                        compactLocation: components.isEmpty
                            ? root.logicalKey
                            : "\(root.logicalKey)/"
                                + locator.relativePath,
                        repositoryIdentity: repositoryIdentity,
                        commonDirectoryIdentity:
                            commonDirectoryIdentity,
                        rawOrigin: origin ?? ""
                    ),
                ],
                canonicalRootRequired: false
            )
        )
        counters.candidateRows += 1
    }

    private func localRemoteDefaultAvailable(
        _ repository: Int32
    ) -> Bool {
        guard let descriptor = openMetadataFile(repository, components: [".git", "refs", "remotes", "origin", "HEAD"]) else { return false }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_size > 0,
              info.st_size <= 512 else {
            return false
        }
        guard counters.aggregateBytes + Int(info.st_size) <= configuration.limits.aggregateBytes else {
            degrade(.aggregateByteLimit)
            return false
        }
        guard validateAdmission() else { return false }
        var bytes = [UInt8](
            repeating: 0,
            count: Int(info.st_size)
        )
        let count = Darwin.read(
            descriptor,
            &bytes,
            bytes.count
        )
        if count > 0 { counters.aggregateBytes += count }
        guard validateAdmission(), count == bytes.count,
              let value = String(
                  data: Data(bytes),
                  encoding: .utf8
              )?.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }
        return value.hasPrefix(
            "ref: refs/remotes/origin/"
        )
    }

    private func validateAdmission() -> Bool {
        guard checkDeadline() else { return false }
        do {
            try configuration.admission.validate(deadline: configuration.deadlineUptimeNanoseconds)
            return true
        } catch RepositorySelectionAdmissionError.cleanupPending {
            degrade(.cleanupPending)
            return false
        } catch {
            degrade(.policyUnavailable)
            return false
        }
    }

    private func classify(root: RepositorySelectionCatalogRoot, components: [[String]])
        -> [RepositorySelectionAdmissionDisposition]? {
        guard checkDeadline() else { return nil }
        do {
            let paths = try components.map { try RepositorySelectionAdmissionPath(root: root.logicalKey, components: $0) }
            return try configuration.admission.classify(paths, deadline: configuration.deadlineUptimeNanoseconds)
        } catch RepositorySelectionAdmissionError.cleanupPending {
            degrade(.cleanupPending)
            return nil
        } catch {
            degrade(.policyUnavailable)
            return nil
        }
    }

    private func allowed(root: RepositorySelectionCatalogRoot, components: [String]) -> Bool {
        guard let decision = classify(root: root, components: [components])?.first else { return false }
        if case .allowed = decision { return true }
        if components.isEmpty { degrade(.policyUnavailable) }
        else { appendProtected(components: components, root: root) }
        return false
    }

    private func appendProtected(components: [String], root: RepositorySelectionCatalogRoot) {
        guard checkRowLimit(), let locator = try? RepositorySelectionLocator(
            governedRoot: root.logicalKey, components: components) else {
            degrade(.unsafeEntry)
            return
        }
        candidates.append(RepositorySelectionCandidate(
            id: localID(root: root.logicalKey, path: locator.relativePath), locator: locator,
            displayLabel: components.last ?? locator.relativePath,
            compactLocation: "\(root.logicalKey)/\(locator.relativePath)",
            policyDisposition: .permanentNoTouch, isVisible: true, isEligible: false,
            disabledReason: RepositorySelectionPolicyDisposition.permanentNoTouch.disabledReason,
            advisoryOrigin: nil, advisoryOriginSource: .unavailable,
            catalogRootIdentity: root.identity, catalogRepositoryIdentity: nil,
            catalogGeneration: configuration.generation, isDefaultSelected: false,
            section: .protected, alternatives: [], canonicalRootRequired: false))
        counters.candidateRows += 1
    }

    private func appendUnsafe(
        components: [String],
        root: RepositorySelectionCatalogRoot,
        reason: String
    ) {
        guard checkRowLimit(),
              let locator = try? RepositorySelectionLocator(
                  governedRoot: root.logicalKey,
                  components: components
              ) else {
            degrade(.unsafeEntry)
            return
        }
        candidates.append(
            RepositorySelectionCandidate(
                id: localID(
                    root: root.logicalKey,
                    path: locator.relativePath
                ),
                locator: locator,
                displayLabel: components.last ?? locator.relativePath,
                compactLocation:
                    "\(root.logicalKey)/\(locator.relativePath)",
                policyDisposition: .excluded,
                isVisible: true,
                isEligible: false,
                disabledReason: reason,
                advisoryOrigin: nil,
                advisoryOriginSource: .unavailable,
                catalogRootIdentity: root.identity,
                catalogRepositoryIdentity: nil,
                catalogGeneration: configuration.generation,
                isDefaultSelected: false,
                section: .unavailable,
                alternatives: [],
                canonicalRootRequired: false
            )
        )
        counters.candidateRows += 1
        degrade(.unsafeEntry)
    }

    /// The caller supplies only the fixed metadata roster above. Each ancestor
    /// has been admitted under the catalog's original deadline; no aliases are
    /// followed and a special final file cannot block before its type check.
    private func openMetadataFile(_ repository: Int32, components: [String]) -> Int32? {
        guard let leaf = components.last, validateAdmission() else { return nil }
        var parent = dup(repository)
        guard parent >= 0 else { degrade(.unsafeEntry); return nil }
        defer { close(parent) }
        for component in components.dropLast() {
            guard validateAdmission() else { return nil }
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return nil }
            close(parent); parent = next
            counters.directoriesOpened += 1
            guard checkDirectoryLimit() else { return nil }
            var info = stat()
            guard fstat(parent, &info) == 0, info.st_uid == geteuid(),
                  (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o022) == 0 else {
                degrade(.unsafeEntry); return nil
            }
        }
        guard validateAdmission() else { return nil }
        let file = openat(parent, leaf, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { return nil }
        counters.filesOpened += 1
        guard counters.filesOpened <= configuration.limits.filesOpened else {
            close(file); degrade(.fileOpenLimit); return nil
        }
        return file
    }

    private func metadataAllowed(root: RepositorySelectionCatalogRoot, repository: [String],
                                 paths: [[String]]) -> Bool {
        guard let decisions = classify(root: root, components: paths.map { repository + $0 }) else { return false }
        guard decisions.allSatisfy({ if case .allowed = $0 { return true }; return false }) else {
            // A protected metadata leaf disables its checkout, not a synthetic
            // repository row named config, HEAD, or .git.
            appendProtected(components: repository, root: root)
            return false
        }
        return true
    }

    private func directOrigin(_ repository: Int32) -> String? {
        guard let config = openMetadataFile(repository, components: [".git", "config"]) else { return nil }
        defer { close(config) }
        var info = stat()
        guard fstat(config, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_size >= 0 else {
            degrade(.unsafeEntry)
            return nil
        }
        guard info.st_size
                <= configuration.limits.directConfigBytes else {
            degrade(.aggregateByteLimit)
            return nil
        }
        guard counters.aggregateBytes + Int(info.st_size)
                <= configuration.limits.aggregateBytes else {
            degrade(.aggregateByteLimit)
            return nil
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count <= configuration.limits.directConfigBytes {
            guard checkDeadline() else { return nil }
            let count = Darwin.read(config, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0 && errno == EINTR { continue }
            guard count == 0 else { return nil }
            break
        }
        counters.aggregateBytes += data.count
        guard data.count <= configuration.limits.directConfigBytes,
              let text = String(data: data, encoding: .utf8),
              !text.contains("\0") else {
            return nil
        }
        var inOrigin = false
        var urls: [String] = []
        for raw in text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.lowercased() == "[remote \"origin\"]"
            } else if inOrigin,
                      let separator = line.firstIndex(of: "="),
                      line[..<separator].trimmingCharacters(
                          in: .whitespaces
                      ).lowercased() == "url" {
                urls.append(
                    line[line.index(after: separator)...]
                        .trimmingCharacters(in: .whitespaces)
                )
            }
        }
        guard urls.count == 1, repositoryID(urls[0]) != nil else {
            return nil
        }
        return urls[0]
    }

    private func repositoryID(_ origin: String) -> String? {
        var value: String
        if origin.hasPrefix("git@github.com:") {
            value = String(origin.dropFirst("git@github.com:".count))
        } else if origin.hasPrefix("ssh://git@github.com/") {
            value = String(origin.dropFirst("ssh://git@github.com/".count))
        } else if origin.hasPrefix("https://github.com/") {
            value = String(origin.dropFirst("https://github.com/".count))
        } else {
            return nil
        }
        if value.hasSuffix(".git") {
            value.removeLast(4)
        }
        value = value.lowercased()
        return RepositorySelectionPreferenceEntry.validRepositoryID(value)
            ? value : nil
    }

    private func localID(root: String, path: String) -> String {
        let digest = SHA256.hash(data: Data("\(root)\0\(path)".utf8))
        return "local-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func impossibleEntry(
        _ locator: RepositorySelectionLocator
    ) -> RepositorySelectionPreferenceEntry {
        try! RepositorySelectionPreferenceEntry(
            repositoryID: String(repeating: "x", count: 1) + "/x",
            locator: locator
        )
    }

    private func checkDeadline() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now <= configuration.deadlineUptimeNanoseconds,
              now - started <= configuration.limits.elapsedNanoseconds else {
            degrade(.deadline)
            return false
        }
        return true
    }

    private func checkDirectoryLimit() -> Bool {
        guard counters.directoriesOpened
                <= configuration.limits.directoriesOpened else {
            degrade(.directoryOpenLimit)
            return false
        }
        return true
    }

    private func checkRowLimit() -> Bool {
        guard counters.candidateRows
                < configuration.limits.candidateRows else {
            degrade(.rowLimit)
            return false
        }
        return true
    }

    private func degrade(_ reason: RepositorySelectionCatalogDegradation) {
        if degradation == nil {
            degradation = reason
        }
    }
}
