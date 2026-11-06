import CryptoKit
import Darwin
import Foundation

struct RepositoryMaintenanceDraft {
    let prunable: [PrunableRegistrationEvidence]
    let moved: [MovedWorktreeEvidence]
    let refusals: [String]
    let diagnostics: [String]
}

#if SHADOW_SYNC_TESTING
enum RepositoryMaintenanceTesting {
    @TaskLocal static var registrationObserver: (@Sendable (String) -> Void)?
}
#endif

enum RepositoryMaintenancePlanner {
    typealias GitRun = (
        _ arguments: [String],
        _ handle: RepositoryHandle,
        _ frozen: FrozenGitConfiguration,
        _ admission: GitAdmissionSnapshot?,
        _ timeout: TimeInterval
    ) throws -> ProcessResult

    static func unavailableRepairMessage(
        total: Int,
        unproven: Int,
        detached: Int
    ) -> String {
        precondition(
            total > 0
                && unproven > 0
                && detached >= 0
                && detached <= unproven
                && unproven <= total
        )
        let stale =
            "stale registration\(total == 1 ? "" : "s")"
        if detached == unproven {
            return "Repair unavailable: \(detached) of \(total) \(stale) \(detached == 1 ? "is" : "are") detached and cannot be safely removed. Nothing will be changed."
        }
        if detached > 0 {
            let other = unproven - detached
            return "Repair unavailable: \(unproven) of \(total) \(stale) cannot be safely removed; \(detached) \(detached == 1 ? "is" : "are") detached and \(other) \(other == 1 ? "lacks" : "lack") independent proof. Nothing will be changed."
        }
        return "Repair unavailable: \(unproven) of \(total) \(stale) cannot be independently proven safe to remove. Nothing will be changed."
    }

    static func inspect(
        clone: LocalClone,
        remote: RemoteRepository,
        account: EffectiveAccount,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        capturedNow: Date,
        validateAdmission: () throws -> Void,
        run: GitRun
    ) throws -> RepositoryMaintenanceDraft {
        try validateAdmission()
        guard clone.policyCategory == .writable,
              let resolvedDefault = remote.resolvedDefault else {
            return RepositoryMaintenanceDraft(
                prunable: [],
                moved: [],
                refusals: [],
                diagnostics: []
            )
        }
        do {
            try handle.rejectBusyState(
                defaultBranch: resolvedDefault.name
            )
            let arguments = gitDirectoryArguments(
                handle: handle,
                command: [
                    "worktree", "prune", "--dry-run",
                    "--verbose", "--expire=now",
                ]
            )
            let dryRun = try run(
                arguments,
                handle,
                frozen,
                admission,
                5
            )
            try validateAdmission()
            guard dryRun.succeeded,
                  !dryRun.stdoutTruncated,
                  !dryRun.stderrTruncated else {
                return RepositoryMaintenanceDraft(
                    prunable: [],
                    moved: [],
                    refusals: [
                        "Repair is unavailable because Git's final stale-registration set could not be verified.",
                    ],
                    diagnostics: [
                        "Repair inspection could not verify Git's exact stale-registration dry-run set.",
                    ]
                )
            }
            let identifiers = try parsePruneSet(dryRun.output)
            guard !identifiers.isEmpty else {
                return RepositoryMaintenanceDraft(
                    prunable: [],
                    moved: [],
                    refusals: [],
                    diagnostics: []
                )
            }
            var prunable: [PrunableRegistrationEvidence] = []
            var moved: [MovedWorktreeEvidence] = []
            var unproven: [
                (
                    identifier: String,
                    reason: String,
                    detached: Bool
                )
            ] = []
            for identifier in identifiers {
                try validateAdmission()
                do {
                    let inspected = try inspectRegistration(
                        identifier: identifier,
                        clone: clone,
                        defaultRef: resolvedDefault.localRef,
                        commonDirectory:
                            handle.identity.commonDirectoryPath,
                        account: account
                    )
                    try requireCurrentBranchOID(
                        inspected.branchRef,
                        expectedOID: inspected.branchOID,
                        handle: handle,
                        frozen: frozen,
                        admission: admission,
                        run: run
                    )
                    try validateAdmission()
                    if let movedPath = findMovedPath(
                        registrationID: identifier,
                        registrationPath:
                            inspected.registrationPath,
                        previousPath: inspected.worktreePath,
                        account: account
                    ) {
                        try validateAdmission()
                        let movedEvidence = try movedEvidence(
                            movedPath: movedPath,
                            inspected: inspected,
                            account: account,
                            commonDirectory:
                                handle.identity.commonDirectoryPath,
                            capturedNow: capturedNow
                        )
                        try requireMovedCandidateClean(
                            movedEvidence,
                            clone: clone,
                            frozen: frozen,
                            admission: admission,
                            run: run
                        )
                        moved.append(movedEvidence)
                    } else {
                        try validateAdmission()
                        let awa = AWAEvidenceReader.read(
                            worktreePath: inspected.worktreePath,
                            commonDirectory:
                                handle.identity.commonDirectoryPath,
                            branch: String(
                                inspected.branchRef.dropFirst(
                                    "refs/heads/".count
                                )
                            ),
                            location: locationKind(
                                inspected.worktreePath,
                                account: account
                            ),
                            account: account,
                            capturedNow: capturedNow
                        )
                        guard awa.state != .active,
                              awa.state != .unavailable else {
                            throw MaintenanceInspectionError.refused
                        }
                        prunable.append(
                            try PrunableRegistrationEvidence(
                                registrationID: identifier,
                                expectedWorktreePath:
                                    inspected.worktreePath,
                                branchRef: inspected.branchRef,
                                branchOID: inspected.branchOID,
                                registrationIdentity:
                                    inspected.registrationIdentity,
                                gitdirIdentity:
                                    inspected.gitdirIdentity,
                                headIdentity:
                                    inspected.headIdentity,
                                commondirIdentity:
                                    inspected.commondirIdentity
                            )
                        )
                    }
                } catch let error as MaintenanceInspectionError {
                    try validateAdmission()
                    unproven.append(
                        (
                            identifier:
                                safeLabel(identifier),
                            reason:
                                error.diagnosticLabel,
                            detached:
                                error.isDetached
                        )
                    )
                } catch {
            if error is SystemGitConfigurationError { throw error }
            if case GitSafetyError.cancelled = error { throw error }
            try validateAdmission()
                    unproven.append(
                        (
                            identifier:
                                safeLabel(identifier),
                            reason: "unexpected-proof",
                            detached: false
                        )
                    )
                }
            }
            try validateAdmission()
            var refusals: [String] = []
            let diagnostics = unproven.map {
                "Repair unavailable registration \($0.identifier): \($0.reason)."
            }
            if !unproven.isEmpty {
                let detached = unproven.filter {
                    $0.detached
                }.count
                refusals.append(
                    unavailableRepairMessage(
                        total: identifiers.count,
                        unproven: unproven.count,
                        detached: detached
                    )
                )
            }
            if prunable.count != identifiers.count {
                if !prunable.isEmpty && unproven.isEmpty {
                    refusals.append(
                        "Prune Repair unavailable: \(identifiers.count - prunable.count) of \(identifiers.count) stale registration\(identifiers.count == 1 ? "" : "s") \(identifiers.count - prunable.count == 1 ? "requires" : "require") a separate verified repair. Nothing will be changed by Prune Repair."
                    )
                }
                prunable = []
            }
            return RepositoryMaintenanceDraft(
                prunable: prunable,
                moved: moved,
                refusals: refusals,
                diagnostics: diagnostics
            )
        } catch {
            if error is SystemGitConfigurationError { throw error }
            if case GitSafetyError.cancelled = error { throw error }
            try validateAdmission()
            return RepositoryMaintenanceDraft(
                prunable: [],
                moved: [],
                refusals: [
                    "Repair is unavailable because repository metadata or lock state could not be verified.",
                ],
                diagnostics: [
                    "Repair inspection could not verify repository metadata or lock state.",
                ]
            )
        }
    }

