import Foundation

struct LocalRepositoryCommandResult: Sendable {
    let status: Int32
    let stdout: Data
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
    let diagnostic: String

    init(
        status: Int32,
        stdout: Data,
        stdoutTruncated: Bool,
        stderrTruncated: Bool = false,
        diagnostic: String
    ) {
        self.status = status
        self.stdout = stdout
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.diagnostic = diagnostic
    }

    var succeeded: Bool {
        status == 0 && !stderrTruncated
    }
}

enum LocalRepositoryInspectionBlock: Equatable, Sendable {
    case busy
    case localMainMissing
    case detachedHead
    case primaryNotOnMain
    case mainInLinkedWorktree
    case dirty
    case hiddenIndex

    var repositoryReason: RepositoryBlockReason {
        switch self {
        case .busy:
            return .busy
        case .localMainMissing:
            return .localMainMissing
        case .detachedHead:
            return .detachedHead
        case .primaryNotOnMain:
            return .primaryNotOnMain
        case .mainInLinkedWorktree:
            return .mainInLinkedWorktree
        case .dirty:
            return .dirty
        case .hiddenIndex:
            return .hiddenIndex
        }
    }

    var safetyError: GitSafetyError {
        switch self {
        case .busy:
            return .busy
        case .localMainMissing:
            return .localMainMissing
        case .detachedHead:
            return .detached
        case .primaryNotOnMain:
            return .primaryNotOnMain
        case .mainInLinkedWorktree:
            return .mainInLinkedWorktree
        case .dirty:
            return .dirty
        case .hiddenIndex:
            return .hiddenIndex
        }
    }
}

struct LocalRepositoryInspection: Equatable, Sendable {
    typealias CommandRunner = ([String]) throws
        -> LocalRepositoryCommandResult

    let localMainCommit: String?
    let cachedMainRelation: RepositoryCachedMainRelation
    let block: LocalRepositoryInspectionBlock?

    var blockedReason: RepositoryBlockReason? {
        block?.repositoryReason
    }

    func requireEligible() throws {
        if let block {
            throw block.safetyError
        }
        guard localMainCommit != nil else {
            throw GitSafetyError.localMainMissing
        }
    }

