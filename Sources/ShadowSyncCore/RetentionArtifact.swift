import CryptoKit
import Darwin
import Foundation

public let shadowSyncRetentionSchema =
    "shadow-sync-retention/v2"

public enum RetentionEntryKind:
    String, Codable, Equatable, Sendable {
    case directory
    case regular
    case symbolicLink
}

public struct RetentionEntry:
    Codable, Equatable, Sendable {
    public let path: String
    public let kind: RetentionEntryKind
    public let mode: UInt16
    public let size: UInt64
    public let symlinkTarget: String?
    public let contentSHA256: String?

    public init(
        path: String,
        kind: RetentionEntryKind,
        mode: UInt16,
        size: UInt64,
        symlinkTarget: String?,
        contentSHA256: String?
    ) throws {
        guard RetentionPath.isSafeRelative(path),
              mode <= 0o7777,
              (kind == .symbolicLink)
                == (symlinkTarget != nil),
              (kind == .regular)
                == (contentSHA256 != nil) else {
            throw GitSafetyError.unsafeRepository(
                "retention manifest entry is invalid"
            )
        }
        self.path = path
        self.kind = kind
        self.mode = mode
        self.size = size
        self.symlinkTarget = symlinkTarget
        self.contentSHA256 = contentSHA256
    }
}

public struct RetentionRestoreProof:
    Codable, Equatable, Sendable {
    public let verifiedAt: String
    public let exactTipOID: String?
    public let bundleVerified: Bool
    public let connectivityVerified: Bool
    public let entryManifestVerified: Bool
    public let indexVerified: Bool
    public let statusDigestVerified: Bool

    public var isComplete: Bool {
        entryManifestVerified
            && indexVerified
            && statusDigestVerified
            && (
                exactTipOID == nil
                    || (bundleVerified && connectivityVerified)
            )
    }
}

public struct RetentionManifest:
    Codable, Equatable, Sendable {
    public let schema: String
    public let artifactID: String
    public let repositoryID: String
    public let cloneID: String
    public let commonDirectoryIdentity:
        RepositoryDirectoryIdentity
    public let worktreeID: String?
    public let worktreeRootIdentity:
        RepositoryDirectoryIdentity?
    public let registrationIdentity:
        RepositoryDirectoryIdentity?
    public let branchRef: String?
    public let tipOID: String?
    public let objectFormat: String
    public let entries: [RetentionEntry]
    public let indexSHA256: String?
    public let sharedIndexFiles: [String: String]
    public let statusSHA256: String?
    public let includedPaths: [String]
    public let excludedPaths: [String]
    public let secretShapedPaths: [String]
    public let possibleSecretsAuthorized: Bool
    public let createdAt: String
    public let componentSHA256: [String: String]
    public let restoreProof: RetentionRestoreProof
    public let restoreInstructions: [String]

    public init(
        artifactID: String,
        repositoryID: String,
        cloneID: String,
        commonDirectoryIdentity:
            RepositoryDirectoryIdentity,
        worktreeID: String?,
        worktreeRootIdentity:
            RepositoryDirectoryIdentity?,
        registrationIdentity:
            RepositoryDirectoryIdentity?,
        branchRef: String?,
        tipOID: String?,
        objectFormat: String,
        entries: [RetentionEntry],
        indexSHA256: String?,
        sharedIndexFiles: [String: String],
        statusSHA256: String?,
        includedPaths: [String],
        excludedPaths: [String],
        secretShapedPaths: [String],
        possibleSecretsAuthorized: Bool,
        createdAt: String,
        componentSHA256: [String: String],
        restoreProof: RetentionRestoreProof,
        restoreInstructions: [String]
    ) throws {
        guard artifactID.range(
            of: #"^[a-z0-9-]{8,80}$"#,
            options: .regularExpression
        ) != nil,
        GitHubIdentity.parse(
            "git@github.com:\(repositoryID).git"
        )?.canonicalName == repositoryID,
        cloneID.hasPrefix("clone:"),
        branchRef == nil
            || GitReferenceSyntax.isValidLocalBranchRef(branchRef!),
        tipOID == nil || RetentionPath.isOID(tipOID!),
        objectFormat == "sha1" || objectFormat == "sha256",
        Set(entries.map(\.path)).count == entries.count,
        entries == entries.sorted(by: { $0.path < $1.path }),
        includedPaths.allSatisfy(RetentionPath.isSafeRelative),
        excludedPaths.allSatisfy(RetentionPath.isSafeRelative),
        secretShapedPaths.allSatisfy(
            RetentionPath.isSafeRelative
        ),
        restoreProof.isComplete,
        possibleSecretsAuthorized,
        !restoreInstructions.isEmpty else {
            throw GitSafetyError.unsafeRepository(
                "retention manifest is incomplete"
            )
        }
        schema = shadowSyncRetentionSchema
        self.artifactID = artifactID
        self.repositoryID = repositoryID
        self.cloneID = cloneID
        self.commonDirectoryIdentity =
            commonDirectoryIdentity
        self.worktreeID = worktreeID
        self.worktreeRootIdentity = worktreeRootIdentity
        self.registrationIdentity = registrationIdentity
        self.branchRef = branchRef
        self.tipOID = tipOID?.lowercased()
        self.objectFormat = objectFormat
        self.entries = entries
        self.indexSHA256 = indexSHA256
        self.sharedIndexFiles = sharedIndexFiles
        self.statusSHA256 = statusSHA256
        self.includedPaths = includedPaths.sorted()
        self.excludedPaths = excludedPaths.sorted()
        self.secretShapedPaths = secretShapedPaths.sorted()
        self.possibleSecretsAuthorized =
            possibleSecretsAuthorized
        self.createdAt = createdAt
        self.componentSHA256 = componentSHA256
        self.restoreProof = restoreProof
        self.restoreInstructions =
            restoreInstructions.map(Redactor.sanitize)
    }
}

public struct RetentionArtifactSummary:
    Codable, Equatable, Sendable {
    public let artifactID: String
    public let repositoryID: String
    public let target: String
    public let tipOID: String?
    public let path: String
    public let restoreProven: Bool
    public let restoreInstructions: [String]

    public init(
        manifest: RetentionManifest,
        path: String
    ) {
        artifactID = manifest.artifactID
        repositoryID = manifest.repositoryID
        target = manifest.worktreeID
            ?? manifest.branchRef
            ?? "history"
        tipOID = manifest.tipOID
        self.path = path
        restoreProven = manifest.restoreProof.isComplete
        restoreInstructions = manifest.restoreInstructions
    }
}

public enum RetentionPreparation:
    Equatable, Sendable {
    case completed(RetentionArtifactSummary)
    case incomplete(
        excludedPaths: [String],
        secretShapedPaths: [String],
        reason: String
    )
    case cancelled
}