    static func parsePruneSet(_ data: Data) throws -> [String] {
        guard let text = String(data: data, encoding: .utf8),
              !text.contains("\0"),
              !text.contains("\r") else {
            throw MaintenanceInspectionError.malformed
        }
        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: true
        ).map(String.init)
        var identifiers: [String] = []
        for line in lines {
            let prefix = "Removing worktrees/"
            guard line.hasPrefix(prefix),
                  let separator = line.range(of: ": "),
                  separator.lowerBound
                    > line.index(
                        line.startIndex,
                        offsetBy: prefix.count
                    ) else {
                throw MaintenanceInspectionError.malformed
            }
            let identifier = String(
                line[
                    line.index(
                        line.startIndex,
                        offsetBy: prefix.count
                    )..<separator.lowerBound
                ]
            )
            guard validRegistrationID(identifier) else {
                throw MaintenanceInspectionError.malformed
            }
            identifiers.append(identifier)
        }
        guard Set(identifiers).count == identifiers.count else {
            throw MaintenanceInspectionError.malformed
        }
        return identifiers.sorted()
    }

    private static func requireMovedCandidateClean(
        _ evidence: MovedWorktreeEvidence,
        clone: LocalClone,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        run: GitRun
    ) throws {
        let moved = try RepositoryHandle.openMovedWorktree(
            clone.sourceSnapshot,
            evidence: evidence
        )
        try moved.rejectBusyState(
            defaultBranch: String(
                evidence.branchRef.dropFirst(
                    "refs/heads/".count
                )
            )
        )
        let status = try run(
            [
                "--no-replace-objects", "--no-lazy-fetch",
                "status", "--porcelain=v1", "-z",
                "--untracked-files=all",
            ],
            moved,
            frozen,
            admission,
            5
        )
        let index = try run(
            [
                "--no-replace-objects", "--no-lazy-fetch",
                "ls-files", "-v", "-z",
            ],
            moved,
            frozen,
            admission,
            5
        )
        guard status.succeeded,
              status.stdout.isEmpty,
              !status.stdoutTruncated,
              !status.stderrTruncated,
              index.succeeded,
              !index.stdoutTruncated,
              !index.stderrTruncated,
              (try? GitIndexVisibility.validate(
                  index.stdout
              )) != nil else {
            throw MaintenanceInspectionError.refused
        }
    }

    private static func requireCurrentBranchOID(
        _ branchRef: String,
        expectedOID: String,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        run: GitRun
    ) throws {
        let result = try run(
            [
                "--no-replace-objects", "--no-lazy-fetch",
                "rev-parse", "--verify",
                "\(branchRef)^{commit}",
            ],
            handle,
            frozen,
            admission,
            5
        )
        let observed = String(
            data: result.stdout,
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded,
              !result.stdoutTruncated,
              !result.stderrTruncated,
              observed?.lowercased() == expectedOID.lowercased() else {
            throw MaintenanceInspectionError.refused
        }
    }

    static func gitDirectoryArguments(
        handle: RepositoryHandle,
        command: [String]
    ) -> [String] {
        [
            "--no-replace-objects",
            "--no-lazy-fetch",
            "--git-dir=\(handle.identity.commonDirectoryPath)",
        ] + command
    }

    static func repairedRegistrationMismatch(
        _ evidence: MovedWorktreeEvidence,
        commonDirectory: String,
        account: EffectiveAccount
    ) -> String? {
        let path = URL(fileURLWithPath: commonDirectory)
            .appendingPathComponent(
                "worktrees/\(evidence.registrationID)"
            ).path
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return "registration-open" }
        defer { close(descriptor) }
        let rootDescriptor = Darwin.open(
            evidence.verifiedPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else { return "root-open" }
        defer { close(rootDescriptor) }
        var info = stat()
        var rootInfo = stat()
        guard fstat(descriptor, &info) == 0,
              RepositoryDirectoryIdentity(FileIdentity(info))
                == evidence.registrationIdentity else {
            return "registration-identity"
        }
        guard
              fstat(rootDescriptor, &rootInfo) == 0,
              RepositoryDirectoryIdentity(FileIdentity(rootInfo))
                == evidence.rootIdentity else {
            return "root-identity"
        }
        guard let marker = try? readMetadata(
            ".git",
            directory: rootDescriptor,
            account: account
        ), let gitdir = try? readMetadata(
            "gitdir",
            directory: descriptor,
            account: account
        ), let head = try? readMetadata(
            "HEAD",
            directory: descriptor,
            account: account
        ), let commondir = try? readMetadata(
            "commondir",
            directory: descriptor,
            account: account
        ) else {
            return "metadata-read"
        }
        guard marker.line.hasPrefix("gitdir: "),
              resolve(
                  String(marker.line.dropFirst("gitdir: ".count)),
                  relativeTo: evidence.verifiedPath
              ).map({
                  physicallyEqual($0, path)
              }) == true else {
            return "marker-backlink"
        }
        guard gitdir.line.hasSuffix("/.git"),
              samePotentialPath(
                  String(
                      gitdir.line.dropLast("/.git".count)
                  ),
                  evidence.verifiedPath
              ) else {
            return "registration-backlink"
        }
        guard head.line == "ref: \(evidence.branchRef)" else {
            return "branch-claim"
        }
        guard resolve(
            commondir.line,
            relativeTo: path
        ).map({
            physicallyEqual($0, commonDirectory)
        }) == true else {
            return "common-directory"
        }
        return nil
    }

    private struct InspectedRegistration {
        let registrationID: String
        let registrationPath: String
        let registrationIdentity: RepositoryDirectoryIdentity
        let gitdirIdentity: RepositoryMetadataFileIdentity
        let headIdentity: RepositoryMetadataFileIdentity
        let commondirIdentity: RepositoryMetadataFileIdentity
        let worktreePath: String
        let branchRef: String
        let branchOID: String
    }

    private static func inspectRegistration(
        identifier: String,
        clone: LocalClone,
        defaultRef: String,
        commonDirectory: String,
        account: EffectiveAccount
    ) throws -> InspectedRegistration {
        #if SHADOW_SYNC_TESTING
        RepositoryMaintenanceTesting.registrationObserver?(identifier)
        #endif
        guard validRegistrationID(identifier),
              commonDirectory.hasPrefix("/") else {
            throw MaintenanceInspectionError.diagnostic("common")
        }
        let commonPath = commonDirectory
        let registrationPath = URL(fileURLWithPath: commonPath)
            .appendingPathComponent("worktrees/\(identifier)").path
        let registrationFD = Darwin.open(
            registrationPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard registrationFD >= 0 else {
            throw MaintenanceInspectionError.diagnostic("registration-open")
        }
        defer { close(registrationFD) }
        var registrationInfo = stat()
        guard fstat(registrationFD, &registrationInfo) == 0,
              FileIdentity(registrationInfo).isDirectory,
              registrationInfo.st_uid == account.uid,
              (registrationInfo.st_mode & 0o022) == 0 else {
            throw MaintenanceInspectionError.diagnostic("registration-identity")
        }
        try requireAbsent(
            names: [
                "locked", "index.lock", "HEAD.lock",
                "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD",
                "BISECT_LOG", "rebase-apply", "rebase-merge",
                "sequencer",
            ],
            directory: registrationFD
        )
        let gitdir: Metadata
        let head: Metadata
        let commondir: Metadata
        do {
            gitdir = try readMetadata(
                "gitdir",
                directory: registrationFD,
                account: account
            )
            head = try readMetadata(
                "HEAD",
                directory: registrationFD,
                account: account
            )
            commondir = try readMetadata(
                "commondir",
                directory: registrationFD,
                account: account
            )
        } catch {
            throw MaintenanceInspectionError.diagnostic(
                "metadata-\(error)"
            )
        }
        guard gitdir.line.hasSuffix("/.git"),
              gitdir.line.hasPrefix("/") else {
            throw MaintenanceInspectionError.diagnostic("gitdir-value")
        }
        guard head.line.hasPrefix("ref: ") else {
            if validOID(head.line) {
                throw MaintenanceInspectionError.detached
            }
            throw MaintenanceInspectionError.diagnostic(
                "head-value"
            )
        }
        guard GitReferenceSyntax.isValidLocalBranchRef(
                  String(head.line.dropFirst("ref: ".count))
              ),
              head.line != "ref: \(defaultRef)" else {
            throw MaintenanceInspectionError.diagnostic(
                "head-value-\(head.line)-default-\(defaultRef)"
            )
        }
        guard resolve(
            commondir.line,
            relativeTo: registrationPath
        ).map({ physicallyEqual($0, commonPath) }) == true else {
            throw MaintenanceInspectionError.diagnostic(
                "commondir-value"
            )
        }
        guard let worktreePath = canonicalPathAllowingMissing(
            String(gitdir.line.dropLast("/.git".count))
        ) else {
            throw MaintenanceInspectionError.diagnostic(
                "gitdir-path"
            )
        }
        guard worktreePath.hasPrefix(account.homeDirectory + "/"),
              absentPath(worktreePath),
              ownerControlledParent(
                  worktreePath,
                  account: account
              ) else {
            throw MaintenanceInspectionError.diagnostic("absent-root")
        }
        let branchRef = String(head.line.dropFirst("ref: ".count))
        guard let branch = clone.branches.first(where: {
            $0.fullRef == branchRef
        }), let branchOID = branch.tipOID else {
            throw MaintenanceInspectionError.diagnostic("branch")
        }
        return InspectedRegistration(
            registrationID: identifier,
            registrationPath: registrationPath,
            registrationIdentity:
                RepositoryDirectoryIdentity(
                    FileIdentity(registrationInfo)
                ),
            gitdirIdentity: gitdir.identity,
            headIdentity: head.identity,
            commondirIdentity: commondir.identity,
            worktreePath: worktreePath,
            branchRef: branchRef,
            branchOID: branchOID
        )
    }

    private static func movedEvidence(
        movedPath: String,
        inspected: InspectedRegistration,
        account: EffectiveAccount,
        commonDirectory: String,
        capturedNow: Date
    ) throws -> MovedWorktreeEvidence {
        let rootFD = Darwin.open(
            movedPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootFD >= 0 else {
            throw MaintenanceInspectionError.refused
        }
        defer { close(rootFD) }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0,
              FileIdentity(rootInfo).isDirectory,
              rootInfo.st_uid == account.uid,
              (rootInfo.st_mode & 0o022) == 0 else {
            throw MaintenanceInspectionError.refused
        }
        let marker = try readMetadata(
            ".git",
            directory: rootFD,
            account: account
        )
        guard marker.line.hasPrefix("gitdir: "),
              resolve(
                  String(marker.line.dropFirst("gitdir: ".count)),
                  relativeTo: movedPath
              ).map({
                  physicallyEqual(
                      $0,
                      inspected.registrationPath
                  )
              }) == true else {
            throw MaintenanceInspectionError.refused
        }
        let awa = AWAEvidenceReader.read(
            worktreePath: movedPath,
            commonDirectory: commonDirectory,
            branch: String(
                inspected.branchRef.dropFirst(
                    "refs/heads/".count
                )
            ),
            location: locationKind(
                movedPath,
                account: account
            ),
            account: account,
            capturedNow: capturedNow
        )
        guard awa.state != .active,
              awa.state != .unavailable else {
            throw MaintenanceInspectionError.refused
        }
        let payload = try WorktreeBytesSnapshot.capture(
            path: movedPath,
            account: account,
            administrativeIndexPath:
                URL(fileURLWithPath: inspected.registrationPath)
                    .appendingPathComponent("index").path
        )
        return try MovedWorktreeEvidence(
            registrationID: inspected.registrationID,
            previousPath: inspected.worktreePath,
            verifiedPath: movedPath,
            branchRef: inspected.branchRef,
            branchOID: inspected.branchOID,
            rootIdentity:
                RepositoryDirectoryIdentity(FileIdentity(rootInfo)),
            markerIdentity: marker.identity,
            registrationIdentity:
                inspected.registrationIdentity,
            gitdirIdentity: inspected.gitdirIdentity,
            headIdentity: inspected.headIdentity,
            commondirIdentity: inspected.commondirIdentity,
            registrationSetDigest: try registrationSetDigest(
                commonDirectory: commonDirectory,
                account: account
            ),
            payloadDigest: payload.digest,
            payloadFileCount: payload.files,
            payloadByteCount: payload.bytes,
            awaLeaseID: awa.leaseID
        )
    }

    private struct Metadata {
        let line: String
        let identity: RepositoryMetadataFileIdentity
    }

    private static func readMetadata(
        _ name: String,
        directory: Int32,
        account: EffectiveAccount
    ) throws -> Metadata {
        let descriptor = openat(
            directory,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw MaintenanceInspectionError.refused
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              FileIdentity(info).isRegular,
              info.st_uid == account.uid,
              info.st_nlink == 1,
              (info.st_mode & 0o022) == 0,
              info.st_size > 0,
              info.st_size <= 16_384 else {
            throw MaintenanceInspectionError.refused
        }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 1_024)
        while data.count <= 16_384 {
            let count = Darwin.read(
                descriptor,
                &bytes,
                bytes.count
            )
            if count > 0 {
                data.append(contentsOf: bytes.prefix(count))
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw MaintenanceInspectionError.refused
            }
        }
        guard data.count <= 16_384,
              let raw = String(data: data, encoding: .utf8),
              !raw.contains("\0"),
              !raw.contains("\r") else {
            throw MaintenanceInspectionError.malformed
        }
        let lines = raw.split(
            separator: "\n",
            omittingEmptySubsequences: true
        )
        guard lines.count == 1 else {
            throw MaintenanceInspectionError.malformed
        }
        return Metadata(
            line: String(lines[0]),
            identity: RepositoryMetadataFileIdentity(info)
        )
    }

    static func registrationSetDigest(
        commonDirectory: String,
        excluding registrationIDs: Set<String> = [],
        account: EffectiveAccount
    ) throws -> String {
        let path = URL(fileURLWithPath: commonDirectory)
            .appendingPathComponent("worktrees").path
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT {
            return digestRows([])
        }
        guard descriptor >= 0 else {
            throw MaintenanceInspectionError.refused
        }
        defer { close(descriptor) }
        var rootInfo = stat()
        guard fstat(descriptor, &rootInfo) == 0,
              FileIdentity(rootInfo).isDirectory,
              rootInfo.st_uid == account.uid,
              (rootInfo.st_mode & 0o022) == 0 else {
            throw MaintenanceInspectionError.refused
        }
        let initial = try registrationNames(
            at: path,
            excluding: registrationIDs
        )
        var rows: [String] = []
        for name in initial {
            let registration = openat(
                descriptor,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard registration >= 0 else {
                throw MaintenanceInspectionError.refused
            }
            defer { close(registration) }
            var info = stat()
            guard fstat(registration, &info) == 0,
                  FileIdentity(info).isDirectory,
                  info.st_uid == account.uid,
                  (info.st_mode & 0o022) == 0 else {
                throw MaintenanceInspectionError.refused
            }
            let gitdir = try readMetadata(
                "gitdir",
                directory: registration,
                account: account
            )
            let head = try readMetadata(
                "HEAD",
                directory: registration,
                account: account
            )
            let commondir = try readMetadata(
                "commondir",
                directory: registration,
                account: account
            )
            rows.append([
                name,
                identityField(FileIdentity(info)),
                metadataField(gitdir),
                metadataField(head),
                metadataField(commondir),
            ].joined(separator: "|"))
        }
        guard try registrationNames(
            at: path,
            excluding: registrationIDs
        ) == initial else {
            throw MaintenanceInspectionError.refused
        }
        return digestRows(rows)
    }

    private static func registrationNames(
        at path: String,
        excluding: Set<String>
    ) throws -> [String] {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: path)
            .filter { !excluding.contains($0) }
            .sorted()
        guard names.count <= 512,
              names.allSatisfy(validRegistrationID) else {
            throw MaintenanceInspectionError.refused
        }
        return names
    }

    private static func metadataField(
        _ metadata: Metadata
    ) -> String {
        let bytes = SHA256.hash(data: Data(metadata.line.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        return identityField(metadata.identity.identity)
            + ":\(metadata.identity.size)"
            + ":\(metadata.identity.modifiedSeconds)"
            + ":\(metadata.identity.modifiedNanoseconds)"
            + ":\(bytes)"
    }

    private static func identityField(
        _ identity: FileIdentity
    ) -> String {
        "\(identity.device):\(identity.inode):\(identity.owner):\(identity.mode):\(identity.linkCount)"
    }

    private static func digestRows(_ rows: [String]) -> String {
        SHA256.hash(
            data: Data(rows.sorted().joined(separator: "\n").utf8)
        ).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func findMovedPath(
        registrationID: String,
        registrationPath: String,
        previousPath: String,
        account: EffectiveAccount
    ) -> String? {
        let parent = URL(fileURLWithPath: previousPath)
            .deletingLastPathComponent().path
        guard parent.hasPrefix(account.homeDirectory + "/"),
              let names = try? FileManager.default
                .contentsOfDirectory(atPath: parent),
              names.count <= 512 else {
            return nil
        }
        var matches: [String] = []
        for name in names.sorted()
        where name != URL(
            fileURLWithPath: previousPath
        ).lastPathComponent {
            let path = URL(fileURLWithPath: parent)
                .appendingPathComponent(name).path
            var rootInfo = stat()
            guard lstat(path, &rootInfo) == 0,
                  FileIdentity(rootInfo).isDirectory,
                  rootInfo.st_uid == account.uid,
                  (rootInfo.st_mode & 0o022) == 0 else {
                continue
            }
            let rootFD = Darwin.open(
                path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard rootFD >= 0 else { continue }
            let marker = try? readMetadata(
                ".git",
                directory: rootFD,
                account: account
            )
            close(rootFD)
            if let marker,
               marker.line.hasPrefix("gitdir: "),
               resolve(
                   String(marker.line.dropFirst("gitdir: ".count)),
                   relativeTo: path
               ).map({
                   physicallyEqual($0, registrationPath)
               }) == true {
                matches.append(path)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func requireAbsent(
        names: [String],
        directory: Int32
    ) throws {
        for name in names {
            var info = stat()
            if fstatat(
                directory,
                name,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0 || errno != ENOENT {
                throw MaintenanceInspectionError.refused
            }
        }
    }

    private static func absentPath(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) != 0 && errno == ENOENT
    }

    private static func ownerControlledParent(
        _ path: String,
        account: EffectiveAccount
    ) -> Bool {
        var cursor = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
        for _ in 0..<32 {
            var info = stat()
            if lstat(cursor.path, &info) == 0 {
                return FileIdentity(info).isDirectory
                    && info.st_uid == account.uid
                    && (info.st_mode & 0o002) == 0
            }
            guard errno == ENOENT else { return false }
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else { return false }
            cursor = parent
        }
        return false
    }

    private static func resolve(
        _ value: String,
        relativeTo base: String
    ) -> String? {
        let url: URL
        if value.hasPrefix("/") {
            url = URL(fileURLWithPath: value)
        } else {
            url = URL(fileURLWithPath: base)
                .appendingPathComponent(value)
        }
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/") ? path : nil
    }

    private static func physicallyEqual(
        _ left: String,
        _ right: String
    ) -> Bool {
        guard let leftPointer = realpath(left, nil) else {
            return false
        }
        defer { free(leftPointer) }
        guard let rightPointer = realpath(right, nil) else {
            return false
        }
        defer { free(rightPointer) }
        return String(cString: leftPointer)
            == String(cString: rightPointer)
    }

    static func samePotentialPath(
        _ left: String,
        _ right: String
    ) -> Bool {
        guard let canonicalLeft =
                canonicalPathAllowingMissing(left),
              let canonicalRight =
                canonicalPathAllowingMissing(right) else {
            return false
        }
        return canonicalLeft == canonicalRight
    }

    private static func canonicalPathAllowingMissing(
        _ path: String
    ) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var cursor = URL(fileURLWithPath: path)
        var suffix: [String] = []
        for _ in 0..<32 {
            if let pointer = realpath(cursor.path, nil) {
                defer { free(pointer) }
                var result = URL(
                    fileURLWithPath: String(cString: pointer)
                )
                for component in suffix.reversed() {
                    result.appendPathComponent(component)
                }
                return result.standardizedFileURL.path
            }
            guard errno == ENOENT else { return nil }
            suffix.append(cursor.lastPathComponent)
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else { return nil }
            cursor = parent
        }
        return nil
    }

    private static func validRegistrationID(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.hasPrefix("-")
            && value.allSatisfy {
                $0.isLetter || $0.isNumber
                    || $0 == "-" || $0 == "_" || $0 == "."
            }
    }

    private static func locationKind(
        _ path: String,
        account: EffectiveAccount
    ) -> WorktreeLocationKind {
        if path.hasPrefix(account.homeDirectory + "/dev/") {
            return .dev
        }
        if path.hasPrefix(
            account.homeDirectory + "/.cursor/worktrees/"
        ) {
            return .cursorManaged
        }
        if path.hasPrefix(
            account.homeDirectory + "/.local/share/awa/worktrees/"
        ) {
            return .awaManaged
        }
        return .external
    }

    private static func safeLabel(_ value: String) -> String {
        value.filter {
            $0.isLetter || $0.isNumber
                || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    private static func validOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy(\.isHexDigit)
    }

    private enum MaintenanceInspectionError: Error {
        case refused
        case malformed
        case detached
        case diagnostic(String)

        var isDetached: Bool {
            if case .detached = self {
                return true
            }
            return false
        }

        var diagnosticLabel: String {
            switch self {
            case .refused:
                return "independent activity or policy proof is incomplete"
            case .malformed:
                return "registration metadata is malformed"
            case .detached:
                return "HEAD is detached"
            case let .diagnostic(value):
                #if SHADOW_SYNC_TESTING
                return RepositoryMaintenancePlanner
                    .safeLabel(value)
                #else
                _ = value
                return "independent identity or branch proof is incomplete"
                #endif
            }
        }
    }
}

public final class RepositoryMaintenanceTransaction:
    @unchecked Sendable {
    private let helper: FastForwardTransactionV2
    private let configuration: GitTransactionConfiguration
    private let account: EffectiveAccount

    public init(
        runner: DescriptorProcessRunner,
        configuration: GitTransactionConfiguration,
        account: EffectiveAccount
    ) {
        helper = FastForwardTransactionV2(
            runner: runner,
            configuration: configuration,
            account: account
        )
        self.configuration = configuration
        self.account = account
    }

    public func execute(
        operation: PlannedOperation,
        cancellation: CancellationToken,
        phase: @escaping @Sendable (RepositoryPhase) throws -> Void,
        checkpoint: @escaping @Sendable (RepositoryCheckpoint) throws -> Void
            = { _ in }
    ) -> RepositoryResult {
        let startedAt = WallClock.timestamp()
        let started = MonotonicInstant.now()
        let candidate =
            operation.target.canonicalClone.sourceSnapshot
        let branch = operation.target.resolvedDefault
        var fetched = false
        var before: String?
        var target: String?
        var remoteBefore: String?
        var remoteAfter: String?

        func result(
            _ code: ResultCode,
            updated: Bool = false,
            after: String? = nil,
            explanation: String,
            detail: String? = nil,
            failure: FetchFailureReason? = nil
        ) -> RepositoryResult {
            RepositoryResult(
                repository: candidate,
                operationID: operation.id,
                defaultBranch: branch.name,
                code: code,
                fetched: fetched,
                mainUpdated: updated,
                beforeCommit: before,
                targetCommit: target,
                afterCommit: after,
                remoteTrackingBeforeCommit: remoteBefore,
                remoteTrackingAfterCommit: remoteAfter,
                startedAt: startedAt,
                endedAt: WallClock.timestamp(),
                durationMilliseconds:
                    MonotonicInstant.now().milliseconds(
                        since: started
                    ),
                explanation: explanation,
                technicalDetail: detail.map(Redactor.sanitize),
                failureReason: failure
            )
        }

        guard operation.kind != .fastForward,
              operation.isSelectable,
              operation.maintenanceEvidence != nil else {
            return result(
                .failedInspection,
                explanation:
                    "The selected maintenance operation is invalid."
            )
        }
        if cancellation.isCancelled {
            return result(
                .cancelledPending,
                explanation:
                    "The pending operation was cancelled before it started."
            )
        }
        do {
            try phase(.checking)
            try helper.validateRuntimeEligibility(operation)
            let primary = try RepositoryHandle.open(candidate)
            try primary.rejectReplacementAndGraftState()
            try primary.rejectBusyState(
                defaultBranch: branch.name
            )
            let frozen = try helper.freezeConfiguration(primary)
            let admission = try helper.validateOriginAndTransport(
                handle: primary,
                frozen: frozen,
                cancellation: cancellation
            )
            let currentDefault = try helper.resolveRemoteDefault(
                handle: primary,
                frozen: frozen,
                admission: admission,
                cancellation: cancellation
            )
            guard currentDefault.name == branch.name,
                  currentDefault.advertisedOID
                    == branch.advertisedOID else {
                throw RemoteDefaultResolutionError.changed
            }
            before = try helper.optionalCommit(
                branch.localRef,
                handle: primary,
                frozen: frozen,
                admission: admission,
                cancellation: cancellation
            )
            try checkpoint(RepositoryCheckpoint(
                repository: candidate,
                startedAt: startedAt,
                beforeCommit: before,
                targetCommit: nil,
                fetched: false
            ))
            #if SHADOW_SYNC_TESTING
            configuration.afterPreflight?(candidate)
            #endif
            if cancellation.isCancelled {
                return result(
                    .cancelledNoUpdate,
                    after: before,
                    explanation:
                        "The operation was cancelled before mutation."
                )
            }
            switch operation.kind {
            case .repairPruneRegistrations:
                return try executePrune(
                    operation: operation,
                    primary: primary,
                    frozen: frozen,
                    admission: admission,
                    cancellation: cancellation,
                    phase: phase,
                    result: result
                )
            case .repairMovedWorktree:
                return try executeMovedRepair(
                    operation: operation,
                    primary: primary,
                    frozen: frozen,
                    admission: admission,
                    cancellation: cancellation,
                    phase: phase,
                    result: result
                )
            case .initializeDefaultBranch:
                let initialized = try executeInitialize(
                    operation: operation,
                    primary: primary,
                    frozen: frozen,
                    admission: admission,
                    cancellation: cancellation,
                    phase: phase,
                    checkpoint: checkpoint,
                    startedAt: startedAt,
                    result: result,
                    markFetched: {
                        fetched = true
                    },
                    setTarget: {
                        target = $0
                    },
                    setRemoteBefore: {
                        remoteBefore = $0
                    },
                    setRemoteAfter: {
                        remoteAfter = $0
                    }
                )
                return initialized
            case .fastForward:
                throw GitSafetyError.unsafeRepository(
                    "Fast-forward reached maintenance execution"
                )
            }
        } catch let error as GitSafetyError {
            let code: ResultCode
            switch error {
            case .busy: code = .skippedBusy
            case .cancelled: code = .cancelledNoUpdate
            case .originChanged: code = .skippedOriginChanged
            case .repositoryRemoved:
                code = .skippedRepositoryRemoved
            default: code = .failedInspection
            }
            return result(
                code,
                after: before,
                explanation:
                    "The operation was refused because its exact safety evidence changed.",
                detail: String(describing: error)
            )
        } catch {
            return result(
                .failedInspection,
                after: before,
                explanation:
                    "The operation target could not be verified safely.",
                detail: String(describing: error)
            )
        }
    }

    private func executePrune(
        operation: PlannedOperation,
        primary: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken,
        phase: @escaping @Sendable (RepositoryPhase) throws -> Void,
        result: (
            ResultCode, Bool, String?, String, String?,
            FetchFailureReason?
        ) -> RepositoryResult
    ) throws -> RepositoryResult {
        guard case let .prune(expected)? =
                operation.maintenanceEvidence else {
            throw GitSafetyError.unsafeRepository(
                "Prune evidence is unavailable"
            )
        }
        let preserved = try captureWorktrees(
            operation.target.canonicalClone,
            excludingPaths: Set(
                expected.map(\.expectedWorktreePath)
            ),
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        let lock = try primary.acquireCommonDirectoryOperationLock(
            account: account
        )
        defer { withExtendedLifetime(lock) {} }
        try helper.validateRuntimeEligibility(operation)
        try primary.revalidate()
        try primary.rejectBusyState(
            defaultBranch:
                operation.target.resolvedDefault.name
        )
        let currentDefault = try helper.resolveRemoteDefault(
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        guard currentDefault.name
                == operation.target.resolvedDefault.name,
              currentDefault.localRef
                == operation.target.resolvedDefault.localRef,
              currentDefault.remoteTrackingRef
                == operation.target.resolvedDefault.remoteTrackingRef,
              currentDefault.advertisedOID
                == operation.target.resolvedDefault.advertisedOID else {
            throw RemoteDefaultResolutionError.changed
        }
        let finalDraft = try RepositoryMaintenancePlanner.inspect(
            clone: operation.target.canonicalClone,
            remote: operation.target.repository,
            account: account,
            handle: primary,
            frozen: frozen,
            admission: admission,
            capturedNow: Date(),
            validateAdmission: {
                guard !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else {
                    throw GitSafetyError.cancelled
                }
            }
        ) { [helper] arguments, handle, config, transport, timeout in
            try helper.runGit(
                arguments: arguments,
                operation: nil,
                handle: handle,
                frozen: config,
                admission: transport,
                cancellation: cancellation,
                timeout: timeout
            )
        }
        guard finalDraft.prunable == expected,
              finalDraft.moved.isEmpty else {
            throw GitSafetyError.unsafeRepository(
                "final prune exact set changed"
            )
        }
        let refsBefore = try refMap(
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        let unselectedRegistrationsBefore =
            try RepositoryMaintenancePlanner.registrationSetDigest(
                commonDirectory:
                    primary.identity.commonDirectoryPath,
                excluding:
                    Set(expected.map(\.registrationID)),
                account: account
            )
        #if SHADOW_SYNC_TESTING
        configuration.maintenanceBeforeAction?(
            operation.kind,
            primary.candidate
        )
        #endif
        try phase(.updating)
        let actionDraft = try RepositoryMaintenancePlanner.inspect(
            clone: operation.target.canonicalClone,
            remote: operation.target.repository,
            account: account,
            handle: primary,
            frozen: frozen,
            admission: admission,
            capturedNow: Date(),
            validateAdmission: {
                guard !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else {
                    throw GitSafetyError.cancelled
                }
            }
        ) { [helper] arguments, handle, config, transport, timeout in
            try helper.runGit(
                arguments: arguments,
                operation: nil,
                handle: handle,
                frozen: config,
                admission: transport,
                cancellation: cancellation,
                timeout: timeout
            )
        }
        guard actionDraft.prunable == expected,
              actionDraft.moved.isEmpty,
              try refMap(
                  handle: primary,
                  frozen: frozen,
                  admission: admission,
                  cancellation: cancellation
              ) == refsBefore else {
            throw GitSafetyError.unsafeRepository(
                "final prune evidence changed"
            )
        }
        guard try RepositoryMaintenancePlanner
            .registrationSetDigest(
                commonDirectory:
                    primary.identity.commonDirectoryPath,
                excluding:
                    Set(expected.map(\.registrationID)),
                account: account
            ) == unselectedRegistrationsBefore else {
            throw GitSafetyError.unsafeRepository(
                "unselected worktree registration changed"
            )
        }
        let finalPreserved = try captureWorktrees(
            operation.target.canonicalClone,
            excludingPaths: Set(
                expected.map(\.expectedWorktreePath)
            ),
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        guard finalPreserved == preserved else {
            throw GitSafetyError.unsafeRepository(
                "preserved worktree state changed"
            )
        }
        let finalDryRun = try helper.runGit(
            arguments:
                RepositoryMaintenancePlanner
                    .gitDirectoryArguments(
                        handle: primary,
                        command: [
                            "worktree", "prune", "--dry-run",
                            "--verbose", "--expire=now",
                        ]
                    ),
            operation: operation,
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation,
            timeout: configuration.localTimeoutSeconds
        )
        guard finalDryRun.succeeded,
              !finalDryRun.stdoutTruncated,
              !finalDryRun.stderrTruncated,
              try RepositoryMaintenancePlanner.parsePruneSet(
                  finalDryRun.output
              ) == expected.map(\.registrationID).sorted()
        else {
            throw GitSafetyError.unsafeRepository(
                "final prune exact set changed"
            )
        }
        if cancellation.isCancelled {
            return result(
                .cancelledNoUpdate,
                false,
                nil,
                "Prune Repair was cancelled before Git changed metadata.",
                nil,
                nil
            )
        }
        let action = try helper.runGit(
            arguments:
                RepositoryMaintenancePlanner
                    .gitDirectoryArguments(
                        handle: primary,
                        command: [
                            "worktree", "prune",
                            "--verbose", "--expire=now",
                        ]
                    ),
            operation: operation,
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation,
            timeout: configuration.localTimeoutSeconds
        )
        #if SHADOW_SYNC_TESTING
        configuration.maintenanceAfterAction?(
            operation.kind,
            primary.candidate
        )
        #endif
        let postflight = try prunePostflight(
            expected: expected,
            refsBefore: refsBefore,
            preserved: preserved,
            unselectedRegistrationsBefore:
                unselectedRegistrationsBefore,
            clone: operation.target.canonicalClone,
            primary: primary,
            frozen: frozen,
            admission: admission
        )
        if postflight && action.succeeded {
            return result(
                cancellation.isCancelled
                    ? .updatedBeforeCancellation : .updated,
                true,
                nil,
                "Repair removed only the selected stale worktree registrations. No branch ref or worktree path changed.",
                nil,
                nil
            )
        }
        if postflight {
            return result(
                .updatedWithWarning,
                true,
                nil,
                "The selected stale registrations are gone and refs are unchanged, but Git reported a warning.",
                action.diagnostic,
                nil
            )
        }
        return result(
            .needsAttention,
            false,
            nil,
            "Prune Repair did not produce a fully verifiable result; review the repository metadata.",
            action.diagnostic,
            nil
        )
    }

    private func executeMovedRepair(
        operation: PlannedOperation,
        primary: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken,
        phase: @escaping @Sendable (RepositoryPhase) throws -> Void,
        result: (
            ResultCode, Bool, String?, String, String?,
            FetchFailureReason?
        ) -> RepositoryResult
    ) throws -> RepositoryResult {
        guard case let .repairMoved(evidence)? =
                operation.maintenanceEvidence else {
            throw GitSafetyError.unsafeRepository(
                "Moved-worktree evidence is unavailable"
            )
        }
        let moved = try RepositoryHandle.openMovedWorktree(
            operation.target.canonicalClone.sourceSnapshot,
            evidence: evidence
        )
        try requireClean(
            moved,
            branchRef: evidence.branchRef,
            expectedOID: evidence.branchOID,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        let administrativeIndex = URL(
            fileURLWithPath:
                primary.identity.commonDirectoryPath
        ).appendingPathComponent(
            "worktrees/\(evidence.registrationID)/index"
        ).path
        let bytesBefore = try WorktreeBytesSnapshot.capture(
            path: evidence.verifiedPath,
            account: account,
            administrativeIndexPath: administrativeIndex
        )
        guard bytesBefore.digest == evidence.payloadDigest,
              bytesBefore.files == evidence.payloadFileCount,
              bytesBefore.bytes == evidence.payloadByteCount else {
            throw GitSafetyError.unsafeRepository(
                "moved worktree payload changed after preview"
            )
        }
        let refsBefore = try refMap(
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        let lock = try primary.acquireCommonDirectoryOperationLock(
            account: account
        )
        defer { withExtendedLifetime(lock) {} }
        try helper.validateRuntimeEligibility(operation)
        try primary.revalidate()
        try requireAbsentPath(evidence.previousPath)
        guard try RepositoryMaintenancePlanner
            .registrationSetDigest(
                commonDirectory:
                    primary.identity.commonDirectoryPath,
                account: account
            ) == evidence.registrationSetDigest else {
            throw GitSafetyError.unsafeRepository(
                "worktree registration set changed"
            )
        }
        let unselectedRegistrationsBefore =
            try RepositoryMaintenancePlanner
                .registrationSetDigest(
                    commonDirectory:
                        primary.identity.commonDirectoryPath,
                    excluding: [evidence.registrationID],
                    account: account
                )
        let finalMoved = try RepositoryHandle.openMovedWorktree(
            operation.target.canonicalClone.sourceSnapshot,
            evidence: evidence
        )
        try requireClean(
            finalMoved,
            branchRef: evidence.branchRef,
            expectedOID: evidence.branchOID,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        let currentDefault = try helper.resolveRemoteDefault(
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        guard currentDefault.name
                == operation.target.resolvedDefault.name,
              currentDefault.localRef
                == operation.target.resolvedDefault.localRef,
              currentDefault.remoteTrackingRef
                == operation.target.resolvedDefault.remoteTrackingRef,
              currentDefault.advertisedOID
                == operation.target.resolvedDefault.advertisedOID else {
            throw RemoteDefaultResolutionError.changed
        }
        let awa = AWAEvidenceReader.read(
            worktreePath: evidence.verifiedPath,
            commonDirectory:
                primary.identity.commonDirectoryPath,
            branch: String(
                evidence.branchRef.dropFirst(
                    "refs/heads/".count
                )
            ),
            location: locationKind(evidence.verifiedPath),
            account: account,
            capturedNow: Date()
        )
        guard awa.state != .active,
              awa.state != .unavailable,
              awa.leaseID == evidence.awaLeaseID else {
            throw GitSafetyError.busy
        }
        try phase(.updating)
        #if SHADOW_SYNC_TESTING
        configuration.maintenanceBeforeAction?(
            operation.kind,
            primary.candidate
        )
        #endif
        if cancellation.isCancelled {
            return result(
                .cancelledNoUpdate,
                false,
                nil,
                "Moved-worktree Repair was cancelled before Git changed metadata.",
                nil,
                nil
            )
        }
        try primary.revalidate()
        try requireAbsentPath(evidence.previousPath)
        guard try RepositoryMaintenancePlanner
            .registrationSetDigest(
                commonDirectory:
                    primary.identity.commonDirectoryPath,
                account: account
            ) == evidence.registrationSetDigest else {
            throw GitSafetyError.unsafeRepository(
                "worktree registration set changed"
            )
        }
        let actionMoved = try RepositoryHandle.openMovedWorktree(
            operation.target.canonicalClone.sourceSnapshot,
            evidence: evidence
        )
        try requireClean(
            actionMoved,
            branchRef: evidence.branchRef,
            expectedOID: evidence.branchOID,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        guard try WorktreeBytesSnapshot.capture(
            path: evidence.verifiedPath,
            account: account,
            administrativeIndexPath: administrativeIndex
        ) == bytesBefore else {
            throw GitSafetyError.unsafeRepository(
                "moved worktree bytes changed"
            )
        }
        let actionDefault = try helper.resolveRemoteDefault(
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        guard actionDefault.name
                == operation.target.resolvedDefault.name,
              actionDefault.advertisedOID
                == operation.target.resolvedDefault.advertisedOID else {
            throw RemoteDefaultResolutionError.changed
        }
        guard try refMap(
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        ) == refsBefore else {
            throw GitSafetyError.unsafeRepository(
                "worktree Repair refs changed"
            )
        }
        let actionAWA = AWAEvidenceReader.read(
            worktreePath: evidence.verifiedPath,
            commonDirectory:
                primary.identity.commonDirectoryPath,
            branch: String(
                evidence.branchRef.dropFirst(
                    "refs/heads/".count
                )
            ),
            location: locationKind(evidence.verifiedPath),
            account: account,
            capturedNow: Date()
        )
        guard actionAWA.state != .active,
              actionAWA.state != .unavailable,
              actionAWA.leaseID == evidence.awaLeaseID else {
            throw GitSafetyError.busy
        }
        if cancellation.isCancelled {
            return result(
                .cancelledNoUpdate,
                false,
                nil,
                "Moved-worktree Repair was cancelled before Git changed metadata.",
                nil,
                nil
            )
        }
        let action = try helper.runGit(
            arguments:
                RepositoryMaintenancePlanner
                    .gitDirectoryArguments(
                        handle: primary,
                        command: [
                            "worktree", "repair",
                            evidence.verifiedPath,
                        ]
                    ),
            operation: operation,
            handle: actionMoved,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation,
            timeout: configuration.localTimeoutSeconds,
            postExecutionHandle: primary
        )
        #if SHADOW_SYNC_TESTING
        configuration.maintenanceAfterAction?(
            operation.kind,
            primary.candidate
        )
        #endif
        let refsAfter = try? refMap(
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: CancellationToken()
        )
        let bytesAfter = try? WorktreeBytesSnapshot.capture(
            path: evidence.verifiedPath,
            account: account,
            administrativeIndexPath: administrativeIndex
        )
        let metadataMismatch =
            RepositoryMaintenancePlanner
                .repairedRegistrationMismatch(
                    evidence,
                    commonDirectory:
                        primary.identity.commonDirectoryPath,
                    account: account
                )
        let metadataMatches = metadataMismatch == nil
        let unselectedRegistrationsAfter =
            try? RepositoryMaintenancePlanner
                .registrationSetDigest(
                    commonDirectory:
                        primary.identity.commonDirectoryPath,
                    excluding: [evidence.registrationID],
                    account: account
                )
        let safe = refsAfter == refsBefore
            && bytesAfter == bytesBefore
            && metadataMatches
            && unselectedRegistrationsAfter
                == unselectedRegistrationsBefore
        let postflightDetail = [
            "refs-preserved=\(refsAfter == refsBefore)",
            "payload-preserved=\(bytesAfter == bytesBefore)",
            "registration-reconnected=\(metadataMatches)",
            "other-registrations-preserved=\(unselectedRegistrationsAfter == unselectedRegistrationsBefore)",
            metadataMismatch.map {
                "registration-mismatch=\($0)"
            },
            action.diagnostic,
        ].compactMap { value in
            value?.isEmpty == false ? value : nil
        }.joined(separator: "; ")
        if safe && action.succeeded {
            return result(
                cancellation.isCancelled
                    ? .updatedBeforeCancellation : .updated,
                true,
                evidence.branchOID,
                "Repair reconnected one moved worktree. Worktree bytes, index state, and every ref are unchanged.",
                nil,
                nil
            )
        }
        if safe {
            return result(
                .updatedWithWarning,
                true,
                evidence.branchOID,
                "The moved worktree is reconnected and preserved, but Git reported a warning.",
                action.diagnostic,
                nil
            )
        }
        return result(
            .needsAttention,
            false,
            nil,
            "Moved-worktree Repair completed without a complete preservation proof; review is required.",
            postflightDetail,
            nil
        )
    }

    private func executeInitialize(
        operation: PlannedOperation,
        primary: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken,
        phase: @escaping @Sendable (RepositoryPhase) throws -> Void,
        checkpoint: @escaping @Sendable (RepositoryCheckpoint) throws -> Void,
        startedAt: String,
        result: (
            ResultCode, Bool, String?, String, String?,
            FetchFailureReason?
        ) -> RepositoryResult,
        markFetched: () -> Void,
        setTarget: (String?) -> Void,
        setRemoteBefore: (String?) -> Void,
        setRemoteAfter: (String?) -> Void
    ) throws -> RepositoryResult {
        guard case .initializeDefault? =
                operation.maintenanceEvidence,
              operation.target.expectedLocalOID == nil else {
            throw GitSafetyError.unsafeRepository(
                "Initialize evidence is unavailable"
            )
        }
        let branch = operation.target.resolvedDefault
        let remoteBefore = try helper.optionalCommit(
            branch.remoteTrackingRef,
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        setRemoteBefore(remoteBefore)
        try phase(.fetching)
        let fetch = try helper.runGit(
            arguments: helper.fetchArguments(branch),
            operation: operation,
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation,
            timeout: configuration.fetchTimeoutSeconds
        )
        switch FetchProcessOutcome.resolve(fetch) {
        case .cancelledBeforeCompletion:
            return result(
                .cancelledDuringFetch,
                false,
                nil,
                "Fetching stopped; the absent local default was not initialized.",
                fetch.diagnostic,
                nil
            )
        case .failed:
            let failure = FetchFailureClassifier.classify(fetch)
            return result(
                fetchResultCode(failure),
                false,
                nil,
                fetchExplanation(failure),
                fetch.diagnostic,
                failure
            )
        case .completed:
            break
        }
        let target = try helper.capturedFetchTarget(
            stdout: fetch.stdout,
            truncated: fetch.stdoutTruncated,
            expectedRemoteTrackingRef:
                branch.remoteTrackingRef
        )
        setTarget(target)
        let remoteAfter = try helper.optionalCommit(
            branch.remoteTrackingRef,
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: CancellationToken()
        )
        setRemoteAfter(remoteAfter)
        guard target == branch.advertisedOID,
              remoteAfter == target else {
            throw RemoteDefaultResolutionError.changed
        }
        markFetched()
        try checkpoint(RepositoryCheckpoint(
            repository: operation.target.canonicalClone
                .sourceSnapshot,
            startedAt: startedAt,
            beforeCommit: nil,
            targetCommit: target,
            fetched: true
        ))
        if cancellation.isCancelled {
            return result(
                .cancelledNoUpdate,
                false,
                nil,
                "The fetch completed, but Initialize was cancelled before creating the local default ref.",
                nil,
                nil
            )
        }
        let preserved = try captureWorktrees(
            operation.target.canonicalClone,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        let lock = try primary.acquireCommonDirectoryOperationLock(
            account: account
        )
        defer { withExtendedLifetime(lock) {} }
        try helper.validateRuntimeEligibility(operation)
        try primary.revalidate()
        try primary.rejectBusyState(
            defaultBranch: branch.name
        )
        let lockedDefault = try helper.resolveRemoteDefault(
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        guard lockedDefault.name == branch.name,
              lockedDefault.advertisedOID == target,
              try helper.optionalCommit(
                  branch.localRef,
                  handle: primary,
                  frozen: frozen,
                  admission: admission,
                  cancellation: cancellation
              ) == nil,
              try helper.optionalCommit(
                  branch.remoteTrackingRef,
                  handle: primary,
                  frozen: frozen,
                  admission: admission,
                  cancellation: cancellation
              ) == target else {
            throw GitSafetyError.unsafeRepository(
                "Initialize ref evidence changed"
            )
        }
        let claims = try worktreeClaims(
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        guard !claims.contains(branch.localRef) else {
            throw GitSafetyError.unsafeRepository(
                "Initialize target gained a worktree claim"
            )
        }
        let objectFormat = try objectFormat(
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        guard target.count == objectFormat.oidLength else {
            throw GitSafetyError.unsafeRepository(
                "Initialize object format changed"
            )
        }
        try requireCommitObject(
            target,
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        let refsBefore = try refMap(
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        try requireAvailableNamespace(
            branch.localRef,
            refs: refsBefore.keys
        )
        #if SHADOW_SYNC_TESTING
        configuration.maintenanceBeforeAction?(
            operation.kind,
            primary.candidate
        )
        #endif
        if cancellation.isCancelled {
            return result(
                .cancelledNoUpdate,
                false,
                nil,
                "Initialize was cancelled before the zero-old-OID compare-and-swap.",
                nil,
                nil
            )
        }
        try phase(.updating)
        let finalDefault = try helper.resolveRemoteDefault(
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        guard finalDefault.name == branch.name,
              finalDefault.advertisedOID == target else {
            throw RemoteDefaultResolutionError.changed
        }
        let finalRefs = try refMap(
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        guard finalRefs == refsBefore else {
            throw GitSafetyError.unsafeRepository(
                "Initialize ref namespace changed"
            )
        }
        try requireAvailableNamespace(
            branch.localRef,
            refs: finalRefs.keys
        )
        let finalPreserved = try captureWorktrees(
            operation.target.canonicalClone,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        guard finalPreserved == preserved else {
            throw GitSafetyError.unsafeRepository(
                "Initialize worktree state changed"
            )
        }
        let finalClaims = try worktreeClaims(
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        guard !finalClaims.contains(branch.localRef) else {
            throw GitSafetyError.unsafeRepository(
                "Initialize target gained a worktree claim"
            )
        }
        if cancellation.isCancelled {
            return result(
                .cancelledNoUpdate,
                false,
                nil,
                "Initialize was cancelled before the zero-old-OID compare-and-swap.",
                nil,
                nil
            )
        }
        let zero = String(
            repeating: "0",
            count: objectFormat.oidLength
        )
        let action = try helper.runGit(
            arguments:
                RepositoryMaintenancePlanner
                    .gitDirectoryArguments(
                        handle: primary,
                        command: [
                            "update-ref", branch.localRef,
                            target, zero,
                        ]
                    ),
            operation: operation,
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation,
            timeout: configuration.localTimeoutSeconds
        )
        #if SHADOW_SYNC_TESTING
        configuration.maintenanceAfterAction?(
            operation.kind,
            primary.candidate
        )
        #endif
        let observed = try? helper.optionalCommit(
            branch.localRef,
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: CancellationToken()
        )
        let refsAfter = try? refMap(
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: CancellationToken()
        )
        var expectedRefs = refsBefore
        expectedRefs[branch.localRef] = target
        let preservedAfter = try? captureWorktrees(
            operation.target.canonicalClone,
            frozen: frozen,
            admission: admission,
            cancellation: CancellationToken()
        )
        let safe = observed == target
            && refsAfter == expectedRefs
            && preservedAfter == preserved
        if safe && action.succeeded {
            return result(
                cancellation.isCancelled
                    ? .updatedBeforeCancellation : .updated,
                true,
                target,
                "Initialize created the absent local actual-default ref at the exact fetched commit. No checkout, index, or worktree changed.",
                nil,
                nil
            )
        }
        if observed == nil {
            return result(
                .failedUpdate,
                false,
                nil,
                "Git or an applicable reference hook refused Initialize; the local default ref remains absent.",
                action.diagnostic,
                nil
            )
        }
        return result(
            .needsAttention,
            false,
            observed,
            action.succeeded
                ? "Initialize ended with an ambiguous ref or preservation result; review is required."
                : "Initialize's zero-old-OID compare-and-swap did not succeed; re-inspect the externally changed ref.",
            action.diagnostic,
            nil
        )
    }

    private struct WorktreeSnapshot: Equatable {
        let roots: [String: RepositoryDirectoryIdentity]
        let states: [String: String]
    }

    private func captureWorktrees(
        _ clone: LocalClone,
        excludingPaths: Set<String> = [],
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws -> WorktreeSnapshot {
        var roots: [String: RepositoryDirectoryIdentity] = [:]
        var states: [String: String] = [:]
        for worktree in clone.worktrees {
            if excludingPaths.contains(where: {
                RepositoryMaintenancePlanner.samePotentialPath(
                    worktree.path,
                    $0
                )
            }) {
                continue
            }
            guard let root = worktree.rootIdentity,
                  worktree.verification == .verified else {
                throw GitSafetyError.unsafeRepository(
                    "worktree preservation inventory is incomplete"
                )
            }
            let handle = try RepositoryHandle.openOperationWorktree(
                clone,
                targetWorktree: worktree
            )
            let status = try helper.runGit(
                arguments: [
                    "--no-replace-objects", "--no-lazy-fetch",
                    "status", "--porcelain=v1", "-z",
                    "--untracked-files=all",
                    "--ignored=matching",
                ],
                operation: nil,
                handle: handle,
                frozen: frozen,
                admission: admission,
                cancellation: cancellation,
                timeout: configuration.localTimeoutSeconds
            )
            let index = try helper.runGit(
                arguments: [
                    "--no-replace-objects", "--no-lazy-fetch",
                    "ls-files", "-v", "-z",
                ],
                operation: nil,
                handle: handle,
                frozen: frozen,
                admission: admission,
                cancellation: cancellation,
                timeout: configuration.localTimeoutSeconds
            )
            guard status.succeeded,
                  !status.stdoutTruncated,
                  index.succeeded,
                  !index.stdoutTruncated else {
                throw GitSafetyError.unsafeRepository(
                    "worktree preservation state is unavailable"
                )
            }
            roots[worktree.path] = root
            states[worktree.path] = digest(
                status.stdout + index.stdout
            )
        }
        return WorktreeSnapshot(roots: roots, states: states)
    }

    private func prunePostflight(
        expected: [PrunableRegistrationEvidence],
        refsBefore: [String: String],
        preserved: WorktreeSnapshot,
        unselectedRegistrationsBefore: String,
        clone: LocalClone,
        primary: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot
    ) throws -> Bool {
        for item in expected {
            let path = URL(
                fileURLWithPath:
                    primary.identity.commonDirectoryPath
            ).appendingPathComponent(
                "worktrees/\(item.registrationID)"
            ).path
            var info = stat()
            guard lstat(path, &info) != 0, errno == ENOENT else {
                return false
            }
            var worktree = stat()
            guard lstat(item.expectedWorktreePath, &worktree) != 0,
                  errno == ENOENT else {
                return false
            }
        }
        let refsAfter = try refMap(
            handle: primary,
            frozen: frozen,
            admission: admission,
            cancellation: CancellationToken()
        )
        let worktreesAfter = try captureWorktrees(
            clone,
            excludingPaths: Set(
                expected.map(\.expectedWorktreePath)
            ),
            frozen: frozen,
            admission: admission,
            cancellation: CancellationToken()
        )
        let unselectedRegistrationsAfter =
            try RepositoryMaintenancePlanner.registrationSetDigest(
                commonDirectory:
                    primary.identity.commonDirectoryPath,
                excluding:
                    Set(expected.map(\.registrationID)),
                account: account
            )
        return refsAfter == refsBefore
            && worktreesAfter == preserved
            && unselectedRegistrationsAfter
                == unselectedRegistrationsBefore
    }

    private func requireClean(
        _ moved: RepositoryHandle,
        branchRef: String,
        expectedOID: String,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws {
        try moved.rejectBusyState(
            defaultBranch: String(
                branchRef.dropFirst("refs/heads/".count)
            )
        )
        let status = try helper.runGit(
            arguments: [
                "--no-replace-objects", "--no-lazy-fetch",
                "status", "--porcelain=v1", "-z",
                "--untracked-files=all",
            ],
            operation: nil,
            handle: moved,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation,
            timeout: configuration.localTimeoutSeconds
        )
        let index = try helper.runGit(
            arguments: [
                "--no-replace-objects", "--no-lazy-fetch",
                "ls-files", "-v", "-z",
            ],
            operation: nil,
            handle: moved,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation,
            timeout: configuration.localTimeoutSeconds
        )
        let oid = try helper.optionalCommit(
            branchRef,
            handle: moved,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation
        )
        guard status.succeeded,
              status.stdout.isEmpty,
              !status.stdoutTruncated,
              index.succeeded,
              !index.stdoutTruncated,
              (try? GitIndexVisibility.validate(
                  index.stdout
              )) != nil,
              oid == expectedOID else {
            throw GitSafetyError.dirty
        }
    }

    private func refMap(
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws -> [String: String] {
        let output = try helper.runGit(
            arguments: [
                "--no-replace-objects", "--no-lazy-fetch",
                "for-each-ref",
                "--format=%(refname)%00%(objectname)%00",
                "refs/",
            ],
            operation: nil,
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation,
            timeout: configuration.localTimeoutSeconds
        )
        guard output.succeeded,
              !output.stdoutTruncated else {
            throw GitSafetyError.commandFailed(
                "git for-each-ref",
                output.status,
                output.diagnostic
            )
        }
        var fields = output.stdout.split(
            separator: 0,
            omittingEmptySubsequences: false
        ).map {
            String(decoding: $0, as: UTF8.self)
                .trimmingCharacters(in: .newlines)
        }
        while fields.last?.isEmpty == true {
            fields.removeLast()
        }
        guard fields.count.isMultiple(of: 2) else {
            throw GitSafetyError.unsafeRepository(
                "ref inventory is malformed"
            )
        }
        var refs: [String: String] = [:]
        for index in stride(
            from: 0,
            to: fields.count,
            by: 2
        ) {
            let ref = fields[index]
            let oid = fields[index + 1].lowercased()
            guard !ref.isEmpty,
                  validOID(oid),
                  refs[ref] == nil else {
                throw GitSafetyError.unsafeRepository(
                    "ref inventory is malformed"
                )
            }
            refs[ref] = oid
        }
        return refs
    }

    private func worktreeClaims(
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws -> Set<String> {
        let output = try helper.runGit(
            arguments: [
                "--no-replace-objects", "--no-lazy-fetch",
                "worktree", "list", "--porcelain", "-z",
            ],
            operation: nil,
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation,
            timeout: configuration.localTimeoutSeconds
        )
        guard output.succeeded,
              !output.stdoutTruncated else {
            throw GitSafetyError.commandFailed(
                "git worktree list",
                output.status,
                output.diagnostic
            )
        }
        var claims = Set<String>()
        var sawWorktree = false
        for raw in output.stdout.split(
            separator: 0,
            omittingEmptySubsequences: true
        ) {
            let field = String(decoding: raw, as: UTF8.self)
            if field.hasPrefix("worktree ") {
                guard String(
                    field.dropFirst("worktree ".count)
                ).hasPrefix("/") else {
                    throw GitSafetyError.unsafeRepository(
                        "worktree claims are malformed"
                    )
                }
                sawWorktree = true
            } else if field.hasPrefix("HEAD ") {
                guard sawWorktree,
                      validOID(
                          String(field.dropFirst("HEAD ".count))
                      ) else {
                    throw GitSafetyError.unsafeRepository(
                        "worktree claims are malformed"
                    )
                }
            } else if field.hasPrefix("branch ") {
                let ref = String(
                    field.dropFirst("branch ".count)
                )
                guard sawWorktree,
                      GitReferenceSyntax
                        .isValidLocalBranchRef(ref),
                      claims.insert(ref).inserted else {
                    throw GitSafetyError.unsafeRepository(
                        "worktree claims are incomplete"
                    )
                }
            } else if field == "detached"
                || field == "bare"
                || field == "locked"
                || field.hasPrefix("locked ")
                || field == "prunable"
                || field.hasPrefix("prunable ") {
                continue
            } else {
                throw GitSafetyError.unsafeRepository(
                    "worktree claims contain an unknown field"
                )
            }
        }
        guard sawWorktree else {
            throw GitSafetyError.unsafeRepository(
                "worktree claims are empty"
            )
        }
        return claims
    }

    private enum ObjectFormat: Equatable {
        case sha1
        case sha256

        var oidLength: Int {
            self == .sha1 ? 40 : 64
        }
    }

    private func objectFormat(
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws -> ObjectFormat {
        let output = try helper.runGit(
            arguments: [
                "--no-replace-objects", "--no-lazy-fetch",
                "rev-parse", "--show-object-format",
            ],
            operation: nil,
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation,
            timeout: configuration.localTimeoutSeconds
        )
        let value = String(
            data: output.stdout,
            encoding: .utf8
        )?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard output.succeeded,
              !output.stdoutTruncated else {
            throw GitSafetyError.unsafeRepository(
                "repository object format is unavailable"
            )
        }
        switch value {
        case "sha1": return .sha1
        case "sha256": return .sha256
        default:
            throw GitSafetyError.unsafeRepository(
                "repository object format is unsupported"
            )
        }
    }

    private func requireCommitObject(
        _ oid: String,
        handle: RepositoryHandle,
        frozen: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot,
        cancellation: CancellationToken
    ) throws {
        let output = try helper.runGit(
            arguments: [
                "--no-replace-objects", "--no-lazy-fetch",
                "cat-file", "-e", "\(oid)^{commit}",
            ],
            operation: nil,
            handle: handle,
            frozen: frozen,
            admission: admission,
            cancellation: cancellation,
            timeout: configuration.localTimeoutSeconds
        )
        guard output.succeeded,
              output.stdout.isEmpty,
              !output.stdoutTruncated else {
            throw GitSafetyError.unsafeRepository(
                "Initialize target is not a verified commit"
            )
        }
    }

    private func requireAvailableNamespace(
        _ target: String,
        refs: Dictionary<String, String>.Keys
    ) throws {
        guard !refs.contains(target),
              !refs.contains(where: {
                  $0.hasPrefix(target + "/")
                    || target.hasPrefix($0 + "/")
              }) else {
            throw GitSafetyError.unsafeRepository(
                "Initialize ref namespace is occupied"
            )
        }
    }

    private func requireAbsentPath(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) != 0, errno == ENOENT else {
            throw GitSafetyError.unsafeRepository(
                "the previous worktree path is no longer absent"
            )
        }
    }

    private func locationKind(_ path: String) -> WorktreeLocationKind {
        if path.hasPrefix(account.homeDirectory + "/dev/") {
            return .dev
        }
        if path.hasPrefix(
            account.homeDirectory + "/.cursor/worktrees/"
        ) {
            return .cursorManaged
        }
        if path.hasPrefix(
            account.homeDirectory + "/.local/share/awa/worktrees/"
        ) {
            return .awaManaged
        }
        return .external
    }

    private func fetchResultCode(
        _ failure: FetchFailureReason
    ) -> ResultCode {
        switch failure {
        case .authentication: return .failedFetchAuthentication
        case .dns, .transport, .timeout:
            return .failedFetchNetwork
        case .other: return .failedFetch
        }
    }

    private func fetchExplanation(
        _ failure: FetchFailureReason
    ) -> String {
        switch failure {
        case .authentication:
            return "GitHub authentication is required; the absent local default was not initialized."
        case .dns:
            return "DNS lookup failed; the absent local default was not initialized."
        case .transport:
            return "The remote could not be reached; the absent local default was not initialized."
        case .timeout:
            return "The exact default-branch fetch timed out; the absent local default was not initialized."
        case .other:
            return "The exact default-branch fetch failed; the absent local default was not initialized."
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func validOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy {
                $0.isNumber || ("a"..."f").contains($0.lowercased())
            }
    }
}

private struct WorktreeBytesSnapshot: Equatable {
    let digest: String
    let files: Int
    let bytes: Int64

    static func capture(
        path: String,
        account: EffectiveAccount,
        administrativeIndexPath: String? = nil
    ) throws -> WorktreeBytesSnapshot {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else {
            throw GitSafetyError.unsafeRepository(
                "worktree byte inventory is unavailable"
            )
        }
        var rows: [String] = []
        var files = 0
        var bytes: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            let relative = String(
                url.path.dropFirst(path.count + 1)
            )
            if relative == ".git" {
                enumerator.skipDescendants()
                continue
            }
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  info.st_uid == account.uid,
                  (info.st_mode & S_IFMT) != S_IFLNK else {
                throw GitSafetyError.unsafeRepository(
                    "worktree byte inventory contains unsafe entries"
                )
            }
            let relativeDigest = SHA256.hash(
                data: Data(relative.utf8)
            ).map {
                String(format: "%02x", $0)
            }.joined()
            if FileIdentity(info).isDirectory {
                rows.append(
                    "d|\(relative.utf8.count)|\(relativeDigest)|\(info.st_mode & 0o7777)"
                )
                continue
            }
            guard FileIdentity(info).isRegular,
                  info.st_nlink == 1 else {
                throw GitSafetyError.unsafeRepository(
                    "worktree byte inventory contains an unsupported entry"
                )
            }
            files += 1
            bytes += Int64(info.st_size)
            guard files <= 10_000, bytes <= 67_108_864 else {
                throw GitSafetyError.unsafeRepository(
                    "worktree byte inventory exceeds its safety bound"
                )
            }
            let descriptor = Darwin.open(
                url.path,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw GitSafetyError.unsafeRepository(
                    "worktree file could not be opened"
                )
            }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  FileIdentity(opened).matchesStableNode(
                      FileIdentity(info)
                  ) else {
                close(descriptor)
                throw GitSafetyError.unsafeRepository(
                    "worktree file identity changed"
                )
            }
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(
                    descriptor,
                    &buffer,
                    buffer.count
                )
                if count > 0 {
                    hasher.update(
                        data: Data(buffer.prefix(count))
                    )
                } else if count == 0 {
                    break
                } else if errno != EINTR {
                    close(descriptor)
                    throw GitSafetyError.unsafeRepository(
                        "worktree file could not be read"
                    )
                }
            }
            close(descriptor)
            let fileDigest = hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
            rows.append(
                "f|\(relative.utf8.count)|\(relativeDigest)|\(info.st_mode & 0o7777)|\(info.st_size)|\(fileDigest)"
            )
        }
        guard !enumerationFailed else {
            throw GitSafetyError.unsafeRepository(
                "worktree byte inventory is incomplete"
            )
        }
        if let administrativeIndexPath {
            var indexInfo = stat()
            guard lstat(administrativeIndexPath, &indexInfo) == 0,
                  FileIdentity(indexInfo).isRegular,
                  indexInfo.st_uid == account.uid,
                  indexInfo.st_nlink == 1,
                  (indexInfo.st_mode & 0o022) == 0,
                  indexInfo.st_size >= 0,
                  indexInfo.st_size <= 67_108_864 else {
                throw GitSafetyError.unsafeRepository(
                    "worktree index inventory is unsafe"
                )
            }
            let indexDescriptor = Darwin.open(
                administrativeIndexPath,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard indexDescriptor >= 0 else {
                throw GitSafetyError.unsafeRepository(
                    "worktree index could not be opened"
                )
            }
            defer { close(indexDescriptor) }
            var openedIndex = stat()
            guard fstat(indexDescriptor, &openedIndex) == 0,
                  FileIdentity(openedIndex).matchesStableNode(
                      FileIdentity(indexInfo)
                  ) else {
                throw GitSafetyError.unsafeRepository(
                    "worktree index identity changed"
                )
            }
            var indexHasher = SHA256()
            var indexBuffer = [UInt8](
                repeating: 0,
                count: 16_384
            )
            while true {
                let count = Darwin.read(
                    indexDescriptor,
                    &indexBuffer,
                    indexBuffer.count
                )
                if count > 0 {
                    indexHasher.update(
                        data: Data(indexBuffer.prefix(count))
                    )
                } else if count == 0 {
                    break
                } else if errno != EINTR {
                    throw GitSafetyError.unsafeRepository(
                        "worktree index could not be read"
                    )
                }
            }
            let indexDigest = indexHasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
            rows.append(
                "i|\(indexInfo.st_mode & 0o7777)|\(indexInfo.st_size)|\(indexDigest)"
            )
            files += 1
            bytes += Int64(indexInfo.st_size)
            guard files <= 10_001,
                  bytes <= 67_108_864 else {
                throw GitSafetyError.unsafeRepository(
                    "worktree byte inventory exceeds its safety bound"
                )
            }
        }
        let material = rows.sorted().joined(separator: "\n")
        let digest = SHA256.hash(
            data: Data(material.utf8)
        ).map {
            String(format: "%02x", $0)
        }.joined()
        return WorktreeBytesSnapshot(
            digest: digest,
            files: files,
            bytes: bytes
        )
    }
}