    static func inspect(
        handle: RepositoryHandle,
        knownNoLinkedWorktrees: Bool = false,
        metadata: DiscoveryMetadataAccess? = nil,
        run: CommandRunner
    ) throws -> LocalRepositoryInspection {
        do {
            try DiscoveryMetadataAccess.withHandle(metadata, handle, .busy) { try handle.rejectBusyState() }
        } catch GitSafetyError.busy {
            return LocalRepositoryInspection(
                localMainCommit: nil,
                cachedMainRelation: .unavailable,
                block: .busy
            )
        }

        let worktreeRecords: [WorktreeRecord]
        if knownNoLinkedWorktrees {
            worktreeRecords = [
                WorktreeRecord(
                    path: handle.candidate.path,
                    branch: nil,
                    detached: true
                ),
            ]
        } else {
            let worktrees = try run(localArguments([
                "worktree", "list", "--porcelain", "-z",
            ]))
            guard worktrees.succeeded, !worktrees.stdoutTruncated else {
                throw GitSafetyError.commandFailed(
                    "git worktree",
                    worktrees.status,
                    worktrees.diagnostic
                )
            }
            worktreeRecords = try parseWorktreeRecords(worktrees.stdout)
        }
        let verifiedWorktrees = try worktreeRecords.map { record in
            (
                record: record,
                claim: try DiscoveryMetadataAccess.withHandle(metadata, handle, .primaryClaim(record.path)) {
                    try handle.verifyWorktreeClaim(path: record.path)
                }
            )
        }
        let physicalKeys = Set(verifiedWorktrees.map {
            "\($0.claim.rootIdentity.device):\($0.claim.rootIdentity.inode)"
        })
        guard physicalKeys.count == verifiedWorktrees.count,
              verifiedWorktrees.filter(\.claim.isPrimary).count == 1,
              handle.candidate.linkedWorktrees.isEmpty
                || verifiedWorktrees.filter({
                    !$0.claim.isPrimary
                }).count == handle.candidate.linkedWorktrees.count else {
            throw GitSafetyError.unsafeRepository(
                "worktree output does not match verified physical topology"
            )
        }

        let status = try workingCopyStatus(run: run)
        let references: ReferenceSnapshot
        if status.branchHead == "main",
           !status.isInitial,
           let branchOID = status.branchOID,
           let direct = try directMainSnapshot(
               handle: handle,
               branchOID: branchOID,
               metadata: metadata
           ) {
            references = direct
        } else {
            references = try referenceSnapshot(
                branchHead: status.branchHead,
                run: run
            )
        }
        guard let localMain = references.localMain else {
            return LocalRepositoryInspection(
                localMainCommit: nil,
                cachedMainRelation: .unavailable,
                block: .localMainMissing
            )
        }

        let branch: String?
        if let currentBranch = references.currentBranch {
            guard status.branchHead == currentBranch else {
                throw GitSafetyError.commandFailed(
                    "git symbolic-ref",
                    0,
                    ""
                )
            }
            branch = currentBranch
        } else if status.isInitial {
            branch = status.branchHead
        } else if status.branchHead == "(detached)" {
            branch = nil
        } else {
            guard status.branchHead != "(unknown)" else {
                throw GitSafetyError.commandFailed(
                    "git symbolic-ref",
                    0,
                    ""
                )
            }
            branch = status.branchHead
        }

        let mainInLinkedWorktree = verifiedWorktrees.contains {
            !$0.claim.isPrimary
                && $0.record.branch == "refs/heads/main"
        }
        if branch == "main", mainInLinkedWorktree {
            throw GitSafetyError.unsafeRepository(
                "main appears in both primary and linked worktrees"
            )
        }

        let hasHiddenIndex: Bool
        if knownNoLinkedWorktrees,
           let directIndexState =
                try DiscoveryMetadataAccess.withHandle(metadata, handle, .index, { try handle.readOnlyHiddenIndexState() }) {
            hasHiddenIndex = directIndexState
        } else {
            let index = try run(localArguments([
                "ls-files", "-v", "-z",
            ]))
            guard index.succeeded, !index.stdoutTruncated else {
                throw GitSafetyError.commandFailed(
                    "git ls-files",
                    index.status,
                    index.diagnostic
                )
            }
            do {
                try GitIndexVisibility.validate(index.stdout)
                hasHiddenIndex = false
            } catch GitSafetyError.hiddenIndex {
                hasHiddenIndex = true
            }
        }

        let cachedRelation = try cachedRelation(
            localMain: localMain,
            cachedOriginMain: references.cachedOriginMain,
            run: run
        )
        let block: LocalRepositoryInspectionBlock?
        if branch == nil {
            block = .detachedHead
        } else if mainInLinkedWorktree {
            block = .mainInLinkedWorktree
        } else if branch != "main" {
            block = .primaryNotOnMain
        } else if status.isDirty {
            block = .dirty
        } else if hasHiddenIndex {
            block = .hiddenIndex
        } else {
            block = nil
        }
        return LocalRepositoryInspection(
            localMainCommit: localMain,
            cachedMainRelation: cachedRelation,
            block: block
        )
    }

    private struct WorktreeRecord {
        let path: String
        let branch: String?
        let detached: Bool
    }