public final class RetentionArtifactStore:
    @unchecked Sendable {
    private static let maximumEntries = 10_000
    private static let maximumBytes: UInt64 =
        1_073_741_824
    private let state: SecureStateDirectory
    private let account: EffectiveAccount
    private let runner: ClosedProcessRunner

    public init(
        state: SecureStateDirectory,
        account: EffectiveAccount,
        runner: ClosedProcessRunner = ClosedProcessRunner()
    ) {
        self.state = state
        self.account = account
        self.runner = runner
    }

    public func prepare(
        selection: RemovalSelection,
        cancellation: CancellationToken
    ) -> RetentionPreparation {
        guard selection.intent == .removeWithRecovery
            || selection.includePossibleSecrets else {
            return .incomplete(
                excludedPaths: boundedOmissions(
                    selection.candidate
                ),
                secretShapedPaths: boundedOmissions(
                    selection.candidate
                ).filter(RetentionPath.isSecretShaped),
                reason:
                    "Possible secrets were not authorized; no payload bytes were archived."
            )
        }
        guard selection.includePossibleSecrets else {
            let omitted = boundedOmissions(
                selection.candidate
            )
            return .incomplete(
                excludedPaths: omitted,
                secretShapedPaths:
                    omitted.filter(RetentionPath.isSecretShaped),
                reason:
                    "Possible secrets were not authorized; no payload bytes were archived."
            )
        }
        let artifactID =
            "ret-\(UUID().uuidString.lowercased())"
        var retentionFD: Int32 = -1
        var slotFD: Int32 = -1
        let slotName = ".incomplete-\(artifactID)"
        do {
            if cancellation.isCancelled {
                return .cancelled
            }
            retentionFD = try ensureRetentionDirectory()
            guard mkdirat(
                retentionFD,
                slotName,
                0o700
            ) == 0 else {
                throw SecureStateError.systemCall(
                    "create incomplete retention slot",
                    errno
                )
            }
            slotFD = try openPrivateDirectory(
                slotName,
                parent: retentionFD
            )
            let summary = try buildAndVerify(
                selection: selection,
                artifactID: artifactID,
                retentionFD: retentionFD,
                slotFD: slotFD,
                slotName: slotName,
                cancellation: cancellation
            )
            Darwin.close(slotFD)
            slotFD = -1
            guard renameatx_np(
                retentionFD,
                slotName,
                retentionFD,
                artifactID,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                throw SecureStateError.systemCall(
                    "publish retention artifact",
                    errno
                )
            }
            guard fsync(retentionFD) == 0 else {
                throw SecureStateError.systemCall(
                    "fsync retention directory",
                    errno
                )
            }
            Darwin.close(retentionFD)
            return .completed(summary)
        } catch GitSafetyError.cancelled {
            if slotFD >= 0 { Darwin.close(slotFD) }
            if retentionFD >= 0 {
                try? removeOwnedTree(
                    named: slotName,
                    parent: retentionFD
                )
                Darwin.close(retentionFD)
            }
            return .cancelled
        } catch {
            if slotFD >= 0 { Darwin.close(slotFD) }
            if retentionFD >= 0 {
                try? removeOwnedTree(
                    named: slotName,
                    parent: retentionFD
                )
                Darwin.close(retentionFD)
            }
            return .incomplete(
                excludedPaths:
                    boundedOmissions(selection.candidate),
                secretShapedPaths:
                    boundedOmissions(selection.candidate)
                        .filter(RetentionPath.isSecretShaped),
                reason: Redactor.sanitize(String(describing: error))
            )
        }
    }

    public func list() throws -> [RetentionArtifactSummary] {
        let retentionFD = try ensureRetentionDirectory()
        defer { Darwin.close(retentionFD) }
        let names = try directoryNames(retentionFD)
        guard names.allSatisfy({
            RetentionPath.isArtifactID($0)
                || (
                    $0.hasPrefix(".incomplete-ret-")
                        && RetentionPath.isComponent($0)
                )
        }) else {
            throw GitSafetyError.unsafeRepository(
                "retention directory contains an unknown entry"
            )
        }
        if names.contains(where: {
            $0.hasPrefix(".incomplete-")
        }) {
            throw GitSafetyError.unsafeRepository(
                "retention contains an incomplete transaction slot"
            )
        }
        return try names
            .filter { !$0.hasPrefix(".incomplete-") }
            .compactMap { name in
                guard RetentionPath.isArtifactID(name) else {
                    return nil
                }
                let directory = try openPrivateDirectory(
                    name,
                    parent: retentionFD
                )
                defer { Darwin.close(directory) }
                let data = try readFile(
                    "manifest.json",
                    parent: directory,
                    maximumBytes: 4_194_304,
                    requireProtectedArtifact: true
                )
                guard Self.rawManifestIsSupported(data) else {
                    throw GitSafetyError.unsafeRepository(
                        "published retention artifact schema is incompatible"
                    )
                }
                let manifest = try JSONDecoder().decode(
                    RetentionManifest.self,
                    from: data
                )
                guard manifest.schema
                        == shadowSyncRetentionSchema,
                      manifest.artifactID == name,
                      Self.validPublishedManifest(
                          manifest
                      ) else {
                    throw GitSafetyError.unsafeRepository(
                        "published retention artifact is invalid"
                    )
                }
                let summary = RetentionArtifactSummary(
                    manifest: manifest,
                    path: state.path
                        + "/retention/\(name)"
                )
                guard try verify(summary) else {
                    throw GitSafetyError.unsafeRepository(
                        "published retention artifact failed integrity verification"
                    )
                }
                return summary
            }
            .sorted { $0.artifactID < $1.artifactID }
    }

    public func verify(
        _ summary: RetentionArtifactSummary
    ) throws -> Bool {
        guard RetentionPath.isArtifactID(summary.artifactID),
              summary.path == state.path
                + "/retention/\(summary.artifactID)" else {
            return false
        }
        let retentionFD = try ensureRetentionDirectory()
        defer { Darwin.close(retentionFD) }
        let directory = try openPrivateDirectory(
            summary.artifactID,
            parent: retentionFD
        )
        defer { Darwin.close(directory) }
        let data = try readFile(
            "manifest.json",
            parent: directory,
            maximumBytes: 4_194_304,
            requireProtectedArtifact: true
        )
        guard Self.rawManifestIsSupported(data) else {
            return false
        }
        let manifest = try JSONDecoder().decode(
            RetentionManifest.self,
            from: data
        )
        guard manifest.schema == shadowSyncRetentionSchema,
              manifest.artifactID == summary.artifactID,
              manifest.repositoryID == summary.repositoryID,
              manifest.tipOID == summary.tipOID,
              Self.validPublishedManifest(manifest) else {
            return false
        }
        let expectedTopLevel =
            Set(["manifest.json"])
                .union(manifest.componentSHA256.keys)
        guard Set(try directoryNames(directory))
                == expectedTopLevel else {
            return false
        }
        for (name, expected) in manifest.componentSHA256 {
            if name == "index.snapshot" {
                let snapshot = try openPrivateDirectory(
                    name,
                    parent: directory
                )
                defer { Darwin.close(snapshot) }
                let indexHash = try hashFile(
                    "index",
                    parent: snapshot
                )
                var fields = [indexHash]
                let expectedSnapshotEntries =
                    Set(["index"])
                        .union(
                            manifest.sharedIndexFiles.keys
                        )
                guard Set(try directoryNames(snapshot))
                        == expectedSnapshotEntries else {
                    return false
                }
                for shared in manifest.sharedIndexFiles.keys
                    .sorted() {
                    let observed = try hashFile(
                        shared,
                        parent: snapshot
                    )
                    guard observed
                            == manifest.sharedIndexFiles[shared] else {
                        return false
                    }
                    fields.append("\(shared):\(observed)")
                }
                guard Self.sha256(
                    Data(fields.joined(separator: "\n").utf8)
                ) == expected else {
                    return false
                }
            } else if try hashFile(
                name,
                parent: directory
            ) != expected {
                return false
            }
        }
        return true
    }

    private static func rawManifestIsSupported(
        _ data: Data
    ) -> Bool {
        guard let object =
                try? JSONSerialization.jsonObject(
                    with: data
                ) as? [String: Any] else {
            return false
        }
        let required = Set([
            "schema", "artifactID", "repositoryID", "cloneID",
            "commonDirectoryIdentity", "objectFormat", "entries",
            "sharedIndexFiles", "includedPaths", "excludedPaths",
            "secretShapedPaths", "possibleSecretsAuthorized",
            "createdAt", "componentSHA256", "restoreProof",
            "restoreInstructions",
        ])
        let optional = Set([
            "worktreeID", "worktreeRootIdentity",
            "registrationIdentity", "branchRef", "tipOID",
            "indexSHA256", "statusSHA256",
        ])
        let keys = Set(object.keys)
        guard required.isSubset(of: keys),
              keys.isSubset(of: required.union(optional)),
              let common =
                object["commonDirectoryIdentity"]
                    as? [String: Any],
              rawIdentityIsSupported(common),
              let entries =
                object["entries"] as? [[String: Any]],
              entries.allSatisfy(rawEntryIsSupported),
              let proof =
                object["restoreProof"] as? [String: Any],
              rawProofIsSupported(proof) else {
            return false
        }
        for name in [
            "worktreeRootIdentity",
            "registrationIdentity",
        ] {
            if let value = object[name],
               !(value is NSNull) {
                guard let identity =
                        value as? [String: Any],
                      rawIdentityIsSupported(identity) else {
                    return false
                }
            }
        }
        return true
    }

    private static func rawIdentityIsSupported(
        _ value: [String: Any]
    ) -> Bool {
        Set(value.keys) == Set(["device", "inode"])
    }

    private static func rawEntryIsSupported(
        _ value: [String: Any]
    ) -> Bool {
        let required = Set(["path", "kind", "mode", "size"])
        let optional = Set(["symlinkTarget", "contentSHA256"])
        let keys = Set(value.keys)
        return required.isSubset(of: keys)
            && keys.isSubset(of: required.union(optional))
    }

    private static func rawProofIsSupported(
        _ value: [String: Any]
    ) -> Bool {
        let required = Set([
            "verifiedAt", "bundleVerified",
            "connectivityVerified", "entryManifestVerified",
            "indexVerified", "statusDigestVerified",
        ])
        let optional = Set(["exactTipOID"])
        let keys = Set(value.keys)
        return required.isSubset(of: keys)
            && keys.isSubset(of: required.union(optional))
    }

    private static func validPublishedManifest(
        _ manifest: RetentionManifest
    ) -> Bool {
        guard RetentionPath.isArtifactID(
            manifest.artifactID
        ),
        GitHubIdentity.parse(
            "git@github.com:\(manifest.repositoryID).git"
        )?.canonicalName == manifest.repositoryID,
        manifest.cloneID.hasPrefix("clone:"),
        manifest.branchRef == nil
            || GitReferenceSyntax.isValidLocalBranchRef(
                manifest.branchRef!
            ),
        manifest.tipOID == nil
            || RetentionPath.isOID(manifest.tipOID!),
        manifest.objectFormat == "sha1"
            || manifest.objectFormat == "sha256",
        manifest.entries
            == manifest.entries.sorted(by: {
                $0.path < $1.path
            }),
        Set(manifest.entries.map(\.path)).count
            == manifest.entries.count,
        manifest.entries.allSatisfy({
            RetentionPath.isSafeRelative($0.path)
                && $0.mode <= 0o7777
                && (($0.kind == .symbolicLink)
                    == ($0.symlinkTarget != nil))
                && (($0.kind == .regular)
                    == ($0.contentSHA256 != nil))
                && ($0.contentSHA256 == nil
                    || validSHA256($0.contentSHA256!))
        }),
        manifest.includedPaths.allSatisfy(
            RetentionPath.isSafeRelative
        ),
        manifest.includedPaths
            == Array(Set(manifest.includedPaths))
                .sorted(),
        manifest.excludedPaths.allSatisfy(
            RetentionPath.isSafeRelative
        ),
        manifest.excludedPaths
            == Array(Set(manifest.excludedPaths))
                .sorted(),
        manifest.secretShapedPaths.allSatisfy(
            RetentionPath.isSafeRelative
        ),
        manifest.secretShapedPaths
            == Array(Set(manifest.secretShapedPaths))
                .sorted(),
        manifest.possibleSecretsAuthorized,
        manifest.restoreProof.isComplete,
        manifest.restoreProof.exactTipOID
            == manifest.tipOID,
        !manifest.restoreInstructions.isEmpty,
        manifest.componentSHA256.values
            .allSatisfy(validSHA256),
        manifest.sharedIndexFiles.values
            .allSatisfy(validSHA256),
        manifest.sharedIndexFiles.keys.allSatisfy({
            $0.range(
                of: #"^sharedindex\.(?:[0-9a-f]{40}|[0-9a-f]{64})$"#,
                options: .regularExpression
            ) != nil
        }) else {
            return false
        }
        let components =
            Set(manifest.componentSHA256.keys)
        guard components.isSubset(of: [
            "branch.bundle",
            "worktree.tar",
            "index.snapshot",
        ]),
        manifest.excludedPaths.isEmpty,
        Set(manifest.secretShapedPaths)
            == Set(
                manifest.includedPaths.filter(
                    RetentionPath.isSecretShaped
                )
            ) else {
            return false
        }
        if manifest.tipOID != nil,
           !components.contains("branch.bundle") {
            return false
        }
        if manifest.worktreeID != nil {
            return manifest.worktreeRootIdentity != nil
                && manifest.registrationIdentity != nil
                && components.contains("worktree.tar")
                && components.contains("index.snapshot")
                && manifest.indexSHA256.map(validSHA256)
                    == true
                && manifest.statusSHA256.map(validSHA256)
                    == true
                && Set(manifest.entries.map(\.path))
                    == Set(manifest.includedPaths)
        }
        return manifest.branchRef != nil
            && !components.contains("worktree.tar")
            && !components.contains("index.snapshot")
            && manifest.entries.isEmpty
            && manifest.indexSHA256 == nil
            && manifest.statusSHA256 == nil
            && manifest.sharedIndexFiles.isEmpty
    }

    private static func validSHA256(
        _ value: String
    ) -> Bool {
        value.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil
    }

    private func buildAndVerify(
        selection: RemovalSelection,
        artifactID: String,
        retentionFD: Int32,
        slotFD: Int32,
        slotName: String,
        cancellation: CancellationToken
    ) throws -> RetentionArtifactSummary {
        let candidate = selection.candidate
        guard candidate.canSelect,
              candidate.hardExclusion == nil,
              candidate.expectedOID.map(
                RetentionPath.isOID
              ) == true else {
            throw GitSafetyError.unsafeRepository(
                "retention candidate identity is incomplete"
            )
        }
        if let worktree = candidate.worktree {
            guard worktree.verification == .verified,
                  worktree.rootIdentity != nil,
                  worktree.registrationIdentity != nil,
                  worktree.contentEvidenceDigest != nil,
                  worktree.fileState?.operationState
                    == .clear else {
                throw GitSafetyError.unsafeRepository(
                    "incomplete or active worktree state cannot produce complete recovery"
                )
            }
        }
        let source = candidate.clone.sourceSnapshot
        let primary = try RepositoryHandle.open(source)
        let target: RepositoryHandle
        if let worktree = candidate.worktree {
            target = try RepositoryHandle.open(
                source,
                targetWorktree: worktree
            )
        } else {
            target = primary
        }
        let frozen = try primary.freezeConfiguration(
            account: account
        )
        let environment = ClosedProcessRunner.environment(
            account: account,
            frozenConfigPath: frozen.snapshot.frozenPath
        )
        var entries: [RetentionEntry] = []
        var components: [String: String] = [:]
        var includedPaths: [String] = []
        var indexSnapshot: IndexSnapshot?
        var statusData: Data?
        let slotPath = state.path
            + "/retention/\(slotName)"

        if let worktree = candidate.worktree {
            try checkCancellation(cancellation)
            let tarFD = try createArtifactFile(
                "worktree.tar",
                parent: slotFD
            )
            do {
                var writer = TarWriter(descriptor: tarFD)
                entries = try enumerateWorktree(
                    descriptor: target.worktreeDescriptor,
                    relativeParent: "",
                    writer: &writer,
                    count: &includedPaths,
                    totalBytes: 0,
                    cancellation: cancellation
                ).entries
                try writer.finish()
                try finishArtifactFile(tarFD)
            } catch {
                Darwin.close(tarFD)
                throw error
            }
            components["worktree.tar"] = try hashFile(
                "worktree.tar",
                parent: slotFD
            )
            let archived = try TarReader.read(
                readFile(
                    "worktree.tar",
                    parent: slotFD,
                    maximumBytes: Int(Self.maximumBytes)
                )
            ).map(\.entry)
            guard archived == entries else {
                throw GitSafetyError.unsafeRepository(
                    "worktree archive manifest is incomplete"
                )
            }
            includedPaths = entries.map(\.path)
            let location = try indexLocation(
                handle: target,
                worktree: worktree
            )
            indexSnapshot = try captureIndex(
                location: location,
                objectIDBytes:
                    (candidate.expectedOID?.count ?? 40) / 2,
                destination: slotFD
            )
            if let indexSnapshot {
                components["index.snapshot"] =
                    indexSnapshot.componentSHA256
            }
            statusData = try runGit(
                [
                    "-C", target.worktreePath,
                    "status", "--porcelain=v2", "-z",
                    "--untracked-files=all",
                    "--ignored=matching",
                ],
                cwd: target.worktreeDescriptor,
                environment: environment,
                cancellation: cancellation,
                operation: "capture source status"
            ).stdout
        }

        var bundleCreated = false
        if let tip = candidate.expectedOID {
            try checkCancellation(cancellation)
            let revision = candidate.branch?.fullRef
                ?? candidate.worktree?.attachedBranchRef
                ?? tip
            let bundlePath = slotPath + "/branch.bundle"
            _ = try runGit(
                [
                    "--git-dir",
                    primary.identity.commonDirectoryPath,
                    "bundle", "create", bundlePath,
                    revision,
                ],
                cwd: primary.worktreeDescriptor,
                environment: environment,
                cancellation: cancellation,
                operation: "create branch bundle"
            )
            try protectAndSync(
                "branch.bundle",
                parent: slotFD
            )
            components["branch.bundle"] = try hashFile(
                "branch.bundle",
                parent: slotFD
            )
            bundleCreated = true
        }

        let proofName = ".restore-proof"
        guard mkdirat(slotFD, proofName, 0o700) == 0 else {
            throw SecureStateError.systemCall(
                "create restore proof directory",
                errno
            )
        }
        let proofFD = try openPrivateDirectory(
            proofName,
            parent: slotFD
        )
        let proofPath = slotPath + "/\(proofName)"
        defer {
            Darwin.close(proofFD)
            try? removeOwnedTree(
                named: proofName,
                parent: slotFD
            )
        }
        let restorePath = proofPath + "/repository"
        var bundleVerified = false
        var connectivityVerified = false
        if bundleCreated, let tip = candidate.expectedOID {
            _ = try runGit(
                [
                    "--git-dir",
                    primary.identity.commonDirectoryPath,
                    "bundle", "verify",
                    slotPath + "/branch.bundle",
                ],
                cwd: primary.worktreeDescriptor,
                environment: environment,
                cancellation: cancellation,
                operation: "verify branch bundle"
            )
            bundleVerified = true
            _ = try runGit(
                [
                    "clone", "--no-hardlinks",
                    slotPath + "/branch.bundle",
                    restorePath,
                ],
                cwd: proofFD,
                environment: environment,
                cancellation: cancellation,
                operation: "restore branch bundle"
            )
            let restoreFD = Darwin.open(
                restorePath,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard restoreFD >= 0 else {
                throw SecureStateError.systemCall(
                    "open restored repository",
                    errno
                )
            }
            defer { Darwin.close(restoreFD) }
            _ = try runGit(
                [
                    "-C", restorePath,
                    "checkout", "--detach", tip,
                ],
                cwd: restoreFD,
                environment: environment,
                cancellation: cancellation,
                operation:
                    "checkout exact restored tip"
            )
            let observed = try runGit(
                [
                    "-C", restorePath,
                    "rev-parse", "--verify",
                    "\(tip)^{commit}",
                ],
                cwd: restoreFD,
                environment: environment,
                cancellation: cancellation,
                operation: "verify restored tip"
            )
            guard String(
                data: observed.stdout,
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == tip.lowercased() else {
                throw GitSafetyError.unsafeRepository(
                    "restored branch tip differs"
                )
            }
            _ = try runGit(
                [
                    "-C", restorePath,
                    "fsck", "--connectivity-only",
                    "--no-dangling",
                ],
                cwd: restoreFD,
                environment: environment,
                cancellation: cancellation,
                operation: "verify restored connectivity"
            )
            connectivityVerified = true
            if candidate.worktree != nil {
                try clearRestoreWorktree(restoreFD)
                try extractTar(
                    sourceName: "worktree.tar",
                    sourceParent: slotFD,
                    destination: restoreFD
                )
                if let indexSnapshot {
                    try restoreIndex(
                        indexSnapshot,
                        sourceParent: slotFD,
                        restoreRoot: restoreFD
                    )
                }
                let restoredEntries = try manifestEntries(
                    descriptor: restoreFD,
                    relativeParent: "",
                    cancellation: cancellation
                )
                guard restoredEntries == entries else {
                    #if SHADOW_SYNC_TESTING
                    let mismatch = zip(
                        entries,
                        restoredEntries
                    ).first {
                        $0.0 != $0.1
                    }.map {
                        "\($0.0.path):\($0.0.kind.rawValue):\($0.0.mode):\($0.0.size) != \($0.1.path):\($0.1.kind.rawValue):\($0.1.mode):\($0.1.size)"
                    } ?? "count \(entries.count) != \(restoredEntries.count)"
                    throw GitSafetyError.unsafeRepository(
                        "restored worktree manifest differs: \(mismatch)"
                    )
                    #else
                    throw GitSafetyError.unsafeRepository(
                        "restored worktree manifest differs"
                    )
                    #endif
                }
                let restoredStatus = try runGit(
                    [
                        "-C", restorePath,
                        "status", "--porcelain=v2", "-z",
                        "--untracked-files=all",
                        "--ignored=matching",
                    ],
                    cwd: restoreFD,
                    environment: environment,
                    cancellation: cancellation,
                    operation: "verify restored status"
                ).stdout
                guard restoredStatus == statusData else {
                    #if SHADOW_SYNC_TESTING
                    let expectedStatus = String(
                        decoding: statusData ?? Data(),
                        as: UTF8.self
                    ).replacingOccurrences(
                        of: "\0",
                        with: "|"
                    )
                    let observedStatus = String(
                        decoding: restoredStatus,
                        as: UTF8.self
                    ).replacingOccurrences(
                        of: "\0",
                        with: "|"
                    )
                    throw GitSafetyError.unsafeRepository(
                        "restored porcelain-v2 status differs: expected \(expectedStatus) observed \(observedStatus)"
                    )
                    #else
                    throw GitSafetyError.unsafeRepository(
                        "restored porcelain-v2 status differs"
                    )
                    #endif
                }
            }
        } else if candidate.worktree != nil {
            throw GitSafetyError.unsafeRepository(
                "worktree recovery lacks exact restorable history"
            )
        }

        if let worktree = candidate.worktree {
            let finalEntries = try manifestEntries(
                descriptor: target.worktreeDescriptor,
                relativeParent: "",
                cancellation: cancellation
            )
            guard finalEntries == entries else {
                throw GitSafetyError.unsafeRepository(
                    "worktree changed while recovery was being proven"
                )
            }
            guard let indexSnapshot else {
                throw GitSafetyError.unsafeRepository(
                    "worktree index snapshot is unavailable"
                )
            }
            try validateCurrentIndex(
                location: try indexLocation(
                    handle: target,
                    worktree: worktree
                ),
                expected: indexSnapshot,
                objectIDBytes:
                    (candidate.expectedOID?.count ?? 40) / 2
            )
            let finalStatus = try runGit(
                [
                    "-C", target.worktreePath,
                    "status", "--porcelain=v2", "-z",
                    "--untracked-files=all",
                    "--ignored=matching",
                ],
                cwd: target.worktreeDescriptor,
                environment: environment,
                cancellation: cancellation,
                operation: "recheck source status"
            ).stdout
            guard finalStatus == statusData else {
                throw GitSafetyError.unsafeRepository(
                    "worktree status changed while recovery was being proven"
                )
            }
        }
        try primary.revalidate()
        try target.revalidate()
        try checkCancellation(cancellation)
        let proof = RetentionRestoreProof(
            verifiedAt: WallClock.timestamp(),
            exactTipOID: candidate.expectedOID,
            bundleVerified: bundleVerified,
            connectivityVerified: connectivityVerified,
            entryManifestVerified:
                candidate.worktree == nil
                    || !entries.isEmpty
                    || components["worktree.tar"] != nil,
            indexVerified:
                candidate.worktree == nil
                    || indexSnapshot != nil,
            statusDigestVerified:
                candidate.worktree == nil
                    || statusData != nil
        )
        let instructions = restoreInstructions(
            artifactID: artifactID,
            candidate: candidate
        )
        let manifest = try RetentionManifest(
            artifactID: artifactID,
            repositoryID: candidate.repository.id,
            cloneID: candidate.clone.id,
            commonDirectoryIdentity:
                candidate.clone.commonDirectoryIdentity,
            worktreeID: candidate.worktree?.id,
            worktreeRootIdentity:
                candidate.worktree?.rootIdentity,
            registrationIdentity:
                candidate.worktree?.registrationIdentity,
            branchRef: candidate.branch?.fullRef
                ?? candidate.worktree?.attachedBranchRef,
            tipOID: candidate.expectedOID,
            objectFormat:
                candidate.expectedOID?.count == 64
                    ? "sha256" : "sha1",
            entries: entries,
            indexSHA256: indexSnapshot?.indexSHA256,
            sharedIndexFiles:
                indexSnapshot?.sharedFiles ?? [:],
            statusSHA256: statusData.map(Self.sha256),
            includedPaths: includedPaths,
            excludedPaths: [],
            secretShapedPaths:
                includedPaths.filter(RetentionPath.isSecretShaped),
            possibleSecretsAuthorized: true,
            createdAt: WallClock.timestamp(),
            componentSHA256: components,
            restoreProof: proof,
            restoreInstructions: instructions
        )
        let encoded = try JSONEncoder.retention.encode(manifest)
        let manifestFD = try createArtifactFile(
            "manifest.json",
            parent: slotFD
        )
        do {
            try writeAll(encoded, to: manifestFD)
            try finishArtifactFile(manifestFD)
        } catch {
            Darwin.close(manifestFD)
            throw error
        }
        guard fsync(slotFD) == 0 else {
            throw SecureStateError.systemCall(
                "fsync retention artifact",
                errno
            )
        }
        return RetentionArtifactSummary(
            manifest: manifest,
            path: state.path
                + "/retention/\(artifactID)"
        )
    }

    private struct EnumerationResult {
        let entries: [RetentionEntry]
        let totalBytes: UInt64
    }

    private func enumerateWorktree(
        descriptor: Int32,
        relativeParent: String,
        writer: inout TarWriter,
        count: inout [String],
        totalBytes: UInt64,
        cancellation: CancellationToken
    ) throws -> EnumerationResult {
        var directoryBefore = stat()
        guard fstat(descriptor, &directoryBefore) == 0,
              FileIdentity(directoryBefore).isDirectory,
              directoryBefore.st_uid == account.uid else {
            throw GitSafetyError.unsafeRepository(
                "retained directory is unreadable or unowned"
            )
        }
        var entries: [RetentionEntry] = []
        var accumulated = totalBytes
        for name in try directoryNames(descriptor) {
            try checkCancellation(cancellation)
            if relativeParent.isEmpty && name == ".git" {
                continue
            }
            let relative = relativeParent.isEmpty
                ? name : relativeParent + "/" + name
            guard RetentionPath.isSafeRelative(relative),
                  count.count < Self.maximumEntries else {
                throw GitSafetyError.unsafeRepository(
                    "retention entry bound exceeded"
                )
            }
            var before = stat()
            guard fstatat(
                descriptor,
                name,
                &before,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            before.st_uid == account.uid else {
                throw GitSafetyError.unsafeRepository(
                    "retention entry is unreadable or unowned"
                )
            }
            let kind = before.st_mode & S_IFMT
            if kind == S_IFDIR {
                let child = openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard child >= 0 else {
                    throw SecureStateError.systemCall(
                        "open retained directory",
                        errno
                    )
                }
                let entry = try RetentionEntry(
                    path: relative,
                    kind: .directory,
                    mode: UInt16(before.st_mode & 0o7777),
                    size: 0,
                    symlinkTarget: nil,
                    contentSHA256: nil
                )
                try writer.appendDirectory(entry)
                entries.append(entry)
                count.append(relative)
                let nested: EnumerationResult
                do {
                    nested = try enumerateWorktree(
                        descriptor: child,
                        relativeParent: relative,
                        writer: &writer,
                        count: &count,
                        totalBytes: accumulated,
                        cancellation: cancellation
                    )
                } catch {
                    Darwin.close(child)
                    throw error
                }
                Darwin.close(child)
                entries.append(contentsOf: nested.entries)
                accumulated = nested.totalBytes
            } else if kind == S_IFREG {
                guard before.st_nlink == 1,
                      before.st_size >= 0 else {
                    throw GitSafetyError.unsafeRepository(
                        "hard-linked retained files are unsupported"
                    )
                }
                accumulated += UInt64(before.st_size)
                guard accumulated <= Self.maximumBytes else {
                    throw GitSafetyError.unsafeRepository(
                        "retention byte bound exceeded"
                    )
                }
                let file = openat(
                    descriptor,
                    name,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                )
                guard file >= 0 else {
                    throw SecureStateError.systemCall(
                        "open retained file",
                        errno
                    )
                }
                let data: Data
                do {
                    data = try readDescriptor(
                        file,
                        maximumBytes: Int(before.st_size)
                    )
                } catch {
                    Darwin.close(file)
                    throw error
                }
                var after = stat()
                let stable = fstat(file, &after) == 0
                    && Self.sameSnapshot(before, after)
                Darwin.close(file)
                var pathAfter = stat()
                guard stable,
                      fstatat(
                        descriptor,
                        name,
                        &pathAfter,
                        AT_SYMLINK_NOFOLLOW
                      ) == 0,
                      Self.sameSnapshot(before, pathAfter) else {
                    throw GitSafetyError.unsafeRepository(
                        "retained file changed during capture"
                    )
                }
                let entry = try RetentionEntry(
                    path: relative,
                    kind: .regular,
                    mode: UInt16(before.st_mode & 0o7777),
                    size: UInt64(data.count),
                    symlinkTarget: nil,
                    contentSHA256: Self.sha256(data)
                )
                try writer.appendFile(entry, data: data)
                entries.append(entry)
                count.append(relative)
            } else if kind == S_IFLNK {
                guard let target = try readLink(
                    name,
                    parent: descriptor
                ),
                RetentionPath.symlinkIsContained(
                    path: relative,
                    target: target
                ) else {
                    throw GitSafetyError.unsafeRepository(
                        "escaping retained symlink is unsupported"
                    )
                }
                var pathAfter = stat()
                guard fstatat(
                    descriptor,
                    name,
                    &pathAfter,
                    AT_SYMLINK_NOFOLLOW
                ) == 0,
                Self.sameSnapshot(before, pathAfter) else {
                    throw GitSafetyError.unsafeRepository(
                        "retained symlink changed during capture"
                    )
                }
                let entry = try RetentionEntry(
                    path: relative,
                    kind: .symbolicLink,
                    mode: UInt16(before.st_mode & 0o7777),
                    size: 0,
                    symlinkTarget: target,
                    contentSHA256: nil
                )
                try writer.appendSymlink(entry)
                entries.append(entry)
                count.append(relative)
            } else {
                throw GitSafetyError.unsafeRepository(
                    "special retained file is unsupported"
                )
            }
        }
        var directoryAfter = stat()
        guard fstat(descriptor, &directoryAfter) == 0,
              Self.sameSnapshot(
                directoryBefore,
                directoryAfter
              ) else {
            throw GitSafetyError.unsafeRepository(
                "retained directory changed during capture"
            )
        }
        return EnumerationResult(
            entries: entries.sorted { $0.path < $1.path },
            totalBytes: accumulated
        )
    }

    private struct IndexLocation {
        let directoryFD: Int32
        let commonDirectoryFD: Int32
    }

    private struct IndexSnapshot {
        let indexSHA256: String
        let sharedFiles: [String: String]
        let componentSHA256: String
    }

    private func indexLocation(
        handle: RepositoryHandle,
        worktree: Worktree
    ) throws -> IndexLocation {
        _ = worktree
        let directory =
            try handle.duplicateIndexDirectoryDescriptor()
        do {
            return IndexLocation(
                directoryFD: directory,
                commonDirectoryFD:
                    try handle
                        .duplicateCommonDirectoryDescriptor()
            )
        } catch {
            Darwin.close(directory)
            throw error
        }
    }

    private func captureIndex(
        location: IndexLocation,
        objectIDBytes: Int,
        destination: Int32
    ) throws -> IndexSnapshot {
        defer { Darwin.close(location.directoryFD) }
        defer { Darwin.close(location.commonDirectoryFD) }
        let index = try readFile(
            "index",
            parent: location.directoryFD,
            maximumBytes: 67_108_864
        )
        let shared = try GitIndexValidator.validate(
            index,
            objectIDBytes: objectIDBytes
        )
        guard mkdirat(
            destination,
            "index.snapshot",
            0o700
        ) == 0 else {
            throw SecureStateError.systemCall(
                "create index snapshot",
                errno
            )
        }
        let snapshot = try openPrivateDirectory(
            "index.snapshot",
            parent: destination
        )
        defer { Darwin.close(snapshot) }
        let indexFD = try createArtifactFile(
            "index",
            parent: snapshot
        )
        do {
            try writeAll(index, to: indexFD)
            try finishArtifactFile(indexFD)
        } catch {
            Darwin.close(indexFD)
            throw error
        }
        var sharedFiles: [String: String] = [:]
        for hash in shared {
            let name = "sharedindex.\(hash)"
            let source: Int32
            do {
                source = try openSharedIndex(
                    named: name,
                    location: location
                )
            } catch {
                throw error
            }
            let data: Data
            do {
                data = try readDescriptor(
                    source,
                    maximumBytes: 67_108_864
                )
            } catch {
                Darwin.close(source)
                throw error
            }
            Darwin.close(source)
            let nestedDependencies =
                try GitIndexValidator.validate(
                data,
                objectIDBytes: objectIDBytes
            )
            guard nestedDependencies.isEmpty else {
                throw GitSafetyError.unsafeRepository(
                    "nested shared index dependencies are unsupported"
                )
            }
            let file = try createArtifactFile(
                name,
                parent: snapshot
            )
            do {
                try writeAll(data, to: file)
                try finishArtifactFile(file)
            } catch {
                Darwin.close(file)
                throw error
            }
            sharedFiles[name] = Self.sha256(data)
        }
        guard fsync(snapshot) == 0 else {
            throw SecureStateError.systemCall(
                "fsync index snapshot",
                errno
            )
        }
        let indexHash = Self.sha256(index)
        let component = Self.sha256(
            Data(
                (
                    [indexHash]
                        + sharedFiles.keys.sorted().map {
                            "\($0):\(sharedFiles[$0]!)"
                        }
                ).joined(separator: "\n").utf8
            )
        )
        return IndexSnapshot(
            indexSHA256: indexHash,
            sharedFiles: sharedFiles,
            componentSHA256: component
        )
    }

    private func validateCurrentIndex(
        location: IndexLocation,
        expected: IndexSnapshot,
        objectIDBytes: Int
    ) throws {
        defer { Darwin.close(location.directoryFD) }
        defer { Darwin.close(location.commonDirectoryFD) }
        let index = try readFile(
            "index",
            parent: location.directoryFD,
            maximumBytes: 67_108_864
        )
        let shared = try GitIndexValidator.validate(
            index,
            objectIDBytes: objectIDBytes
        ).map { "sharedindex.\($0)" }
        guard Self.sha256(index) == expected.indexSHA256,
              Set(shared) == Set(expected.sharedFiles.keys) else {
            throw GitSafetyError.unsafeRepository(
                "index changed while recovery was being proven"
            )
        }
        for name in shared {
            let descriptor = try openSharedIndex(
                named: name,
                location: location
            )
            let data: Data
            do {
                data = try readDescriptor(
                    descriptor,
                    maximumBytes: 67_108_864
                )
                Darwin.close(descriptor)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            guard Self.sha256(data)
                    == expected.sharedFiles[name],
                  try GitIndexValidator.validate(
                      data,
                      objectIDBytes: objectIDBytes
                  ).isEmpty else {
                throw GitSafetyError.unsafeRepository(
                    "shared index changed or has unsupported dependencies"
                )
            }
        }
    }

    private func openSharedIndex(
        named name: String,
        location: IndexLocation
    ) throws -> Int32 {
        let local = openat(
            location.directoryFD,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if local >= 0 { return local }
        let file = openat(
            location.commonDirectoryFD,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard file >= 0 else {
            throw SecureStateError.systemCall(
                "open required shared index",
                errno
            )
        }
        return file
    }

    private func runGit(
        _ arguments: [String],
        cwd: Int32,
        environment: [String: String],
        cancellation: CancellationToken,
        operation: String
    ) throws -> ProcessResult {
        try RetentionGitCommandPolicy.validate(arguments)
        let result = try runner.run(
            command: ClosedProcessCommand(
                executable: "/usr/bin/git",
                arguments: arguments
            ),
            environment: environment,
            workingDirectoryDescriptor: cwd,
            account: account,
            timeout: 120,
            cancellation: cancellation
        )
        guard result.succeeded,
              !result.stdoutTruncated,
              !result.stderrTruncated else {
            if result.cancelled {
                throw GitSafetyError.cancelled
            }
            throw GitSafetyError.commandFailed(
                operation,
                result.status,
                result.diagnostic
            )
        }
        return result
    }

    private func restoreInstructions(
        artifactID: String,
        candidate: RemovalCandidate
    ) -> [String] {
        var result = [
            "Keep retention/\(artifactID) intact.",
        ]
        if candidate.expectedOID != nil {
            result.append(
                "Clone branch.bundle into a new private directory and verify the recorded exact tip before use."
            )
        }
        if candidate.worktree != nil {
            result.append(
                "Extract worktree.tar into that private clone, then restore index.snapshot/index and every recorded sharedindex file into its Git directory."
            )
            result.append(
                "Verify manifest hashes, modes, symlink targets, index digest, and porcelain-v2 status before resuming work."
            )
        }
        return result
    }

    private func boundedOmissions(
        _ candidate: RemovalCandidate
    ) -> [String] {
        var result: [String] = []
        if candidate.expectedOID != nil {
            result.append("branch.bundle")
        }
        if candidate.worktree != nil {
            result.append("worktree.tar")
            result.append("index.snapshot")
            if let paths = try? omissionPaths(
                candidate
            ) {
                result.append(contentsOf: paths)
            }
        }
        return Array(Set(result)).sorted().prefix(100)
            .map { $0 }
    }

    private func omissionPaths(
        _ candidate: RemovalCandidate
    ) throws -> [String] {
        guard let worktree = candidate.worktree,
              worktree.verification == .verified,
              let expected = worktree.rootIdentity else {
            return []
        }
        let root = Darwin.open(
            worktree.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard root >= 0 else {
            throw SecureStateError.systemCall(
                "open omitted worktree",
                errno
            )
        }
        defer { Darwin.close(root) }
        var info = stat()
        guard fstat(root, &info) == 0,
              RepositoryDirectoryIdentity(
                FileIdentity(info)
              ) == expected else {
            throw GitSafetyError.unsafeRepository(
                "omission inventory identity changed"
            )
        }
        var result: [String] = []
        try collectOmissionPaths(
            descriptor: root,
            prefix: "",
            result: &result
        )
        return result.sorted()
    }

    private func collectOmissionPaths(
        descriptor: Int32,
        prefix: String,
        result: inout [String]
    ) throws {
        guard result.count <= Self.maximumEntries else {
            throw GitSafetyError.unsafeRepository(
                "omission inventory is too large"
            )
        }
        let duplicate = openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard duplicate >= 0,
              let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw SecureStateError.systemCall(
                "enumerate omitted worktree",
                errno
            )
        }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            let name = withUnsafePointer(
                to: &entry.pointee.d_name
            ) {
                $0.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".."
                || (prefix.isEmpty && name == ".git") {
                continue
            }
            let path = prefix.isEmpty
                ? name : prefix + "/" + name
            guard RetentionPath.isSafeRelative(path) else {
                throw GitSafetyError.unsafeRepository(
                    "unsafe omission path"
                )
            }
            var info = stat()
            guard fstatat(
                descriptor,
                name,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw SecureStateError.systemCall(
                    "inspect omitted worktree entry",
                    errno
                )
            }
            result.append(path)
            if (info.st_mode & S_IFMT) == S_IFDIR {
                let child = openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY
                        | O_NOFOLLOW | O_CLOEXEC
                )
                guard child >= 0 else {
                    throw SecureStateError.systemCall(
                        "open omitted worktree directory",
                        errno
                    )
                }
                do {
                    try collectOmissionPaths(
                        descriptor: child,
                        prefix: path,
                        result: &result
                    )
                    Darwin.close(child)
                } catch {
                    Darwin.close(child)
                    throw error
                }
            }
        }
    }

    private func ensureRetentionDirectory() throws -> Int32 {
        if mkdirat(
            state.descriptor.value,
            "retention",
            0o700
        ) != 0, errno != EEXIST {
            throw SecureStateError.systemCall(
                "create retention directory",
                errno
            )
        }
        return try openPrivateDirectory(
            "retention",
            parent: state.descriptor.value
        )
    }

    private func openPrivateDirectory(
        _ name: String,
        parent: Int32,
        requireExactMode: Bool = true
    ) throws -> Int32 {
        guard RetentionPath.isComponent(name) else {
            throw SecureStateError.unsafePath(name)
        }
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SecureStateError.systemCall(
                "open private retention directory",
                errno
            )
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              FileIdentity(info).isDirectory,
              info.st_uid == account.uid,
              (
                requireExactMode
                    ? (info.st_mode & 0o777)
                        == 0o700
                    : (info.st_mode & 0o077) == 0
              ) else {
            Darwin.close(descriptor)
            throw SecureStateError.unsafePath(name)
        }
        return descriptor
    }

    private func createArtifactFile(
        _ name: String,
        parent: Int32
    ) throws -> Int32 {
        guard RetentionPath.isComponent(name) else {
            throw SecureStateError.unsafePath(name)
        }
        let descriptor = openat(
            parent,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o400
        )
        guard descriptor >= 0 else {
            throw SecureStateError.systemCall(
                "create retention component",
                errno
            )
        }
        return descriptor
    }

    private func finishArtifactFile(_ descriptor: Int32) throws {
        guard fchmod(descriptor, 0o400) == 0,
              fsync(descriptor) == 0 else {
            throw SecureStateError.systemCall(
                "finish retention component",
                errno
            )
        }
        Darwin.close(descriptor)
    }

    private func protectAndSync(
        _ name: String,
        parent: Int32
    ) throws {
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SecureStateError.systemCall(
                "open retention component",
                errno
            )
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              FileIdentity(info).isRegular,
              info.st_uid == account.uid,
              info.st_nlink == 1,
              fchmod(descriptor, 0o400) == 0,
              fsync(descriptor) == 0 else {
            throw GitSafetyError.unsafeRepository(
                "retention component is unsafe"
            )
        }
    }

    private func hashFile(
        _ name: String,
        parent: Int32
    ) throws -> String {
        Self.sha256(
            try readFile(
                name,
                parent: parent,
                maximumBytes: Int(Self.maximumBytes),
                requireProtectedArtifact: true
            )
        )
    }

    private func readFile(
        _ name: String,
        parent: Int32,
        maximumBytes: Int,
        requireProtectedArtifact: Bool = false
    ) throws -> Data {
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SecureStateError.systemCall(
                "open retained component",
                errno
            )
        }
        defer { Darwin.close(descriptor) }
        return try readDescriptor(
            descriptor,
            maximumBytes: maximumBytes,
            requireProtectedArtifact:
                requireProtectedArtifact
        )
    }

    private func readDescriptor(
        _ descriptor: Int32,
        maximumBytes: Int,
        requireProtectedArtifact: Bool = false
    ) throws -> Data {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              FileIdentity(info).isRegular,
              info.st_uid == account.uid,
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= maximumBytes,
              !requireProtectedArtifact
                || (
                    (info.st_mode & 0o777)
                            == 0o400
                ) else {
            throw GitSafetyError.unsafeRepository(
                "retained file exceeds its bound"
            )
        }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(
                descriptor,
                &bytes,
                bytes.count
            )
            if count > 0 {
                data.append(contentsOf: bytes.prefix(count))
                guard data.count <= maximumBytes else {
                    throw GitSafetyError.unsafeRepository(
                        "retained file exceeds its bound"
                    )
                }
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw SecureStateError.systemCall(
                "read retained file",
                errno
            )
        }
        var finalInfo = stat()
        guard fstat(descriptor, &finalInfo) == 0,
              Self.sameSnapshot(info, finalInfo) else {
            throw GitSafetyError.unsafeRepository(
                "retained file changed while read"
            )
        }
        return data
    }

    private func writeAll(
        _ data: Data,
        to descriptor: Int32
    ) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    raw.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw SecureStateError.systemCall(
                        "write retention component",
                        errno
                    )
                }
            }
        }
    }

    private func directoryNames(
        _ descriptor: Int32
    ) throws -> [String] {
        let duplicate = openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard duplicate >= 0,
              let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw GitSafetyError.unsafeRepository(
                "retention directory cannot be enumerated"
            )
        }
        defer { closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(
                to: &entry.pointee.d_name
            ) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(cString: $0) }
            }
            if name != ".", name != ".." {
                names.append(name)
            }
            errno = 0
        }
        guard errno == 0,
              names.count <= Self.maximumEntries else {
            throw GitSafetyError.unsafeRepository(
                "retention directory enumeration failed"
            )
        }
        return names.sorted()
    }

    private func readLink(
        _ name: String,
        parent: Int32
    ) throws -> String? {
        var bytes = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let count = readlinkat(
            parent,
            name,
            &bytes,
            bytes.count
        )
        guard count >= 0, count < bytes.count,
              let value = String(
                bytes: bytes.prefix(count),
                encoding: .utf8
              ),
              !value.contains("\0") else {
            throw GitSafetyError.unsafeRepository(
                "retained symlink target is malformed"
            )
        }
        return value
    }

    private func removeOwnedTree(
        named name: String,
        parent: Int32
    ) throws {
        guard name.hasPrefix(".incomplete-")
                || name == ".restore-proof"
                || name == "repository" else {
            throw SecureStateError.unsafePath(name)
        }
        let directory = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else {
            if errno == ENOENT { return }
            throw SecureStateError.systemCall(
                "open incomplete retention tree",
                errno
            )
        }
        for child in try directoryNames(directory) {
            var info = stat()
            guard fstatat(
                directory,
                child,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            info.st_uid == account.uid else {
                Darwin.close(directory)
                throw SecureStateError.unsafePath(child)
            }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                try removeAnyOwnedDirectory(
                    named: child,
                    parent: directory
                )
            } else {
                guard unlinkat(directory, child, 0) == 0 else {
                    Darwin.close(directory)
                    throw SecureStateError.systemCall(
                        "remove incomplete retention file",
                        errno
                    )
                }
            }
        }
        Darwin.close(directory)
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
            throw SecureStateError.systemCall(
                "remove incomplete retention directory",
                errno
            )
        }
    }

    private func removeAnyOwnedDirectory(
        named name: String,
        parent: Int32
    ) throws {
        let directory = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else {
            throw SecureStateError.systemCall(
                "open owned scratch directory",
                errno
            )
        }
        for child in try directoryNames(directory) {
            var info = stat()
            guard fstatat(
                directory,
                child,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            info.st_uid == account.uid else {
                Darwin.close(directory)
                throw SecureStateError.unsafePath(child)
            }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                try removeAnyOwnedDirectory(
                    named: child,
                    parent: directory
                )
            } else {
                guard unlinkat(directory, child, 0) == 0 else {
                    Darwin.close(directory)
                    throw SecureStateError.systemCall(
                        "remove owned scratch entry",
                        errno
                    )
                }
            }
        }
        Darwin.close(directory)
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
            throw SecureStateError.systemCall(
                "remove owned scratch directory",
                errno
            )
        }
    }

    private func clearRestoreWorktree(_ root: Int32) throws {
        for name in try directoryNames(root) where name != ".git" {
            var info = stat()
            guard fstatat(
                root,
                name,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw SecureStateError.systemCall(
                    "inspect restore worktree",
                    errno
                )
            }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                try removeAnyOwnedDirectory(
                    named: name,
                    parent: root
                )
            } else {
                guard unlinkat(root, name, 0) == 0 else {
                    throw SecureStateError.systemCall(
                        "clear restore worktree",
                        errno
                    )
                }
            }
        }
    }

    private func extractTar(
        sourceName: String,
        sourceParent: Int32,
        destination: Int32
    ) throws {
        let data = try readFile(
            sourceName,
            parent: sourceParent,
            maximumBytes: Int(Self.maximumBytes),
            requireProtectedArtifact: true
        )
        for record in try TarReader.read(data) {
            try createParents(
                for: record.entry.path,
                root: destination
            )
            let parts = record.entry.path.split(
                separator: "/"
            ).map(String.init)
            let parent = try openRelativeDirectory(
                Array(parts.dropLast()),
                root: destination
            )
            let name = parts.last!
            do {
                switch record.entry.kind {
                case .directory:
                    if mkdirat(
                        parent,
                        name,
                        mode_t(record.entry.mode)
                    ) != 0, errno != EEXIST {
                        throw SecureStateError.systemCall(
                            "restore retained directory",
                            errno
                        )
                    }
                    let restoredDirectory = openat(
                        parent,
                        name,
                        O_RDONLY | O_DIRECTORY
                            | O_NOFOLLOW | O_CLOEXEC
                    )
                    guard restoredDirectory >= 0 else {
                        throw SecureStateError.systemCall(
                            "open restored directory",
                            errno
                        )
                    }
                    guard fchmod(
                        restoredDirectory,
                        mode_t(record.entry.mode)
                    ) == 0 else {
                        let code = errno
                        Darwin.close(restoredDirectory)
                        throw SecureStateError.systemCall(
                            "restore retained directory mode",
                            code
                        )
                    }
                    Darwin.close(restoredDirectory)
                case .regular:
                    let file = openat(
                        parent,
                        name,
                        O_WRONLY | O_CREAT | O_EXCL
                            | O_NOFOLLOW | O_CLOEXEC,
                        mode_t(record.entry.mode)
                    )
                    guard file >= 0 else {
                        throw SecureStateError.systemCall(
                            "restore retained file",
                            errno
                        )
                    }
                    do {
                        try writeAll(record.data, to: file)
                        guard fchmod(
                            file,
                            mode_t(record.entry.mode)
                        ) == 0 else {
                            throw SecureStateError.systemCall(
                                "restore retained mode",
                                errno
                            )
                        }
                        Darwin.close(file)
                    } catch {
                        Darwin.close(file)
                        throw error
                    }
                case .symbolicLink:
                    guard let target =
                            record.entry.symlinkTarget,
                          symlinkat(
                            target,
                            parent,
                            name
                          ) == 0 else {
                        throw SecureStateError.systemCall(
                            "restore retained symlink",
                            errno
                        )
                    }
                }
            } catch {
                Darwin.close(parent)
                throw error
            }
            Darwin.close(parent)
        }
    }

    private func createParents(
        for path: String,
        root: Int32
    ) throws {
        let components = path.split(separator: "/")
            .dropLast().map(String.init)
        var current = dup(root)
        guard current >= 0 else {
            throw SecureStateError.systemCall(
                "retain restore root",
                errno
            )
        }
        defer { Darwin.close(current) }
        for component in components {
            if mkdirat(current, component, 0o700) != 0,
               errno != EEXIST {
                throw SecureStateError.systemCall(
                    "create restore parent",
                    errno
                )
            }
            let next = openat(
                current,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard next >= 0 else {
                throw SecureStateError.systemCall(
                    "open restore parent",
                    errno
                )
            }
            Darwin.close(current)
            current = next
        }
    }

    private func openRelativeDirectory(
        _ components: [String],
        root: Int32
    ) throws -> Int32 {
        var current = dup(root)
        guard current >= 0 else {
            throw SecureStateError.systemCall(
                "retain relative root",
                errno
            )
        }
        for component in components {
            let next = openat(
                current,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard next >= 0 else {
                Darwin.close(current)
                throw SecureStateError.systemCall(
                    "open relative directory",
                    errno
                )
            }
            Darwin.close(current)
            current = next
        }
        return current
    }

    private func restoreIndex(
        _ snapshot: IndexSnapshot,
        sourceParent: Int32,
        restoreRoot: Int32
    ) throws {
        let source = try openPrivateDirectory(
            "index.snapshot",
            parent: sourceParent
        )
        defer { Darwin.close(source) }
        let git = try openPrivateDirectory(
            ".git",
            parent: restoreRoot,
            requireExactMode: false
        )
        defer { Darwin.close(git) }
        let names = ["index"]
            + snapshot.sharedFiles.keys.sorted()
        for name in names {
            let data = try readFile(
                name,
                parent: source,
                maximumBytes: 67_108_864,
                requireProtectedArtifact: true
            )
            _ = unlinkat(git, name, 0)
            let output = openat(
                git,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
            guard output >= 0 else {
                throw SecureStateError.systemCall(
                    "restore index snapshot",
                    errno
                )
            }
            do {
                try writeAll(data, to: output)
                Darwin.close(output)
            } catch {
                Darwin.close(output)
                throw error
            }
        }
    }

    private func manifestEntries(
        descriptor: Int32,
        relativeParent: String,
        cancellation: CancellationToken
    ) throws -> [RetentionEntry] {
        var entries: [RetentionEntry] = []
        for name in try directoryNames(descriptor) {
            try checkCancellation(cancellation)
            if relativeParent.isEmpty && name == ".git" {
                continue
            }
            let relative = relativeParent.isEmpty
                ? name : relativeParent + "/" + name
            var info = stat()
            guard fstatat(
                descriptor,
                name,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw SecureStateError.systemCall(
                    "inspect restored entry",
                    errno
                )
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                let child = openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard child >= 0 else {
                    throw SecureStateError.systemCall(
                        "open restored directory",
                        errno
                    )
                }
                entries.append(try RetentionEntry(
                    path: relative,
                    kind: .directory,
                    mode: UInt16(info.st_mode & 0o7777),
                    size: 0,
                    symlinkTarget: nil,
                    contentSHA256: nil
                ))
                entries.append(
                    contentsOf: try manifestEntries(
                        descriptor: child,
                        relativeParent: relative,
                        cancellation: cancellation
                    )
                )
                Darwin.close(child)
            case S_IFREG:
                let data = try readFile(
                    name,
                    parent: descriptor,
                    maximumBytes: Int(Self.maximumBytes)
                )
                entries.append(try RetentionEntry(
                    path: relative,
                    kind: .regular,
                    mode: UInt16(info.st_mode & 0o7777),
                    size: UInt64(data.count),
                    symlinkTarget: nil,
                    contentSHA256: Self.sha256(data)
                ))
            case S_IFLNK:
                entries.append(try RetentionEntry(
                    path: relative,
                    kind: .symbolicLink,
                    mode: UInt16(info.st_mode & 0o7777),
                    size: 0,
                    symlinkTarget: try readLink(
                        name,
                        parent: descriptor
                    ),
                    contentSHA256: nil
                ))
            default:
                throw GitSafetyError.unsafeRepository(
                    "restored special file is invalid"
                )
            }
        }
        return entries.sorted { $0.path < $1.path }
    }

    private func checkCancellation(
        _ cancellation: CancellationToken
    ) throws {
        if cancellation.isCancelled {
            throw GitSafetyError.cancelled
        }
    }

    private static func sameSnapshot(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec
                == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec
                == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec
                == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec
                == rhs.st_ctimespec.tv_nsec
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

private enum RetentionPath {
    static func isComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\0")
    }

    static func isSafeRelative(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("/")
            && !value.contains("\0")
            && value.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    static func isOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy {
                $0.isNumber
                    || ("a"..."f").contains($0.lowercased())
            }
    }

    static func isArtifactID(_ value: String) -> Bool {
        value.hasPrefix("ret-")
            && value.count <= 80
            && value.allSatisfy {
                $0.isLowercase || $0.isNumber || $0 == "-"
            }
    }

    static func isSecretShaped(_ path: String) -> Bool {
        let value = path.lowercased()
        let leaf = value.split(separator: "/").last.map(String.init)
            ?? value
        return leaf == ".env"
            || leaf.hasPrefix(".env.")
            || value.contains("credential")
            || value.contains("secret")
            || value.contains("token")
            || value.contains("private-key")
            || value.contains("id_rsa")
            || value.contains("id_ed25519")
            || [".pem", ".p12", ".pfx", ".key"].contains {
                leaf.hasSuffix($0)
            }
    }

    static func symlinkIsContained(
        path: String,
        target: String
    ) -> Bool {
        guard !target.hasPrefix("/"),
              !target.contains("\0") else {
            return false
        }
        var components = path.split(separator: "/")
            .dropLast().map(String.init)
        for component in target.split(
            separator: "/",
            omittingEmptySubsequences: false
        ) {
            if component.isEmpty || component == "." {
                continue
            }
            if component == ".." {
                guard !components.isEmpty else { return false }
                components.removeLast()
            } else {
                components.append(String(component))
            }
        }
        return true
    }
}

private enum RetentionGitCommandPolicy {
    static func validate(_ arguments: [String]) throws {
        guard !arguments.isEmpty,
              !arguments.contains(where: {
                  $0.contains("\0")
                    || $0.contains("\n")
                    || $0.contains("\r")
              }) else {
            throw GitSafetyError.unsafeRepository(
                "retention Git arguments are invalid"
            )
        }
        let valid =
            (
                arguments.count == 6
                    && arguments[0] == "--git-dir"
                    && isAbsolutePath(arguments[1])
                    && arguments[2] == "bundle"
                    && arguments[3] == "create"
                    && isBundlePath(arguments[4])
                    && (
                        GitReferenceSyntax
                            .isValidLocalBranchRef(
                                arguments[5]
                            )
                            || RetentionPath.isOID(
                                arguments[5]
                            )
                    )
            )
            || (
                arguments.count == 5
                    && arguments[0] == "--git-dir"
                    && isAbsolutePath(arguments[1])
                    && arguments[2] == "bundle"
                    && arguments[3] == "verify"
                    && isBundlePath(arguments[4])
            )
            || (
                arguments.count == 4
                    && arguments[0] == "clone"
                    && arguments[1] == "--no-hardlinks"
                    && isBundlePath(arguments[2])
                    && isAbsolutePath(arguments[3])
                    && arguments[3].hasSuffix(
                        "/.restore-proof/repository"
                    )
            )
            || (
                arguments.count == 5
                    && arguments[0] == "-C"
                    && isAbsolutePath(arguments[1])
                    && arguments[2] == "rev-parse"
                    && arguments[3] == "--verify"
                    && arguments[4].hasSuffix(
                        "^{commit}"
                    )
                    && RetentionPath.isOID(
                        String(
                            arguments[4].dropLast(
                                "^{commit}".count
                            )
                        )
                    )
            )
            || (
                arguments.count == 5
                    && arguments[0] == "-C"
                    && isAbsolutePath(arguments[1])
                    && arguments[2] == "checkout"
                    && arguments[3] == "--detach"
                    && RetentionPath.isOID(arguments[4])
            )
            || (
                arguments.count == 5
                    && arguments[0] == "-C"
                    && isAbsolutePath(arguments[1])
                    && arguments[2] == "fsck"
                    && arguments[3] == "--connectivity-only"
                    && arguments[4] == "--no-dangling"
            )
            || (
                arguments.count == 7
                    && arguments[0] == "-C"
                    && isAbsolutePath(arguments[1])
                    && arguments[2] == "status"
                    && arguments[3] == "--porcelain=v2"
                    && arguments[4] == "-z"
                    && arguments[5] == "--untracked-files=all"
                    && arguments[6] == "--ignored=matching"
            )
        guard valid,
              !arguments.contains("--force"),
              !arguments.contains("-D"),
              !arguments.contains("push") else {
            throw GitSafetyError.unsafeRepository(
                "retention Git command is outside the closed grammar"
            )
        }
    }

    private static func isBundlePath(
        _ value: String
    ) -> Bool {
        isAbsolutePath(value)
            && value.hasSuffix("/branch.bundle")
            && value.contains(
                "/retention/.incomplete-ret-"
            )
    }

    private static func isAbsolutePath(
        _ value: String
    ) -> Bool {
        value.hasPrefix("/")
            && !value.contains("/../")
            && !value.hasSuffix("/..")
            && !value.contains("/./")
            && !value.hasSuffix("/.")
    }
}

enum GitIndexValidator {
    private struct Inspection {
        let shared: [String]
        let hasHiddenEntries: Bool
    }

    static func validate(
        _ data: Data,
        objectIDBytes: Int
    ) throws -> [String] {
        try inspect(
            data,
            objectIDBytes: objectIDBytes
        ).shared
    }

    static func hiddenEntryState(
        _ data: Data,
        objectIDBytes: Int
    ) throws -> Bool? {
        let inspection = try inspect(
            data,
            objectIDBytes: objectIDBytes
        )
        guard inspection.shared.isEmpty else {
            return nil
        }
        return inspection.hasHiddenEntries
    }

    private static func inspect(
        _ data: Data,
        objectIDBytes: Int
    ) throws -> Inspection {
        guard [20, 32].contains(objectIDBytes),
              data.count >= 12 + objectIDBytes,
              String(data: data.prefix(4), encoding: .ascii)
                == "DIRC" else {
            throw GitSafetyError.unsafeRepository(
                "index snapshot header is invalid"
            )
        }
        let version = integer(data, offset: 4)
        guard version == 2 || version == 3 else {
            throw GitSafetyError.unsafeRepository(
                "unknown index format is unsupported"
            )
        }
        let count = Int(integer(data, offset: 8))
        guard count <= 1_000_000 else {
            throw GitSafetyError.unsafeRepository(
                "index entry bound exceeded"
            )
        }
        var offset = 12
        var hasHiddenEntries = false
        let checksumStart = data.count - objectIDBytes
        let payload = data.prefix(checksumStart)
        let expectedChecksum = data.suffix(objectIDBytes)
        let observedChecksum: Data
        if objectIDBytes == 20 {
            observedChecksum = Data(
                Insecure.SHA1.hash(data: payload)
            )
        } else {
            observedChecksum = Data(
                SHA256.hash(data: payload)
            )
        }
        guard observedChecksum == expectedChecksum else {
            throw GitSafetyError.unsafeRepository(
                "index checksum is invalid"
            )
        }
        for _ in 0..<count {
            let start = offset
            let fixed = 40 + objectIDBytes + 2
            guard offset + fixed <= checksumStart else {
                throw GitSafetyError.unsafeRepository(
                    "index entry is truncated"
                )
            }
            let flags = UInt16(data[offset + fixed - 2]) << 8
                | UInt16(data[offset + fixed - 1])
            if (flags & 0x8000) != 0 {
                hasHiddenEntries = true
            }
            offset += fixed
            if (flags & 0x4000) != 0 {
                guard version >= 3,
                      offset + 2 <= checksumStart else {
                    throw GitSafetyError.unsafeRepository(
                        "extended index entry is truncated"
                    )
                }
                let extendedFlags =
                    UInt16(data[offset]) << 8
                    | UInt16(data[offset + 1])
                if (extendedFlags & 0x4000) != 0 {
                    hasHiddenEntries = true
                }
                offset += 2
            }
            guard let terminator = data[
                offset..<checksumStart
            ].firstIndex(of: 0) else {
                throw GitSafetyError.unsafeRepository(
                    "index pathname is unterminated"
                )
            }
            offset = terminator + 1
            let length = offset - start
            offset += (8 - (length % 8)) % 8
            guard offset <= checksumStart else {
                throw GitSafetyError.unsafeRepository(
                    "index entry padding is invalid"
                )
            }
        }
        let known = Set([
            "TREE", "REUC", "UNTR", "FSMN",
            "EOIE", "IEOT", "link", "sdir",
        ])
        var shared: [String] = []
        while offset < checksumStart {
            guard offset + 8 <= checksumStart,
                  let signature = String(
                    data: data[offset..<(offset + 4)],
                    encoding: .ascii
                  ) else {
                throw GitSafetyError.unsafeRepository(
                    "index extension is malformed"
                )
            }
            let size = Int(integer(data, offset: offset + 4))
            offset += 8
            guard known.contains(signature),
                  size >= 0,
                  offset + size <= checksumStart else {
                throw GitSafetyError.unsafeRepository(
                    "unknown index extension is unsupported"
                )
            }
            if signature == "link" {
                guard size >= objectIDBytes else {
                    throw GitSafetyError.unsafeRepository(
                        "shared index extension is truncated"
                    )
                }
                shared.append(
                    data[offset..<(offset + objectIDBytes)]
                        .map { String(format: "%02x", $0) }
                        .joined()
                )
            }
            offset += size
        }
        guard offset == checksumStart else {
            throw GitSafetyError.unsafeRepository(
                "index extension boundary is invalid"
            )
        }
        return Inspection(
            shared: shared,
            hasHiddenEntries: hasHiddenEntries
        )
    }

    private static func integer(
        _ data: Data,
        offset: Int
    ) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }
}

#if SHADOW_SYNC_TESTING
public enum RetentionArtifactTesting {
    public static func validateIndex(
        _ data: Data,
        objectIDBytes: Int
    ) throws -> [String] {
        try GitIndexValidator.validate(
            data,
            objectIDBytes: objectIDBytes
        )
    }
}
#endif

private struct TarWriter {
    let descriptor: Int32

    mutating func appendDirectory(
        _ entry: RetentionEntry
    ) throws {
        try appendHeader(entry, type: UInt8(ascii: "5"), size: 0)
    }

    mutating func appendSymlink(
        _ entry: RetentionEntry
    ) throws {
        try appendHeader(entry, type: UInt8(ascii: "2"), size: 0)
    }

    mutating func appendFile(
        _ entry: RetentionEntry,
        data: Data
    ) throws {
        try appendHeader(
            entry,
            type: UInt8(ascii: "0"),
            size: data.count
        )
        try write(data)
        let padding = (512 - (data.count % 512)) % 512
        if padding > 0 {
            try write(Data(repeating: 0, count: padding))
        }
    }

    mutating func finish() throws {
        try write(Data(repeating: 0, count: 1_024))
    }

    private mutating func appendHeader(
        _ entry: RetentionEntry,
        type: UInt8,
        size: Int
    ) throws {
        let split = try TarPath.split(entry.path)
        var header = Data(repeating: 0, count: 512)
        put(split.name, into: &header, offset: 0, length: 100)
        putOctal(
            UInt64(entry.mode),
            into: &header,
            offset: 100,
            length: 8
        )
        putOctal(0, into: &header, offset: 108, length: 8)
        putOctal(0, into: &header, offset: 116, length: 8)
        putOctal(
            UInt64(size),
            into: &header,
            offset: 124,
            length: 12
        )
        putOctal(0, into: &header, offset: 136, length: 12)
        for index in 148..<156 { header[index] = 0x20 }
        header[156] = type
        if let target = entry.symlinkTarget {
            put(target, into: &header, offset: 157, length: 100)
        }
        put("ustar\u{0}", into: &header, offset: 257, length: 6)
        put("00", into: &header, offset: 263, length: 2)
        if let prefix = split.prefix {
            put(prefix, into: &header, offset: 345, length: 155)
        }
        let checksum = header.reduce(UInt64(0)) {
            $0 + UInt64($1)
        }
        putOctal(
            checksum,
            into: &header,
            offset: 148,
            length: 8,
            terminator: 0x20
        )
        try write(header)
    }

    private func put(
        _ value: String,
        into data: inout Data,
        offset: Int,
        length: Int
    ) {
        let bytes = Array(value.utf8.prefix(length))
        data.replaceSubrange(
            offset..<(offset + bytes.count),
            with: bytes
        )
    }

    private func putOctal(
        _ value: UInt64,
        into data: inout Data,
        offset: Int,
        length: Int,
        terminator: UInt8 = 0
    ) {
        let text = String(value, radix: 8)
        let padded = String(
            repeating: "0",
            count: max(0, length - text.count - 1)
        ) + text
        put(
            padded,
            into: &data,
            offset: offset,
            length: length - 1
        )
        data[offset + length - 1] = terminator
    }

    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    raw.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw SecureStateError.systemCall(
                        "write worktree tar",
                        errno
                    )
                }
            }
        }
    }
}

