import Foundation

/// The live selection phase admits each bounded, nonspawning metadata read.
/// No service or deadline escapes its callback, and a Git command never runs
/// inside this short metadata stage.
struct DiscoveryMetadataAccess: Sendable {
    enum Read {
        case identity, busy, topology, index, mainReference, remoteReference
        case looseCommit(String), primaryClaim(String)
    }
    let binder: SelectedRepositoryScopeBinder
    let scope: ValidatedSelectedRepositoryScope
    let cancellation: CancellationToken

    static func paths(candidate: RepositoryCandidate, read: Read) throws -> [String] {
        let root = candidate.path, git = root + "/.git"
        var paths = DiscoveryCustodyIntent.repositoryMetadataPaths(repositoryPath: root)
        let busy = ["index.lock", "HEAD.lock", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD",
                    "BISECT_LOG", "rebase-apply", "rebase-merge", "sequencer", "packed-refs.lock",
                    "config.lock", "shallow.lock", "refs/heads/main.lock", "refs/remotes/origin/main.lock"]
        switch read {
        case .identity: break
        case .busy: paths += busy.map { git + "/" + $0 }
        case .topology: paths.append(git + "/worktrees")
        case .index: paths.append(git + "/index")
        case .mainReference, .remoteReference:
            paths += busy.map { git + "/" + $0 }
            paths.append(git + (read.isMainReference ? "/refs/heads/main" : "/refs/remotes/origin/main"))
        case .looseCommit(let oid):
            guard [40, 64].contains(oid.utf8.count), oid.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }) else { throw SelectedRepositoryScopeError.changed }
            paths.append(git + "/objects/" + oid.prefix(2) + "/" + oid.dropFirst(2))
        case .primaryClaim(let path):
            // A decoded worktree-list path is not authority to access another
            // checkout. Linked resources require their separate admission.
            guard path.utf8.elementsEqual(root.utf8) else { throw SelectedRepositoryScopeError.changed }
        }
        return paths
    }

    func withRead<Value>(_ candidate: RepositoryCandidate, _ read: Read,
                         _ body: () throws -> Value) throws -> Value {
        let paths = try Self.paths(candidate: candidate, read: read)
        return try binder.withDiscoveryPolicy(scope, cancellation: cancellation) { service in
            guard candidate.isEligible, service.scope.admits(candidate),
                  candidate.policyAdmissionSHA256 == service.scope.policyDigest,
                  let selected = service.scope.repositories.first(where: {
                      $0.repositoryID == candidate.id && $0.repositoryPath.utf8.elementsEqual(candidate.path.utf8)
                  }) else { throw SelectedRepositoryScopeError.changed }
            try service.requireSelected(selected)
            try service.prepareAccess(paths)
            try service.validate()
            let result = try body()
            try service.requireSelected(selected)
            return result
        }
    }

    static func withHandle<Value>(_ access: Self?, _ handle: RepositoryHandle, _ read: Read,
                                  _ body: () throws -> Value) throws -> Value {
        guard let access else { return try body() }
        return try access.withRead(handle.candidate, read) {
            try handle.revalidate()
            let value = try body()
            try handle.revalidate()
            return value
        }
    }
}

private extension DiscoveryMetadataAccess.Read {
    var isMainReference: Bool { if case .mainReference = self { return true }; return false }
}