    private static func parseWorktreeRecords(
        _ data: Data
    ) throws -> [WorktreeRecord] {
        guard !data.isEmpty else {
            throw GitSafetyError.unsafeRepository(
                "worktree output is empty"
            )
        }
        var fields: [String] = []
        for field in data.split(
            separator: 0,
            omittingEmptySubsequences: false
        ) {
            if field.isEmpty {
                continue
            }
            guard let value = String(data: field, encoding: .utf8),
                  !value.contains("\n"),
                  !value.contains("\r"),
                  !value.contains("\0") else {
                throw GitSafetyError.unsafeRepository(
                    "worktree output is malformed"
                )
            }
            fields.append(value)
        }
        var records: [WorktreeRecord] = []
        var path: String?
        var branch: String?
        var detached = false
        for field in fields {
            if field.hasPrefix("worktree ") {
                if let path {
                    records.append(
                        WorktreeRecord(
                            path: path,
                            branch: branch,
                            detached: detached
                        )
                    )
                }
                path = String(field.dropFirst("worktree ".count))
                branch = nil
                detached = false
            } else if field.hasPrefix("branch ") {
                guard path != nil, branch == nil else {
                    throw GitSafetyError.unsafeRepository(
                        "worktree branch output is ambiguous"
                    )
                }
                branch = String(field.dropFirst("branch ".count))
            } else if field == "detached" || field == "bare" {
                guard path != nil, branch == nil, !detached else {
                    throw GitSafetyError.unsafeRepository(
                        "worktree attachment output is ambiguous"
                    )
                }
                detached = true
            } else if field.hasPrefix("HEAD ")
                || field == "locked"
                || field.hasPrefix("locked ")
                || field == "prunable"
                || field.hasPrefix("prunable ") {
                continue
            } else {
                throw GitSafetyError.unsafeRepository(
                    "worktree output contains an unknown field"
                )
            }
        }
        if let path {
            records.append(
                WorktreeRecord(
                    path: path,
                    branch: branch,
                    detached: detached
                )
            )
        }
        guard !records.isEmpty,
              Set(records.map(\.path)).count == records.count,
              records.allSatisfy({
                  $0.path.hasPrefix("/")
                    && !$0.path.contains("\n")
                    && !$0.path.contains("\r")
                    && !$0.path.contains("\0")
                    && ($0.branch != nil || $0.detached)
              }) else {
            throw GitSafetyError.unsafeRepository(
                "worktree output is incomplete"
            )
        }
        return records
    }

    private static func requiredCommit(
        _ reference: String,
        run: CommandRunner
    ) throws -> String {
        let result = try run(localArguments([
            "rev-parse", "--verify", "\(reference)^{commit}",
        ]))
        guard result.succeeded,
              !result.stdoutTruncated,
              let value = objectID(result.stdout) else {
            throw GitSafetyError.commandFailed(
                "git rev-parse",
                result.status,
                result.diagnostic
            )
        }
        return value
    }

    private struct ReferenceSnapshot {
        let localMain: String?
        let cachedOriginMain: String?
        let currentBranch: String?
    }

    private static func directMainSnapshot(
        handle: RepositoryHandle,
        branchOID: String,
        metadata: DiscoveryMetadataAccess?
    ) throws -> ReferenceSnapshot? {
        guard let localMain = try DiscoveryMetadataAccess.withHandle(metadata, handle, .mainReference, { try handle.readOnlyMainCommit() }),
              localMain == branchOID,
              try DiscoveryMetadataAccess.withHandle(metadata, handle, .remoteReference, { try handle.readOnlyRemoteMainCommit() }) == nil,
              try DiscoveryMetadataAccess.withHandle(metadata, handle, .looseCommit(localMain), { try handle.readOnlyLooseCommitObject(localMain) }) == true else {
            return nil
        }
        return ReferenceSnapshot(
            localMain: localMain,
            cachedOriginMain: nil,
            currentBranch: "main"
        )
    }

    private static func referenceSnapshot(
        branchHead: String,
        run: CommandRunner
    ) throws -> ReferenceSnapshot {
        let result = try run(localArguments([
            "for-each-ref",
            "--format=%(refname)%00%(objectname)%00%(objecttype)%00%(*objectname)%00%(*objecttype)%00",
            "refs/heads/main",
            "refs/remotes/origin/main",
        ]))
        guard result.succeeded, !result.stdoutTruncated else {
            throw GitSafetyError.commandFailed(
                "git show-ref",
                result.status,
                result.diagnostic
            )
        }
        guard result.stdout.isEmpty || result.stdout.last == 0x0A else {
            throw GitSafetyError.commandFailed(
                "git rev-parse",
                result.status,
                result.diagnostic
            )
        }
        var references: [String: String] = [:]
        for line in result.stdout.split(
            separator: 0x0A,
            omittingEmptySubsequences: true
        ) {
            let fields = line.split(
                separator: 0,
                omittingEmptySubsequences: false
            )
            guard fields.count == 6,
                  fields[5].isEmpty,
                  let name = String(data: Data(fields[0]), encoding: .utf8),
                  name == "refs/heads/main"
                    || name == "refs/remotes/origin/main" else {
                throw GitSafetyError.commandFailed(
                    "git rev-parse",
                    result.status,
                    result.diagnostic
                )
            }
            guard references[name] == nil else {
                throw GitSafetyError.commandFailed(
                    "git rev-parse",
                    result.status,
                    result.diagnostic
                )
            }
            let oid: String?
            if fields[2] == Data("commit".utf8),
               fields[3].isEmpty,
               fields[4].isEmpty {
                oid = objectID(Data(fields[1]))
            } else if fields[2] == Data("tag".utf8),
                      fields[4] == Data("commit".utf8) {
                oid = objectID(Data(fields[3]))
            } else {
                oid = nil
            }
            guard let oid else {
                throw GitSafetyError.commandFailed(
                    "git rev-parse",
                    result.status,
                    result.diagnostic
                )
            }
            references[name] = oid
        }
        return ReferenceSnapshot(
            localMain: references["refs/heads/main"],
            cachedOriginMain: references["refs/remotes/origin/main"],
            currentBranch:
                branchHead == "(detached)" ? nil : branchHead
        )
    }