private enum TarPath {
    static func split(
        _ path: String
    ) throws -> (name: String, prefix: String?) {
        guard path.utf8.count <= 255 else {
            throw GitSafetyError.unsafeRepository(
                "retained path exceeds ustar bounds"
            )
        }
        if path.utf8.count <= 100 {
            return (path, nil)
        }
        let components = path.split(separator: "/")
        for split in stride(
            from: components.count - 1,
            through: 1,
            by: -1
        ) {
            let prefix = components[..<split]
                .joined(separator: "/")
            let name = components[split...]
                .joined(separator: "/")
            if prefix.utf8.count <= 155,
               name.utf8.count <= 100 {
                return (name, prefix)
            }
        }
        throw GitSafetyError.unsafeRepository(
            "retained path cannot be represented in ustar"
        )
    }
}

private struct TarRecord {
    let entry: RetentionEntry
    let data: Data
}

private enum TarReader {
    static func read(_ data: Data) throws -> [TarRecord] {
        var offset = 0
        var result: [TarRecord] = []
        while offset + 512 <= data.count {
            let header = data[offset..<(offset + 512)]
            if header.allSatisfy({ $0 == 0 }) {
                break
            }
            let expected = try octal(header, offset: 148, length: 8)
            var checksumHeader = Data(header)
            for index in 148..<156 { checksumHeader[index] = 0x20 }
            guard checksumHeader.reduce(UInt64(0), {
                $0 + UInt64($1)
            }) == expected else {
                throw GitSafetyError.unsafeRepository(
                    "worktree tar checksum is invalid"
                )
            }
            let name = text(header, offset: 0, length: 100)
            let prefix = text(header, offset: 345, length: 155)
            let path = prefix.isEmpty
                ? name : prefix + "/" + name
            let mode = try octal(header, offset: 100, length: 8)
            let size = Int(
                try octal(header, offset: 124, length: 12)
            )
            let target = text(header, offset: 157, length: 100)
            let type = header[header.startIndex + 156]
            offset += 512
            guard size >= 0, offset + size <= data.count else {
                throw GitSafetyError.unsafeRepository(
                    "worktree tar entry is truncated"
                )
            }
            let payload = Data(data[offset..<(offset + size)])
            offset += size
            offset += (512 - (size % 512)) % 512
            let kind: RetentionEntryKind
            switch type {
            case UInt8(ascii: "0"), 0: kind = .regular
            case UInt8(ascii: "5"): kind = .directory
            case UInt8(ascii: "2"): kind = .symbolicLink
            default:
                throw GitSafetyError.unsafeRepository(
                    "worktree tar entry type is unsupported"
                )
            }
            let entry = try RetentionEntry(
                path: path,
                kind: kind,
                mode: UInt16(mode),
                size: UInt64(size),
                symlinkTarget:
                    kind == .symbolicLink ? target : nil,
                contentSHA256:
                    kind == .regular
                        ? SHA256.hash(data: payload).map {
                            String(format: "%02x", $0)
                        }.joined()
                        : nil
            )
            result.append(TarRecord(entry: entry, data: payload))
        }
        return result
    }

    private static func text(
        _ data: Data.SubSequence,
        offset: Int,
        length: Int
    ) -> String {
        let start = data.startIndex + offset
        let bytes = data[start..<(start + length)]
            .prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func octal(
        _ data: Data.SubSequence,
        offset: Int,
        length: Int
    ) throws -> UInt64 {
        let value = text(data, offset: offset, length: length)
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .trimmingCharacters(in: CharacterSet(
                charactersIn: "\0"
            ))
        guard value.isEmpty
                || value.allSatisfy({ ("0"..."7").contains($0) }),
              let parsed = UInt64(value.isEmpty ? "0" : value, radix: 8)
        else {
            throw GitSafetyError.unsafeRepository(
                "worktree tar numeric field is invalid"
            )
        }
        return parsed
    }
}

private extension JSONEncoder {
    static var retention: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }
}
