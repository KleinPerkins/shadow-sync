import Foundation

/// The command half of discovery admission. This value grants no repository
/// access or process authority; those remain bound to the selected scope and
/// retained repository handle. Both callers and the custodian can validate the
/// same closed operation without inheriting the mutation runner's command set.
struct DiscoveryGitCommand: Sendable {
    static let stdoutLimit = 1_048_576
    static let stderrLimit = 262_144
    static let traceLimit = 262_144
    static let maximumWorkSeconds: TimeInterval = 15
    static let refusal = "Git command is outside the closed discovery command set"

    /// Only these external preflights can precede a discovery Git target. They
    /// must execute serially inside its custodian and consume its original timeline;
    /// this is not a route to spawn a nested custodian or arbitrary command.
    enum Preflight: CaseIterable {
        case systemConfiguration, policyClassification
        var kind: CustodyCommandKind {
            switch self {
            case .systemConfiguration: .systemGitConfig
            case .policyClassification: .policyClassify
            }
        }
        var workSeconds: TimeInterval {
            switch self {
            case .systemConfiguration: 5
            case .policyClassification: 2
            }
        }
    }

    private enum Operation: Sendable {
        case origin, worktrees, index, references, status, compatibilityStatus, branch
        case commit(String), ancestor(String, String)

        var arguments: [String] {
            switch self {
            case .origin: ["remote", "get-url", "--all", "origin"]
            case .worktrees: ["worktree", "list", "--porcelain", "-z"]
            case .index: ["ls-files", "-v", "-z"]
            case .references: ["for-each-ref",
                "--format=%(refname)%00%(objectname)%00%(objecttype)%00%(*objectname)%00%(*objecttype)%00",
                "refs/heads/main", "refs/remotes/origin/main"]
            case .status: ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"]
            case .compatibilityStatus: ["status", "--porcelain=v1", "-z", "--untracked-files=all"]
            case .branch: ["symbolic-ref", "--quiet", "--short", "HEAD"]
            case .commit(let reference): ["rev-parse", "--verify", reference + "^{commit}"]
            case .ancestor(let first, let second): ["merge-base", "--is-ancestor", first, second]
            }
        }
    }

    private let operation: Operation
    let workSeconds: TimeInterval
    var arguments: [String] { ["--no-replace-objects", "--no-lazy-fetch"] + operation.arguments }
    var capturesTransportConfiguration: Bool {
        if case .origin = operation { return true }
        return false
    }

    init(arguments: [String], captureTransportConfiguration: Bool,
         timeoutSeconds: TimeInterval = 5) throws {
        guard timeoutSeconds.isFinite, timeoutSeconds >= 0.1,
              timeoutSeconds <= Self.maximumWorkSeconds,
              arguments.count >= 3, arguments.count <= 8,
              arguments.allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count <= 4096 }),
              Array(arguments.prefix(2)) == ["--no-replace-objects", "--no-lazy-fetch"] else {
            throw GitSafetyError.unsafeRepository(Self.refusal)
        }
        let command = Array(arguments.dropFirst(2))
        let fixed: [Operation] = [.origin, .worktrees, .index, .references, .status, .compatibilityStatus, .branch]
        if let match = fixed.first(where: { $0.arguments == command }) {
            operation = match
        } else if command.count == 3, command[0] == "rev-parse", command[1] == "--verify",
                  command[2].hasSuffix("^{commit}") {
            let reference = String(command[2].dropLast("^{commit}".count))
            guard reference == "HEAD" || GitReferenceSyntax.isValidLocalBranchRef(reference)
                    || GitReferenceSyntax.isValidRemoteTrackingRef(reference) else {
                throw GitSafetyError.unsafeRepository(Self.refusal)
            }
            operation = .commit(reference)
        } else if command.count == 4, command[0] == "merge-base", command[1] == "--is-ancestor",
                  Self.isObjectID(command[2]), Self.isObjectID(command[3]), command[2].count == command[3].count {
            operation = .ancestor(command[2], command[3])
        } else {
            throw GitSafetyError.unsafeRepository(Self.refusal)
        }
        // Origin admission must retain the effective transport trace. Other
        // inspection operations cannot enable an additional diagnostic route.
        let needsTrace: Bool
        if case .origin = operation { needsTrace = true } else { needsTrace = false }
        guard captureTransportConfiguration == needsTrace else {
            throw GitSafetyError.unsafeRepository(Self.refusal)
        }
        workSeconds = timeoutSeconds
    }

    private static func isObjectID(_ value: String) -> Bool {
        (value.utf8.count == 40 || value.utf8.count == 64)
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    func environment(account: EffectiveAccount) -> [String: String] {
        var values = [
            "HOME": account.homeDirectory, "USER": account.username, "LOGNAME": account.username,
            "PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C",
            "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false",
            "GIT_OPTIONAL_LOCKS": "0", "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "include.path",
            "GIT_CONFIG_VALUE_0": "/dev/fd/197",
        ]
        if capturesTransportConfiguration {
            values["GIT_TRACE2_EVENT"] = String(discoveryTraceDescriptor)
            values["GIT_TRACE2_CONFIG_PARAMS"] = "remote.origin.uploadpack,core.sshcommand"
        }
        return values
    }
}