    private struct WorkingCopyStatus {
        let branchHead: String
        let branchOID: String?
        let isInitial: Bool
        let isDirty: Bool
    }

    private static func workingCopyStatus(
        run: CommandRunner
    ) throws -> WorkingCopyStatus {
        let result = try run(localArguments([
            "status",
            "--porcelain=v2",
            "-z",
            "--branch",
            "--untracked-files=all",
        ]))
        guard result.succeeded, !result.stdoutTruncated else {
            throw GitSafetyError.commandFailed(
                "git status",
                result.status,
                result.diagnostic
            )
        }
        guard result.stdout.isEmpty || result.stdout.last == 0 else {
            throw GitSafetyError.commandFailed(
                "git status",
                result.status,
                result.diagnostic
            )
        }
        var fields = result.stdout.split(
            separator: 0,
            omittingEmptySubsequences: false
        )
        if !fields.isEmpty {
            fields.removeLast()
        }
        var branchHead: String?
        var branchOID: String?
        var isDirty = false
        var expectsRenameSource = false
        for field in fields {
            guard !field.isEmpty else {
                throw GitSafetyError.commandFailed(
                    "git status",
                    result.status,
                    result.diagnostic
                )
            }
            if expectsRenameSource {
                expectsRenameSource = false
                isDirty = true
                continue
            }
            if field.starts(with: Data("# ".utf8)) {
                guard let value = String(
                    data: Data(field),
                    encoding: .utf8
                ), !value.contains("\n"),
                   !value.contains("\r") else {
                    throw GitSafetyError.commandFailed(
                        "git symbolic-ref",
                        result.status,
                        result.diagnostic
                    )
                }
                if value.hasPrefix("# branch.oid ") {
                    guard branchOID == nil else {
                        throw GitSafetyError.commandFailed(
                            "git rev-parse",
                            result.status,
                            result.diagnostic
                        )
                    }
                    let oid = String(
                        value.dropFirst("# branch.oid ".count)
                    )
                    guard oid == "(initial)"
                            || objectID(Data(oid.utf8)) != nil else {
                        throw GitSafetyError.commandFailed(
                            "git rev-parse",
                            result.status,
                            result.diagnostic
                        )
                    }
                    branchOID = oid
                } else if value.hasPrefix("# branch.head ") {
                    guard branchHead == nil else {
                        throw GitSafetyError.commandFailed(
                            "git symbolic-ref",
                            result.status,
                            result.diagnostic
                        )
                    }
                    let head = String(
                        value.dropFirst("# branch.head ".count)
                    )
                    guard !head.isEmpty,
                          head != "(unknown)" else {
                        throw GitSafetyError.commandFailed(
                            "git symbolic-ref",
                            result.status,
                            result.diagnostic
                        )
                    }
                    branchHead = head
                } else if value.hasPrefix("# branch.upstream ")
                            || value.hasPrefix("# branch.ab ") {
                    continue
                } else {
                    throw GitSafetyError.commandFailed(
                        "git status",
                        result.status,
                        result.diagnostic
                    )
                }
                continue
            }
            let parts: [Data.SubSequence]
            switch field.first {
            case UInt8(ascii: "1"):
                parts = field.split(
                    separator: UInt8(ascii: " "),
                    maxSplits: 8,
                    omittingEmptySubsequences: false
                )
                guard parts.count == 9 else {
                    throw GitSafetyError.commandFailed(
                        "git status", result.status, result.diagnostic
                    )
                }
            case UInt8(ascii: "2"):
                parts = field.split(
                    separator: UInt8(ascii: " "),
                    maxSplits: 9,
                    omittingEmptySubsequences: false
                )
                guard parts.count == 10 else {
                    throw GitSafetyError.commandFailed(
                        "git status", result.status, result.diagnostic
                    )
                }
                expectsRenameSource = true
            case UInt8(ascii: "u"):
                parts = field.split(
                    separator: UInt8(ascii: " "),
                    maxSplits: 10,
                    omittingEmptySubsequences: false
                )
                guard parts.count == 11 else {
                    throw GitSafetyError.commandFailed(
                        "git status", result.status, result.diagnostic
                    )
                }
            case UInt8(ascii: "?"), UInt8(ascii: "!"):
                parts = field.split(
                    separator: UInt8(ascii: " "),
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                guard parts.count == 2, !parts[1].isEmpty else {
                    throw GitSafetyError.commandFailed(
                        "git status", result.status, result.diagnostic
                    )
                }
            default:
                throw GitSafetyError.commandFailed(
                    "git status", result.status, result.diagnostic
                )
            }
            isDirty = true
        }
        guard !expectsRenameSource else {
            throw GitSafetyError.commandFailed(
                "git status",
                result.status,
                result.diagnostic
            )
        }
        guard let branchOID else {
            throw GitSafetyError.commandFailed(
                "git rev-parse",
                result.status,
                result.diagnostic
            )
        }
        guard let branchHead else {
            throw GitSafetyError.commandFailed(
                "git symbolic-ref",
                result.status,
                result.diagnostic
            )
        }
        return WorkingCopyStatus(
            branchHead: branchHead,
            branchOID:
                branchOID == "(initial)" ? nil : branchOID,
            isInitial: branchOID == "(initial)",
            isDirty: isDirty
        )
    }

    private static func cachedRelation(
        localMain: String,
        cachedOriginMain: String?,
        run: CommandRunner
    ) throws -> RepositoryCachedMainRelation {
        guard let cachedOriginMain else {
            return .unavailable
        }
        if localMain == cachedOriginMain {
            return .equal
        }
        if try isAncestor(localMain, of: cachedOriginMain, run: run) {
            return .behind
        }
        if try isAncestor(cachedOriginMain, of: localMain, run: run) {
            return .ahead
        }
        return .diverged
    }

    private static func isAncestor(
        _ ancestor: String,
        of descendant: String,
        run: CommandRunner
    ) throws -> Bool {
        let result = try run(localArguments([
            "merge-base", "--is-ancestor", ancestor, descendant,
        ]))
        if result.status == 0 {
            return true
        }
        if result.status == 1 {
            return false
        }
        throw GitSafetyError.commandFailed(
            "git merge-base",
            result.status,
            result.diagnostic
        )
    }

    private static func objectID(_ data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            (value.count == 40 || value.count == 64),
            value.allSatisfy({
                $0.isNumber || ("a"..."f").contains($0)
            }) else {
            return nil
        }
        return value
    }

    private static func localArguments(
        _ command: [String]
    ) -> [String] {
        ["--no-replace-objects", "--no-lazy-fetch"] + command
    }
}

struct DefaultBranchTargetInspection: Equatable, Sendable {
    let localOID: String
    let claimingWorktreeIDs: [String]
    let targetWorktreeID: String
    let targetPath: String
    let clean: Bool
    let hiddenIndex: Bool

    func requireMutableTarget(
        expectedLocalOID: String,
        expectedWorktreeID: String
    ) throws {
        guard localOID == expectedLocalOID else {
            throw GitSafetyError.unsafeRepository(
                "local default branch changed"
            )
        }
        guard claimingWorktreeIDs == [expectedWorktreeID],
              targetWorktreeID == expectedWorktreeID else {
            throw GitSafetyError.unsafeRepository(
                "default branch claim set changed"
            )
        }
        guard clean else {
            throw GitSafetyError.dirty
        }
        guard !hiddenIndex else {
            throw GitSafetyError.hiddenIndex
        }
    }
}

extension LocalRepositoryInspection {
    static func inspectDefaultBranchTarget(
        handle: RepositoryHandle,
        defaultBranch: RemoteDefaultBranch,
        expectedWorktree: Worktree,
        run: CommandRunner
    ) throws -> DefaultBranchTargetInspection {
        try handle.rejectBusyState(defaultBranch: defaultBranch.name)
        let worktrees = try run(localArguments([
            "worktree", "list", "--porcelain", "-z",
        ]))
        guard worktrees.succeeded, !worktrees.stdoutTruncated else {
            throw GitSafetyError.commandFailed(
                "git worktree list",
                worktrees.status,
                worktrees.diagnostic
            )
        }
        let records = try parseWorktreeRecords(worktrees.stdout)
        let defaultRecords = records.filter {
            $0.branch == defaultBranch.localRef
        }
        guard defaultRecords.count == 1,
              let defaultRecord = defaultRecords.first,
              expectedWorktree.verification == .verified,
              expectedWorktree.attachedBranchRef
                == defaultBranch.localRef,
              let expectedRoot = expectedWorktree.rootIdentity else {
            throw GitSafetyError.unsafeRepository(
                "default branch claim is missing, duplicated, or changed"
            )
        }
        let targetClaim = try handle.verifyWorktreeClaim(
            path: defaultRecord.path
        )
        let defaultClaims = [
            (record: defaultRecord, claim: targetClaim),
        ]
        guard defaultClaims.count == 1,
              let target = defaultClaims.first,
              target.claim.canonicalPath == expectedWorktree.path,
              target.claim.rootIdentity == expectedRoot else {
            throw GitSafetyError.unsafeRepository(
                "default branch claim is missing, duplicated, or changed"
            )
        }
        let cloneID = LocalClone.id(
            for: handle.candidate.commonDirectoryIdentity
                ?? RepositoryDirectoryIdentity(handle.identity.gitDirectory)
        )
        let claims = defaultClaims.map {
            "worktree:\(cloneID):\($0.claim.rootIdentity.device):\($0.claim.rootIdentity.inode)"
        }.sorted()
        let targetID =
            "worktree:\(cloneID):\(target.claim.rootIdentity.device):\(target.claim.rootIdentity.inode)"
        guard targetID == expectedWorktree.id else {
            throw GitSafetyError.unsafeRepository(
                "default branch target identity changed"
            )
        }

        let local = try requiredCommit(defaultBranch.localRef, run: run)
        let branchResult = try run(localArguments([
            "symbolic-ref", "--quiet", "--short", "HEAD",
        ]))
        guard branchResult.succeeded,
              !branchResult.stdoutTruncated,
              let branch = String(
                  data: branchResult.stdout,
                  encoding: .utf8
              )?.trimmingCharacters(in: .whitespacesAndNewlines),
              branch == defaultBranch.name else {
            throw GitSafetyError.detached
        }
        let status = try run(localArguments([
            "status", "--porcelain=v1", "-z", "--untracked-files=all",
        ]))
        guard status.succeeded, !status.stdoutTruncated else {
            throw GitSafetyError.commandFailed(
                "git status",
                status.status,
                status.diagnostic
            )
        }
        let index = try run(localArguments(["ls-files", "-v", "-z"]))
        guard index.succeeded, !index.stdoutTruncated else {
            throw GitSafetyError.commandFailed(
                "git ls-files",
                index.status,
                index.diagnostic
            )
        }
        let hidden: Bool
        do {
            try GitIndexVisibility.validate(index.stdout)
            hidden = false
        } catch GitSafetyError.hiddenIndex {
            hidden = true
        }
        return DefaultBranchTargetInspection(
            localOID: local,
            claimingWorktreeIDs: claims,
            targetWorktreeID: targetID,
            targetPath: target.claim.canonicalPath,
            clean: status.stdout.isEmpty,
            hiddenIndex: hidden
        )
    }
}
