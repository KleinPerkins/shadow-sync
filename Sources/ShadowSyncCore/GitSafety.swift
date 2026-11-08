import Darwin
import CryptoKit
import Foundation
import zlib

#if SHADOW_SYNC_TESTING
enum GitConfigurationValidationTesting {
    @TaskLocal static var forbidRawProbe = false
}
#endif

public enum GitTransport: String, Codable, Sendable {
    case ssh
    case https
}

public struct GitHubIdentity: Equatable, Codable, Sendable {
    public let owner: String
    public let repository: String
    public let transport: GitTransport

    public var canonicalName: String {
        "\(owner.lowercased())/\(repository.lowercased())"
    }

    public static func parse(_ value: String) -> GitHubIdentity? {
        guard !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
            return nil
        }
        let patterns: [(String, GitTransport)] = [
            (#"^git@github\.com:([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?$"#, .ssh),
            (#"^ssh://git@github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?$"#, .ssh),
            (#"^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$"#, .https),
        ]
        for (pattern, transport) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = expression.firstMatch(in: value, range: range),
                  match.range == range,
                  let ownerRange = Range(match.range(at: 1), in: value),
                  let repositoryRange = Range(match.range(at: 2), in: value) else {
                continue
            }
            let owner = String(value[ownerRange])
            let repository = String(value[repositoryRange])
            guard owner != ".", owner != "..", repository != ".", repository != ".." else {
                return nil
            }
            return GitHubIdentity(owner: owner, repository: repository, transport: transport)
        }
        return nil
    }
}

public enum GitSafetyError: Error, CustomStringConvertible {
    case repositoryRemoved
    case unsafeRepository(String)
    case malformedConfig(String)
    case originChanged
    case customTransport(String)
    case replacementOrGraft
    case busy
    case hiddenIndex
    case dirty
    case detached
    case primaryNotOnMain
    case mainInLinkedWorktree
    case localMainMissing
    case remoteMainMissing
    case unsupportedHookFramework
    case commandFailed(String, Int32, String)
    case cancelled

    public var description: String {
        switch self {
        case .repositoryRemoved:
            return "repository was removed"
        case let .unsafeRepository(reason):
            return "repository metadata is unsafe: \(reason)"
        case let .malformedConfig(reason):
            return "repository config is unsupported: \(reason)"
        case .originChanged:
            return "origin identity changed"
        case let .customTransport(name):
            return "custom Git transport is configured: \(name)"
        case .replacementOrGraft:
            return "replacement or graft metadata is present"
        case .busy:
            return "another Git operation is active"
        case .hiddenIndex:
            return "hidden index state is present"
        case .dirty:
            return "working copy has changes"
        case .detached:
            return "working copy is detached"
        case .primaryNotOnMain:
            return "primary working copy is not on main"
        case .mainInLinkedWorktree:
            return "main is checked out in a linked worktree"
        case .localMainMissing:
            return "local main is missing"
        case .remoteMainMissing:
            return "remote main is missing"
        case .unsupportedHookFramework:
            return "an unsupported hook framework appeared"
        case let .commandFailed(command, status, detail):
            return "\(command) failed (\(status)): \(detail)"
        case .cancelled:
            return "operation was cancelled"
        }
    }
}

enum RepositoryRootPathIdentity {
    struct OpenedDirectory {
        let descriptor: Int32
        let canonicalPath: String
        let identity: RepositoryDirectoryIdentity
    }

    static func matches(path: String, expected: FileIdentity) -> Bool {
        matches(
            path: path,
            expected: RepositoryDirectoryIdentity(expected)
        )
    }

    static func matches(
        path: String,
        expected: RepositoryDirectoryIdentity
    ) -> Bool {
        do {
            return try withVerifiedDirectory(
                path: path,
                expected: expected
            ) { _ in true }
        } catch {
            return false
        }
    }

    static func withVerifiedDirectory<Result>(
        path: String,
        expected: RepositoryDirectoryIdentity? = nil,
        _ body: (OpenedDirectory) throws -> Result
    ) throws -> Result {
        guard path.hasPrefix("/"),
              path.utf8.count <= 4_096,
              path.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw GitSafetyError.unsafeRepository(
                "worktree-list path is invalid"
            )
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count > 1,
              components[0].isEmpty,
              components.dropFirst().allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            throw GitSafetyError.unsafeRepository(
                "worktree-list path is invalid"
            )
        }

        var descriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw GitSafetyError.unsafeRepository(
                "filesystem root cannot be opened"
            )
        }
        defer { close(descriptor) }

        for componentValue in components.dropFirst() {
            let component = String(componentValue)
            var entryInfo = stat()
            guard fstatat(
                descriptor,
                component,
                &entryInfo,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw GitSafetyError.unsafeRepository(
                    "worktree-list path cannot be opened"
                )
            }
            let isAlias = (entryInfo.st_mode & S_IFMT) == S_IFLNK
            if isAlias {
                var parentInfo = stat()
                guard entryInfo.st_uid == 0,
                      fstat(descriptor, &parentInfo) == 0,
                      parentInfo.st_uid == 0,
                      (parentInfo.st_mode & 0o022) == 0 else {
                    throw GitSafetyError.unsafeRepository(
                        "worktree-list path contains an untrusted symlink"
                    )
                }
            }
            let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC
                | (isAlias ? 0 : O_NOFOLLOW)
            let next = component.withCString {
                openat(descriptor, $0, flags)
            }
            guard next >= 0 else {
                throw GitSafetyError.unsafeRepository(
                    "worktree-list path component cannot be opened"
                )
            }
            close(descriptor)
            descriptor = next
        }

        var finalInfo = stat()
        guard fstat(descriptor, &finalInfo) == 0,
              FileIdentity(finalInfo).isDirectory,
              finalInfo.st_uid == geteuid() else {
            throw GitSafetyError.unsafeRepository(
                "worktree-list directory owner or type is unsafe"
            )
        }
        let identity = RepositoryDirectoryIdentity(FileIdentity(finalInfo))
        if let expected, identity != expected {
            throw GitSafetyError.unsafeRepository(
                "worktree-list directory identity changed"
            )
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
            throw GitSafetyError.unsafeRepository(
                "worktree-list physical path is unavailable"
            )
        }
        guard let terminator = buffer.firstIndex(of: 0),
              let canonicalPath = String(
                  data: Data(buffer[..<terminator].map {
                      UInt8(bitPattern: $0)
                  }),
                  encoding: .utf8
              ),
              canonicalPath.hasPrefix("/"),
              canonicalPath.rangeOfCharacter(
                  from: .controlCharacters
              ) == nil else {
            throw GitSafetyError.unsafeRepository(
                "worktree-list physical path is invalid"
            )
        }
        return try body(OpenedDirectory(
            descriptor: descriptor,
            canonicalPath: canonicalPath,
            identity: identity
        ))
    }
}

enum EffectiveTransportConfiguration {
    static let queryArguments = [
        "config", "--null", "--name-only", "--get-regexp",
        #"^(remote\.origin\.uploadpack|core\.sshcommand)$"#,
    ]

    static func validate(
        status: Int32,
        output: Data,
        transport: GitTransport,
        operation: String,
        diagnostic: String = ""
    ) throws {
        if status == 1 {
            guard output.isEmpty else {
                throw GitSafetyError.malformedConfig(
                    "effective transport config absence probe returned output"
                )
            }
            return
        }
        guard status == 0 else {
            throw GitSafetyError.commandFailed(operation, status, diagnostic)
        }
        guard !output.isEmpty, output.last == 0 else {
            throw GitSafetyError.malformedConfig(
                "effective transport config output is malformed"
            )
        }
        let fields = output.split(separator: 0, omittingEmptySubsequences: true)
        guard !fields.isEmpty else {
            throw GitSafetyError.malformedConfig(
                "effective transport config output is empty"
            )
        }
        var names: Set<String> = []
        for field in fields {
            guard let name = String(data: field, encoding: .utf8) else {
                throw GitSafetyError.malformedConfig(
                    "effective transport config name is not UTF-8"
                )
            }
            let normalized = name.lowercased()
            guard normalized == "remote.origin.uploadpack"
                    || normalized == "core.sshcommand" else {
                throw GitSafetyError.malformedConfig(
                    "effective transport config output contains an unexpected key"
                )
            }
            names.insert(normalized)
        }
        if names.contains("remote.origin.uploadpack") {
            throw GitSafetyError.customTransport("remote.origin.uploadpack")
        }
        if transport == .ssh, names.contains("core.sshcommand") {
            throw GitSafetyError.customTransport("core.sshCommand")
        }
    }
}

enum RawGitConfigInspection: Equatable, Sendable {
    case valid(RawGitConfig)
    case unsupportedOrigin
    case unsupportedConfiguration
}

private enum RawGitConfigParseIssue: Error {
    case unsupportedOrigin
}

struct RawGitConfig: Equatable, Sendable {
    let originURL: String

    static func inspect(_ data: Data) -> RawGitConfigInspection {
        do {
            return .valid(try parseCore(data))
        } catch RawGitConfigParseIssue.unsupportedOrigin {
            return .unsupportedOrigin
        } catch {
            return .unsupportedConfiguration
        }
    }

    static func parse(_ data: Data) throws -> RawGitConfig {
        do {
            return try parseCore(data)
        } catch RawGitConfigParseIssue.unsupportedOrigin {
            throw GitSafetyError.malformedConfig(
                "origin must appear once with one approved URL"
            )
        }
    }

    private static func parseCore(_ data: Data) throws -> RawGitConfig {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
            throw GitSafetyError.malformedConfig("config is not bounded UTF-8")
        }
        var currentSection = ""
        var originSections = 0
        var originURLs: [String] = []
        var hasSSHCommand = false

        for rawLine in text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                continue
            }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else {
                    throw GitSafetyError.malformedConfig("unterminated section")
                }
                currentSection = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                if !currentSection.contains("\""), currentSection.contains(".") {
                    throw GitSafetyError.malformedConfig(
                        "deprecated dotted subsection syntax is unsupported"
                    )
                }
                if currentSection == "include" || currentSection.hasPrefix("includeif ") {
                    throw GitSafetyError.malformedConfig("config includes are deferred")
                }
                if currentSection == #"remote "origin""# {
                    originSections += 1
                }
                continue
            }
            guard let separator = line.firstIndex(of: "=") else {
                throw GitSafetyError.malformedConfig("key without value")
            }
            let key = String(line[..<separator])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            var value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if currentSection == #"remote "origin""#, key == "url" {
                originURLs.append(value)
            }
            if currentSection == #"remote "origin""#, key == "uploadpack" {
                throw GitSafetyError.malformedConfig("remote.origin.uploadpack is configured")
            }
            if currentSection == "core", key == "worktree" {
                throw GitSafetyError.malformedConfig("core.worktree is deferred")
            }
            if currentSection == "core", key == "sshcommand" {
                hasSSHCommand = true
            }
            if currentSection == "extensions", key == "worktreeconfig" {
                throw GitSafetyError.malformedConfig("extensions.worktreeConfig is unsupported in M1")
            }
        }
        guard originSections == 1, originURLs.count == 1,
              let origin = GitHubIdentity.parse(originURLs[0]) else {
            throw RawGitConfigParseIssue.unsupportedOrigin
        }
        if hasSSHCommand, origin.transport == .ssh {
            throw GitSafetyError.malformedConfig("core.sshCommand is configured")
        }
        return RawGitConfig(originURL: originURLs[0])
    }
}

private enum EffectiveHooksConfiguration {
    static func directory(
        global: Data,
        local: Data,
        worktreePath: String,
        commonDirectory: String,
        account: EffectiveAccount
    ) throws -> String {
        let localPath = try lastHooksPath(in: local)
        let globalPath = try lastHooksPath(in: global)
        let configured = localPath ?? globalPath
        guard let configured else {
            return commonDirectory + "/hooks"
        }
        let expanded: String
        if configured == "~" {
            expanded = account.homeDirectory
        } else if configured.hasPrefix("~/") {
            expanded =
                account.homeDirectory
                + String(configured.dropFirst())
        } else if configured.hasPrefix("~")
            || configured.hasPrefix("%(prefix)")
        {
            throw GitSafetyError.malformedConfig(
                "core.hooksPath uses an unsupported Git expansion"
            )
        } else if configured.hasPrefix("/") {
            expanded = configured
        } else {
            expanded = worktreePath + "/" + configured
        }
        let normalized = try lexicalAbsolutePath(expanded)
        guard normalized.hasPrefix("/"),
            normalized != account.homeDirectory,
            normalized.hasPrefix(
                account.homeDirectory + "/"
            ),
            !normalized.contains("\0"),
            !normalized.contains("\n"),
            !normalized.contains("\r")
        else {
            throw GitSafetyError.malformedConfig(
                "core.hooksPath is outside the supported account root"
            )
        }
        return normalized
    }

    private static func lexicalAbsolutePath(
        _ value: String
    ) throws -> String {
        guard value.hasPrefix("/") else {
            throw GitSafetyError.malformedConfig(
                "core.hooksPath is not absolute after resolution"
            )
        }
        var components: [Substring] = []
        for component in value.split(separator: "/") {
            if component == "." {
                continue
            }
            if component == ".." {
                guard !components.isEmpty else {
                    throw GitSafetyError.malformedConfig(
                        "core.hooksPath escapes the filesystem root"
                    )
                }
                components.removeLast()
            } else {
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    private static func lastHooksPath(
        in data: Data
    ) throws -> String? {
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitSafetyError.malformedConfig(
                "Git configuration is not UTF-8"
            )
        }
        var section = ""
        var result: String?
        for raw in text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ) {
            let line = String(raw)
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty
                || line.hasPrefix("#")
                || line.hasPrefix(";")
            {
                continue
            }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else {
                    throw GitSafetyError.malformedConfig(
                        "unterminated Git configuration section"
                    )
                }
                section = String(
                    line.dropFirst().dropLast()
                ).trimmingCharacters(
                    in: .whitespaces
                ).lowercased()
                continue
            }
            guard section == "core",
                let separator = line.firstIndex(of: "=")
            else {
                continue
            }
            let key = String(line[..<separator])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard key == "hookspath" else { continue }
            var value = String(
                line[line.index(after: separator)...]
            ).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"")
                || value.hasSuffix("\"")
            {
                guard value.count >= 2,
                    value.hasPrefix("\""),
                    value.hasSuffix("\"")
                else {
                    throw GitSafetyError.malformedConfig(
                        "core.hooksPath quoting is malformed"
                    )
                }
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty,
                !value.contains("\\"),
                !value.contains("\0"),
                !value.contains("\n"),
                !value.contains("\r"),
                !value.contains("#"),
                !value.contains(";")
            else {
                throw GitSafetyError.malformedConfig(
                    "core.hooksPath is unsupported"
                )
            }
            result = value
        }
        return result
    }
}

public struct RepositoryIdentity: Codable, Equatable, Sendable {
    public let root: FileIdentity
    public let worktreeMarker: FileIdentity
    public let worktreeMarkerSize: Int64?
    public let worktreeMarkerModifiedSeconds: Int64?
    public let worktreeMarkerModifiedNanoseconds: Int64?
    public let commonDirectoryPath: String
    public let gitDirectory: FileIdentity
    public let objectsDirectory: FileIdentity
    public let config: FileIdentity
    public let configSize: Int64
    public let configModifiedSeconds: Int64
    public let configModifiedNanoseconds: Int64
}

public struct GitFileDigest: Codable, Equatable, Sendable {
    public let path: String
    public let identity: FileIdentity
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let sha256: String
}

public struct GitPathDigest: Codable, Equatable, Sendable {
    public let path: String
    public let file: GitFileDigest?
}

public struct GitConfigurationSnapshot: Codable, Equatable, Sendable {
    public let contributors: [GitPathDigest]
    public let repositoryConfig: GitFileDigest
    public let frozenDirectoryPath: String
    public let frozenDirectoryIdentity: FileIdentity
    public let frozenPath: String
    public let frozenIdentity: FileIdentity
    public let frozenOwnerPID: Int32
    public let frozenSHA256: String
    public let frozenSize: Int
}

public struct GitAdmissionSnapshot: Codable, Equatable, Sendable {
    public let effectiveURL: String
    public let transport: GitTransport
    public let frozenConfigSHA256: String
    #if SHADOW_SYNC_TESTING
    public let mappedTestURL: String?
    #endif

    #if SHADOW_SYNC_TESTING
    public init(
        effectiveURL: String,
        transport: GitTransport,
        frozenConfigSHA256: String,
        mappedTestURL: String? = nil
    ) {
        self.effectiveURL = effectiveURL
        self.transport = transport
        self.frozenConfigSHA256 = frozenConfigSHA256
        self.mappedTestURL = mappedTestURL
    }
    #else
    public init(
        effectiveURL: String,
        transport: GitTransport,
        frozenConfigSHA256: String
    ) {
        self.effectiveURL = effectiveURL
        self.transport = transport
        self.frozenConfigSHA256 = frozenConfigSHA256
    }
    #endif
}

public struct PackedRefsSnapshot: Codable, Equatable, Sendable {
    public let path: GitPathDigest
    public let containsNoReplacementRefs: Bool
}

public struct RepositoryExecutionSnapshot: Codable, Equatable, Sendable {
    public let repository: RepositoryIdentity
    public let rootPath: String
    public let accountUID: UInt32
    public let accountUsername: String
    public let accountHome: String
    public let packedRefs: PackedRefsSnapshot
    public let configuration: GitConfigurationSnapshot
    public let admission: GitAdmissionSnapshot?
}

/// Captured bytes and integrity observations only. The helper's resource owner
/// must create, retain and explicitly retire its frozen file after policy
/// admission. Capturing does not create a scratch file or run stale cleanup.
struct CapturedGitConfiguration {
    let contributors: [GitPathDigest]
    let repositoryConfig: GitFileDigest
    let bytes: Data
    let effectiveHooksDirectory: String?

    fileprivate init(contributors: [GitPathDigest], repositoryConfig: GitFileDigest,
                     bytes: Data, effectiveHooksDirectory: String?) {
        self.contributors = contributors; self.repositoryConfig = repositoryConfig
        self.bytes = bytes; self.effectiveHooksDirectory = effectiveHooksDirectory
    }
    #if SHADOW_SYNC_TESTING
    /// Resource-owner fixtures exercise actual temporary files; these source
    /// observations are synthetic and do not authorize a repository operation.
    static func testingResourceBytes(_ bytes: Data) -> Self {
        var info = stat(); info.st_dev = 1; info.st_ino = 2
        info.st_uid = geteuid(); info.st_mode = S_IFREG | 0o600; info.st_nlink = 1
        let digest = GitFileDigest(path: "/fixture/unopened-config", identity: FileIdentity(info),
            size: Int64(bytes.count), modifiedSeconds: 0, modifiedNanoseconds: 0,
            sha256: CustodyRecordBinding.digest(bytes))
        return Self(contributors: [], repositoryConfig: digest, bytes: bytes, effectiveHooksDirectory: nil)
    }
    #endif
}

public final class FrozenGitConfiguration: @unchecked Sendable {
    private let ownedDescriptor: OwnedFileDescriptor
    private let ownedDirectoryDescriptor: OwnedFileDescriptor
    public let snapshot: GitConfigurationSnapshot
    let effectiveHooksDirectory: String?
    // In-memory evidence retained with these exact frozen resources. It is not
    // encoded into a trampoline request or reconstructed from contributor paths.
    fileprivate let retainedPreflight: GitConfigurationPreflight?
    fileprivate let retainedProbe: SystemGitConfigurationProbe?

    fileprivate init(
        descriptor: Int32,
        directoryDescriptor: Int32,
        snapshot: GitConfigurationSnapshot,
        effectiveHooksDirectory: String?,
        retainedPreflight: GitConfigurationPreflight? = nil,
        retainedProbe: SystemGitConfigurationProbe? = nil
    ) {
        ownedDescriptor = OwnedFileDescriptor(descriptor)
        ownedDirectoryDescriptor = OwnedFileDescriptor(directoryDescriptor)
        self.snapshot = snapshot
        self.effectiveHooksDirectory = effectiveHooksDirectory
        self.retainedPreflight = retainedPreflight
        self.retainedProbe = retainedProbe
    }

    public var descriptor: Int32 {
        ownedDescriptor.value
    }

    public var directoryDescriptor: Int32 {
        ownedDirectoryDescriptor.value
    }

    deinit {
        try? RepositoryHandle.cleanupFrozenConfiguration(
            descriptor: ownedDescriptor.value,
            directoryDescriptor: ownedDirectoryDescriptor.value,
            snapshot: snapshot
        )
    }
}

struct RepositoryWorktreeClaim: Equatable, Sendable {
    let canonicalPath: String
    let rootIdentity: RepositoryDirectoryIdentity
    let isPrimary: Bool
}

public final class CommonDirectoryOperationLock: @unchecked Sendable {
    private let descriptor: OwnedFileDescriptor
    private let parent: OwnedFileDescriptor
    private let root: OwnedFileDescriptor
    private let rootPath: String
    private let rootIdentity: FileIdentity
    private let directoryIdentities: [(name: String, identity: FileIdentity)]
    private let name: String
    private let identity: FileIdentity

    fileprivate init(
        descriptor: Int32,
        parent: Int32,
        root: Int32,
        rootPath: String,
        rootIdentity: FileIdentity,
        directoryIdentities:
            [(name: String, identity: FileIdentity)],
        name: String,
        identity: FileIdentity
    ) {
        self.descriptor = OwnedFileDescriptor(descriptor)
        self.parent = OwnedFileDescriptor(parent)
        self.root = OwnedFileDescriptor(root)
        self.rootPath = rootPath
        self.rootIdentity = rootIdentity
        self.directoryIdentities = directoryIdentities
        self.name = name
        self.identity = identity
    }

    public func revalidate() throws {
        var rootOpened = stat()
        var rootNamed = stat()
        guard fstat(root.value, &rootOpened) == 0,
            lstat(rootPath, &rootNamed) == 0,
            FileIdentity(rootOpened).matchesStableNode(rootIdentity),
            FileIdentity(rootNamed).matchesStableNode(rootIdentity)
        else {
            throw GitSafetyError.unsafeRepository(
                "common-directory lock root identity changed"
            )
        }
        var current = fcntl(
            root.value,
            F_DUPFD_CLOEXEC,
            0
        )
        guard current >= 0 else {
            throw SecureStateError.systemCall(
                "retain common-directory lock root",
                errno
            )
        }
        defer { Darwin.close(current) }
        for component in directoryIdentities {
            var named = stat()
            guard
                fstatat(
                    current,
                    component.name,
                    &named,
                    AT_SYMLINK_NOFOLLOW
                ) == 0,
                FileIdentity(named).matchesStableNode(
                    component.identity
                )
            else {
                throw GitSafetyError.unsafeRepository(
                    "common-directory lock parent identity changed"
                )
            }
            let child = openat(
                current,
                component.name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard child >= 0 else {
                throw GitSafetyError.unsafeRepository(
                    "common-directory lock parent is unavailable"
                )
            }
            var opened = stat()
            guard fstat(child, &opened) == 0,
                FileIdentity(opened).matchesStableNode(
                    component.identity
                )
            else {
                Darwin.close(child)
                throw GitSafetyError.unsafeRepository(
                    "common-directory lock parent identity changed"
                )
            }
            Darwin.close(current)
            current = child
        }
        var retainedParent = stat()
        var opened = stat()
        var named = stat()
        guard
            let lockDirectoryIdentity =
                directoryIdentities.last?.identity,
            fstat(parent.value, &retainedParent) == 0,
            FileIdentity(retainedParent)
                .matchesStableNode(lockDirectoryIdentity),
            fstat(descriptor.value, &opened) == 0,
            fstatat(
                parent.value,
                name,
                &named,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            FileIdentity(opened) == identity,
            FileIdentity(named) == identity
        else {
            throw GitSafetyError.unsafeRepository(
                "common-directory lock identity changed"
            )
        }
    }
}

public final class RepositoryHandle: @unchecked Sendable {
    private let rootDescriptor: OwnedFileDescriptor
    private let gitDescriptor: OwnedFileDescriptor
    private let linkedWorktreeGitDescriptor: OwnedFileDescriptor?
    public let candidate: RepositoryCandidate
    public let identity: RepositoryIdentity
    public let worktreePath: String
    public let rawOrigin: String
    public let githubIdentity: GitHubIdentity

    var worktreeDescriptor: Int32 { rootDescriptor.value }

    func duplicateIndexDirectoryDescriptor()
        throws -> Int32 {
        let source = linkedWorktreeGitDescriptor?.value
            ?? gitDescriptor.value
        let descriptor = fcntl(
            source,
            F_DUPFD_CLOEXEC,
            0
        )
        guard descriptor >= 0 else {
            throw SecureStateError.systemCall(
                "duplicate worktree index directory",
                errno
            )
        }
        return descriptor
    }

    func duplicateCommonDirectoryDescriptor()
        throws -> Int32 {
        let descriptor = fcntl(
            gitDescriptor.value,
            F_DUPFD_CLOEXEC,
            0
        )
        guard descriptor >= 0 else {
            throw SecureStateError.systemCall(
                "duplicate common Git directory",
                errno
            )
        }
        return descriptor
    }

    private init(
        candidate: RepositoryCandidate,
        rootDescriptor: Int32,
        gitDescriptor: Int32,
        linkedWorktreeGitDescriptor: Int32?,
        identity: RepositoryIdentity,
        worktreePath: String,
        rawOrigin: String,
        githubIdentity: GitHubIdentity
    ) {
        self.candidate = candidate
        self.rootDescriptor = OwnedFileDescriptor(rootDescriptor)
        self.gitDescriptor = OwnedFileDescriptor(gitDescriptor)
        self.linkedWorktreeGitDescriptor =
            linkedWorktreeGitDescriptor.map(OwnedFileDescriptor.init)
        self.identity = identity
        self.worktreePath = worktreePath
        self.rawOrigin = rawOrigin
        self.githubIdentity = githubIdentity
    }

    static func discoveryCandidate(
        path: String,
        presentationLocation: String? = nil
    ) throws -> RepositoryCandidate {
        guard path.hasPrefix("/"),
              !path.contains("\n"),
              !path.contains("\r"),
              !path.contains("\0") else {
            throw GitSafetyError.unsafeRepository("fixed M1 repository path is invalid")
        }
        let rootFD = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            if errno == ENOENT {
                throw GitSafetyError.repositoryRemoved
            }
            throw GitSafetyError.unsafeRepository("fixed M1 repository cannot be opened")
        }
        defer { close(rootFD) }
        var rootStat = stat()
        guard fstat(rootFD, &rootStat) == 0,
              FileIdentity(rootStat).isDirectory,
              rootStat.st_uid == geteuid() else {
            throw GitSafetyError.unsafeRepository("fixed M1 repository owner or type")
        }
        let canonicalPath = try descriptorPath(rootFD)
        let gitFD = openat(rootFD, ".git", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard gitFD >= 0 else {
            throw GitSafetyError.unsafeRepository("fixed M1 repository is not a primary checkout")
        }
        defer { close(gitFD) }
        var gitStat = stat()
        guard fstat(gitFD, &gitStat) == 0,
              FileIdentity(gitStat).isDirectory,
              gitStat.st_uid == geteuid() else {
            throw GitSafetyError.unsafeRepository("fixed M1 Git directory owner or type")
        }
        var rawOrigin = ""
        var originIdentity: GitHubIdentity?
        var configIdentity: RepositoryMetadataFileIdentity?
        var blockedReason: RepositoryBlockReason?
        for metadataPath in ["config.worktree", "commondir"] {
            var metadataInfo = stat()
            if fstatat(
                gitFD,
                metadataPath,
                &metadataInfo,
                AT_SYMLINK_NOFOLLOW
            ) == 0 || errno != ENOENT {
                blockedReason = .unsupportedGitConfiguration
                break
            }
        }
        let configFD = openat(
            gitFD,
            "config",
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if configFD >= 0 {
            defer { close(configFD) }
            var configInfo = stat()
            if fstat(configFD, &configInfo) == 0,
               FileIdentity(configInfo).isRegular,
               configInfo.st_uid == geteuid(),
               configInfo.st_nlink == 1,
               let data = try? readBounded(
                   fd: configFD,
                   maximumBytes: 1_048_576
               ) {
                configIdentity = RepositoryMetadataFileIdentity(configInfo)
                switch RawGitConfig.inspect(data) {
                case let .valid(config) where blockedReason == nil:
                    rawOrigin = config.originURL
                    originIdentity = GitHubIdentity.parse(config.originURL)
                case .valid:
                    break
                case .unsupportedOrigin:
                    blockedReason = blockedReason ?? .unsupportedOrigin
                case .unsupportedConfiguration:
                    blockedReason = .unsupportedGitConfiguration
                }
            } else {
                blockedReason = .unsupportedGitConfiguration
            }
        } else {
            blockedReason = .unsupportedGitConfiguration
        }
        let rootIdentity = RepositoryDirectoryIdentity(FileIdentity(rootStat))
        let gitIdentity = RepositoryDirectoryIdentity(FileIdentity(gitStat))
        let candidateID = originIdentity?.canonicalName
            ?? "local:\(rootIdentity.device):\(rootIdentity.inode)"
        return RepositoryCandidate(
            id: candidateID,
            displayName: URL(fileURLWithPath: canonicalPath).lastPathComponent,
            path: canonicalPath,
            rawOrigin: rawOrigin,
            presentationLocation: presentationLocation,
            rootIdentity: rootIdentity,
            gitDirectoryIdentity: gitIdentity,
            commonDirectoryIdentity: gitIdentity,
            configIdentity: configIdentity,
            blockedReason: blockedReason
        )
    }

    public static func fixedCandidate(path: String) throws -> RepositoryCandidate {
        let candidate = try discoveryCandidate(path: path)
        switch candidate.blockedReason {
        case .unsupportedOrigin:
            throw GitSafetyError.malformedConfig(
                "fixed M1 origin is not approved"
            )
        case .unsupportedGitConfiguration:
            throw GitSafetyError.malformedConfig(
                "fixed M1 config cannot be verified"
            )
        case .none:
            guard candidate.isEligible else {
                throw GitSafetyError.unsafeRepository(
                    "fixed M1 repository identity is invalid"
                )
            }
            return candidate
        default:
            throw GitSafetyError.unsafeRepository(
                "fixed M1 repository is blocked"
            )
        }
    }

    #if SHADOW_SYNC_TESTING
    public static func testingBoundCandidate(
        path: String,
        id: String,
        displayName: String,
        rawOrigin: String,
        presentationLocation: String? = nil
    ) throws -> RepositoryCandidate {
        let rootFD = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            throw GitSafetyError.unsafeRepository("testing repository cannot be opened")
        }
        defer { close(rootFD) }
        var rootStat = stat()
        guard fstat(rootFD, &rootStat) == 0,
              FileIdentity(rootStat).isDirectory,
              rootStat.st_uid == geteuid() else {
            throw GitSafetyError.unsafeRepository("testing repository owner or type")
        }
        let gitFD = openat(rootFD, ".git", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard gitFD >= 0 else {
            throw GitSafetyError.unsafeRepository("testing Git directory cannot be opened")
        }
        defer { close(gitFD) }
        var gitStat = stat()
        guard fstat(gitFD, &gitStat) == 0,
              FileIdentity(gitStat).isDirectory,
              gitStat.st_uid == geteuid() else {
            throw GitSafetyError.unsafeRepository("testing Git directory owner or type")
        }
        let configFD = openat(
            gitFD,
            "config",
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard configFD >= 0 else {
            throw GitSafetyError.unsafeRepository(
                "testing Git config cannot be opened"
            )
        }
        defer { close(configFD) }
        var configInfo = stat()
        guard fstat(configFD, &configInfo) == 0,
              FileIdentity(configInfo).isRegular,
              configInfo.st_uid == geteuid(),
              configInfo.st_nlink == 1 else {
            throw GitSafetyError.unsafeRepository(
                "testing Git config owner or type"
            )
        }
        return RepositoryCandidate(
            id: id,
            displayName: displayName,
            path: try descriptorPath(rootFD),
            rawOrigin: rawOrigin,
            presentationLocation: presentationLocation,
            rootIdentity: RepositoryDirectoryIdentity(FileIdentity(rootStat)),
            gitDirectoryIdentity: RepositoryDirectoryIdentity(FileIdentity(gitStat)),
            commonDirectoryIdentity: RepositoryDirectoryIdentity(FileIdentity(gitStat)),
            configIdentity: RepositoryMetadataFileIdentity(configInfo)
        )
    }
    #endif

    public static func open(_ candidate: RepositoryCandidate) throws -> RepositoryHandle {
        guard candidate.path.hasPrefix("/"),
              !candidate.path.contains("\n"),
              !candidate.path.contains("\r"),
              !candidate.path.contains("\0"),
              let expectedRoot = candidate.rootIdentity,
              let expectedGit = candidate.gitDirectoryIdentity,
              let expectedCommon = candidate.commonDirectoryIdentity else {
            throw GitSafetyError.unsafeRepository("worktree request lacks bound identity")
        }
        let rootFD = Darwin.open(candidate.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            if errno == ENOENT {
                throw GitSafetyError.repositoryRemoved
            }
            throw GitSafetyError.unsafeRepository("worktree open failed")
        }
        do {
            var rootStat = stat()
            guard fstat(rootFD, &rootStat) == 0,
                  FileIdentity(rootStat).isDirectory,
                  rootStat.st_uid == geteuid(),
                  RepositoryDirectoryIdentity(FileIdentity(rootStat)) == expectedRoot,
                  try descriptorPath(rootFD) == candidate.path else {
                throw GitSafetyError.unsafeRepository("worktree owner or type")
            }
            let gitFD = openat(rootFD, ".git", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard gitFD >= 0 else {
                throw GitSafetyError.unsafeRepository("M1 requires a primary .git directory")
            }
            do {
                var gitStat = stat()
                guard fstat(gitFD, &gitStat) == 0,
                      FileIdentity(gitStat).isDirectory,
                      gitStat.st_uid == geteuid(),
                      RepositoryDirectoryIdentity(FileIdentity(gitStat)) == expectedGit,
                      RepositoryDirectoryIdentity(FileIdentity(gitStat)) == expectedCommon else {
                    throw GitSafetyError.unsafeRepository("Git directory owner or type")
                }
                try requireAbsent(relativePath: "config.worktree", directory: gitFD)
                try requireAbsent(relativePath: "commondir", directory: gitFD)
                let configFD = openat(gitFD, "config", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard configFD >= 0 else {
                    throw GitSafetyError.malformedConfig("config cannot be opened")
                }
                defer { close(configFD) }
                var configStat = stat()
                guard fstat(configFD, &configStat) == 0,
                      FileIdentity(configStat).isRegular,
                      configStat.st_uid == geteuid(),
                      configStat.st_nlink == 1,
                      candidate.configIdentity == nil
                        || RepositoryMetadataFileIdentity(configStat)
                            == candidate.configIdentity else {
                    throw GitSafetyError.unsafeRepository("config owner, type, or links")
                }
                let configData = try readBounded(fd: configFD, maximumBytes: 1_048_576)
                let config = try RawGitConfig.parse(configData)
                guard let identity = GitHubIdentity.parse(config.originURL),
                      let selectedIdentity = GitHubIdentity.parse(candidate.rawOrigin),
                      candidate.originIdentity == selectedIdentity,
                      candidate.id.lowercased() == selectedIdentity.canonicalName,
                      config.originURL == candidate.rawOrigin,
                      identity.canonicalName == selectedIdentity.canonicalName else {
                    throw GitSafetyError.originChanged
                }
                let objectsFD = openat(
                    gitFD,
                    "objects",
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard objectsFD >= 0 else {
                    throw GitSafetyError.unsafeRepository("objects directory is unavailable")
                }
                var objectsStat = stat()
                let objectsSafe = fstat(objectsFD, &objectsStat) == 0
                    && FileIdentity(objectsStat).isDirectory
                    && objectsStat.st_uid == geteuid()
                close(objectsFD)
                guard objectsSafe else {
                    throw GitSafetyError.unsafeRepository("objects directory owner or type")
                }
                let captured = RepositoryIdentity(
                    root: FileIdentity(rootStat),
                    worktreeMarker: FileIdentity(gitStat),
                    worktreeMarkerSize: nil,
                    worktreeMarkerModifiedSeconds: nil,
                    worktreeMarkerModifiedNanoseconds: nil,
                    commonDirectoryPath: candidate.path + "/.git",
                    gitDirectory: FileIdentity(gitStat),
                    objectsDirectory: FileIdentity(objectsStat),
                    config: FileIdentity(configStat),
                    configSize: Int64(configStat.st_size),
                    configModifiedSeconds: Int64(configStat.st_mtimespec.tv_sec),
                    configModifiedNanoseconds: Int64(configStat.st_mtimespec.tv_nsec)
                )
                return RepositoryHandle(
                    candidate: candidate,
                    rootDescriptor: rootFD,
                    gitDescriptor: gitFD,
                    linkedWorktreeGitDescriptor: nil,
                    identity: captured,
                    worktreePath: candidate.path,
                    rawOrigin: config.originURL,
                    githubIdentity: identity
                )
            } catch {
                close(gitFD)
                throw error
            }
        } catch {
            close(rootFD)
            throw error
        }
    }

    public static func open(
        _ candidate: RepositoryCandidate,
        targetWorktree: Worktree
    ) throws -> RepositoryHandle {
        let primary = try open(candidate)
        guard targetWorktree.cloneID == LocalClone.id(
            for: candidate.commonDirectoryIdentity
                ?? RepositoryDirectoryIdentity(primary.identity.gitDirectory)
        ), let expectedRoot = targetWorktree.rootIdentity,
              targetWorktree.verification == .verified else {
            throw GitSafetyError.unsafeRepository(
                "target worktree lacks verified clone identity"
            )
        }
        let claim = try primary.verifyWorktreeClaim(
            path: targetWorktree.path
        )
        guard claim.rootIdentity == expectedRoot,
              claim.canonicalPath == targetWorktree.path else {
            throw GitSafetyError.unsafeRepository(
                "target worktree identity changed"
            )
        }
        if claim.isPrimary {
            return primary
        }

        return try RepositoryRootPathIdentity.withVerifiedDirectory(
            path: targetWorktree.path,
            expected: expectedRoot
        ) { opened in
            guard let linked = candidate.linkedWorktrees.first(where: {
                $0.rootIdentity == expectedRoot
                    && $0.path == opened.canonicalPath
            }) else {
                throw GitSafetyError.unsafeRepository(
                    "linked target worktree registration is unavailable"
                )
            }
            let marker = try primary.readWorktreeMetadata(
                ".git",
                directory: opened.descriptor,
                expected: linked.markerIdentity,
                maximumBytes: 16_384
            )
            let markerLine = try Self.worktreeMetadataLine(
                marker,
                description: "linked target worktree marker"
            )
            guard markerLine.hasPrefix("gitdir: ") else {
                throw GitSafetyError.unsafeRepository(
                    "linked target worktree marker is malformed"
                )
            }
            let registrationPath = try Self.resolveWorktreeMetadataPath(
                String(markerLine.dropFirst("gitdir: ".count)),
                relativeTo: opened.canonicalPath
            )
            let registrationDescriptor =
                try RepositoryRootPathIdentity.withVerifiedDirectory(
                    path: registrationPath,
                    expected: linked.registrationDirectoryIdentity
                ) { registration in
                    let retained = fcntl(
                        registration.descriptor,
                        F_DUPFD_CLOEXEC,
                        0
                    )
                    guard retained >= 0 else {
                        throw SecureStateError.systemCall(
                            "retain linked target registration",
                            errno
                        )
                    }
                    return retained
                }
            let rootDescriptor = fcntl(
                opened.descriptor,
                F_DUPFD_CLOEXEC,
                0
            )
            let gitDescriptor = fcntl(
                primary.gitDescriptor.value,
                F_DUPFD_CLOEXEC,
                0
            )
            guard rootDescriptor >= 0, gitDescriptor >= 0 else {
                if rootDescriptor >= 0 { close(rootDescriptor) }
                if gitDescriptor >= 0 { close(gitDescriptor) }
                close(registrationDescriptor)
                throw SecureStateError.systemCall(
                    "retain linked target descriptors",
                    errno
                )
            }
            var rootInfo = stat()
            guard fstat(rootDescriptor, &rootInfo) == 0 else {
                close(rootDescriptor)
                close(gitDescriptor)
                close(registrationDescriptor)
                throw SecureStateError.systemCall(
                    "stat linked target root",
                    errno
                )
            }
            let linkedIdentity = RepositoryIdentity(
                root: FileIdentity(rootInfo),
                worktreeMarker: linked.markerIdentity.identity,
                worktreeMarkerSize: linked.markerIdentity.size,
                worktreeMarkerModifiedSeconds:
                    linked.markerIdentity.modifiedSeconds,
                worktreeMarkerModifiedNanoseconds:
                    linked.markerIdentity.modifiedNanoseconds,
                commonDirectoryPath: primary.identity.commonDirectoryPath,
                gitDirectory: primary.identity.gitDirectory,
                objectsDirectory: primary.identity.objectsDirectory,
                config: primary.identity.config,
                configSize: primary.identity.configSize,
                configModifiedSeconds:
                    primary.identity.configModifiedSeconds,
                configModifiedNanoseconds:
                    primary.identity.configModifiedNanoseconds
            )
            return RepositoryHandle(
                candidate: candidate,
                rootDescriptor: rootDescriptor,
                gitDescriptor: gitDescriptor,
                linkedWorktreeGitDescriptor: registrationDescriptor,
                identity: linkedIdentity,
                worktreePath: opened.canonicalPath,
                rawOrigin: primary.rawOrigin,
                githubIdentity: primary.githubIdentity
            )
        }
    }

    static func openOperationWorktree(
        _ clone: LocalClone,
        targetWorktree: Worktree
    ) throws -> RepositoryHandle {
        let candidate = clone.sourceSnapshot
        guard candidate.path == clone.primaryRoot,
              candidate.rootIdentity == clone.rootIdentity,
              candidate.commonDirectoryIdentity
                == clone.commonDirectoryIdentity,
              clone.id == LocalClone.id(
                  for: clone.commonDirectoryIdentity
              ),
              targetWorktree.cloneID == clone.id,
              clone.worktrees.contains(targetWorktree),
              targetWorktree.verification == .verified,
              targetWorktree.rootIdentity != nil else {
            throw GitSafetyError.unsafeRepository(
                "operation worktree lacks immutable clone evidence"
            )
        }
        let primary = try open(candidate)
        if targetWorktree.isPrimary {
            guard targetWorktree.path == clone.primaryRoot,
                  targetWorktree.rootIdentity == clone.rootIdentity,
                  targetWorktree.registrationIdentity == nil else {
                throw GitSafetyError.unsafeRepository(
                    "operation primary worktree identity changed"
                )
            }
            return primary
        }

        let linked = try primary.freshOperationLinkedWorktree(
            targetWorktree
        )
        let rebound = RepositoryCandidate(
            id: candidate.id,
            displayName: candidate.displayName,
            path: candidate.path,
            rawOrigin: candidate.rawOrigin,
            presentationLocation:
                candidate.presentationLocation,
            rootIdentity: candidate.rootIdentity,
            gitDirectoryIdentity:
                candidate.gitDirectoryIdentity,
            commonDirectoryIdentity:
                candidate.commonDirectoryIdentity,
            configIdentity: candidate.configIdentity,
            policyAdmissionSHA256:
                candidate.policyAdmissionSHA256,
            hookAdmissionSHA256:
                candidate.hookAdmissionSHA256,
            linkedWorktreePaths: [linked.path],
            linkedWorktrees: [linked],
            cachedMainRelation:
                candidate.cachedMainRelation,
            blockedReason: candidate.blockedReason
        )
        return try open(
            rebound,
            targetWorktree: targetWorktree
        )
    }

    public static func openMovedWorktree(
        _ candidate: RepositoryCandidate,
        evidence: MovedWorktreeEvidence
    ) throws -> RepositoryHandle {
        let primary = try open(candidate)
        let registrationPath = URL(
            fileURLWithPath:
                primary.identity.commonDirectoryPath
        ).appendingPathComponent(
            "worktrees/\(evidence.registrationID)"
        ).path
        return try RepositoryRootPathIdentity.withVerifiedDirectory(
            path: evidence.verifiedPath,
            expected: evidence.rootIdentity
        ) { opened in
            let marker = try primary.readWorktreeMetadata(
                ".git",
                directory: opened.descriptor,
                expected: evidence.markerIdentity,
                maximumBytes: 16_384
            )
            let markerLine = try worktreeMetadataLine(
                marker,
                description: "moved worktree marker"
            )
            guard markerLine.hasPrefix("gitdir: "),
                  try resolveWorktreeMetadataPath(
                      String(markerLine.dropFirst("gitdir: ".count)),
                      relativeTo: opened.canonicalPath
                  ) == registrationPath else {
                throw GitSafetyError.unsafeRepository(
                    "moved worktree marker changed"
                )
            }
            let registrationDescriptor =
                try RepositoryRootPathIdentity.withVerifiedDirectory(
                    path: registrationPath,
                    expected: evidence.registrationIdentity
                ) { registration -> Int32 in
                    let gitdir = try primary.readWorktreeMetadata(
                        "gitdir",
                        directory: registration.descriptor,
                        expected: evidence.gitdirIdentity,
                        maximumBytes: 16_384
                    )
                    let head = try primary.readWorktreeMetadata(
                        "HEAD",
                        directory: registration.descriptor,
                        expected: evidence.headIdentity,
                        maximumBytes: 16_384
                    )
                    let commondir = try primary.readWorktreeMetadata(
                        "commondir",
                        directory: registration.descriptor,
                        expected: evidence.commondirIdentity,
                        maximumBytes: 16_384
                    )
                    let gitdirLine = try worktreeMetadataLine(
                        gitdir,
                        description: "moved registration gitdir"
                    )
                    let headLine = try worktreeMetadataLine(
                        head,
                        description: "moved registration HEAD"
                    )
                    let commondirLine = try worktreeMetadataLine(
                        commondir,
                        description: "moved registration commondir"
                    )
                    guard gitdirLine
                            == "\(evidence.previousPath)/.git",
                          headLine
                            == "ref: \(evidence.branchRef)",
                          try resolveWorktreeMetadataPath(
                              commondirLine,
                              relativeTo: registrationPath
                          ) == primary.identity
                            .commonDirectoryPath else {
                        throw GitSafetyError.unsafeRepository(
                            "moved worktree metadata changed"
                        )
                    }
                    let retained = fcntl(
                        registration.descriptor,
                        F_DUPFD_CLOEXEC,
                        0
                    )
                    guard retained >= 0 else {
                        throw SecureStateError.systemCall(
                            "retain moved registration",
                            errno
                        )
                    }
                    return retained
                }
            let rootDescriptor = fcntl(
                opened.descriptor,
                F_DUPFD_CLOEXEC,
                0
            )
            let gitDescriptor = fcntl(
                primary.gitDescriptor.value,
                F_DUPFD_CLOEXEC,
                0
            )
            guard rootDescriptor >= 0, gitDescriptor >= 0 else {
                if rootDescriptor >= 0 { close(rootDescriptor) }
                if gitDescriptor >= 0 { close(gitDescriptor) }
                close(registrationDescriptor)
                throw SecureStateError.systemCall(
                    "retain moved worktree descriptors",
                    errno
                )
            }
            var rootInfo = stat()
            guard fstat(rootDescriptor, &rootInfo) == 0 else {
                close(rootDescriptor)
                close(gitDescriptor)
                close(registrationDescriptor)
                throw SecureStateError.systemCall(
                    "stat moved worktree",
                    errno
                )
            }
            let identity = RepositoryIdentity(
                root: FileIdentity(rootInfo),
                worktreeMarker:
                    evidence.markerIdentity.identity,
                worktreeMarkerSize:
                    evidence.markerIdentity.size,
                worktreeMarkerModifiedSeconds:
                    evidence.markerIdentity.modifiedSeconds,
                worktreeMarkerModifiedNanoseconds:
                    evidence.markerIdentity.modifiedNanoseconds,
                commonDirectoryPath:
                    primary.identity.commonDirectoryPath,
                gitDirectory:
                    primary.identity.gitDirectory,
                objectsDirectory:
                    primary.identity.objectsDirectory,
                config: primary.identity.config,
                configSize: primary.identity.configSize,
                configModifiedSeconds:
                    primary.identity.configModifiedSeconds,
                configModifiedNanoseconds:
                    primary.identity.configModifiedNanoseconds
            )
            return RepositoryHandle(
                candidate: candidate,
                rootDescriptor: rootDescriptor,
                gitDescriptor: gitDescriptor,
                linkedWorktreeGitDescriptor:
                    registrationDescriptor,
                identity: identity,
                worktreePath: opened.canonicalPath,
                rawOrigin: primary.rawOrigin,
                githubIdentity: primary.githubIdentity
            )
        }
    }

    public func revalidate() throws {
        var rootStat = stat()
        var pathStat = stat()
        guard lstat(worktreePath, &pathStat) == 0,
              fstat(rootDescriptor.value, &rootStat) == 0,
              FileIdentity(rootStat).matchesStableNode(identity.root),
              FileIdentity(pathStat).matchesStableNode(identity.root) else {
            throw GitSafetyError.unsafeRepository("worktree identity changed")
        }
        var gitStat = stat()
        guard fstatat(rootDescriptor.value, ".git", &gitStat, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity(gitStat).matchesStableNode(
                  identity.worktreeMarker
              ),
              identity.worktreeMarkerSize == nil
                || (
                    Int64(gitStat.st_size)
                        == identity.worktreeMarkerSize
                        && Int64(gitStat.st_mtimespec.tv_sec)
                            == identity.worktreeMarkerModifiedSeconds
                        && Int64(gitStat.st_mtimespec.tv_nsec)
                            == identity.worktreeMarkerModifiedNanoseconds
                ) else {
            throw GitSafetyError.unsafeRepository("Git directory identity changed")
        }
        try Self.requireAbsent(relativePath: "config.worktree", directory: gitDescriptor.value)
        try Self.requireAbsent(relativePath: "commondir", directory: gitDescriptor.value)
        var configStat = stat()
        guard fstatat(gitDescriptor.value, "config", &configStat, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity(configStat) == identity.config,
              Int64(configStat.st_size) == identity.configSize,
              Int64(configStat.st_mtimespec.tv_sec) == identity.configModifiedSeconds,
              Int64(configStat.st_mtimespec.tv_nsec) == identity.configModifiedNanoseconds else {
            throw GitSafetyError.unsafeRepository("Git config identity changed")
        }
        var objectsStat = stat()
        guard fstatat(
            gitDescriptor.value,
            "objects",
            &objectsStat,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              FileIdentity(objectsStat).matchesStableNode(identity.objectsDirectory) else {
            throw GitSafetyError.unsafeRepository("Git objects directory identity changed")
        }
    }

    func verifyWorktreeClaim(
        path: String
    ) throws -> RepositoryWorktreeClaim {
        try revalidate()
        let claim = try RepositoryRootPathIdentity.withVerifiedDirectory(
            path: path
        ) { opened -> RepositoryWorktreeClaim in
            if opened.identity == candidate.rootIdentity {
                guard opened.canonicalPath == candidate.path else {
                    throw GitSafetyError.unsafeRepository(
                        "primary worktree physical path changed"
                    )
                }
                let git = openat(
                    opened.descriptor,
                    ".git",
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard git >= 0 else {
                    throw GitSafetyError.unsafeRepository(
                        "primary worktree common directory is unavailable"
                    )
                }
                defer { close(git) }
                var gitInfo = stat()
                guard fstat(git, &gitInfo) == 0,
                      FileIdentity(gitInfo).isDirectory,
                      gitInfo.st_uid == geteuid(),
                      RepositoryDirectoryIdentity(FileIdentity(gitInfo))
                        == candidate.gitDirectoryIdentity,
                      RepositoryDirectoryIdentity(FileIdentity(gitInfo))
                        == candidate.commonDirectoryIdentity else {
                    throw GitSafetyError.unsafeRepository(
                        "primary worktree common directory changed"
                    )
                }
                return RepositoryWorktreeClaim(
                    canonicalPath: opened.canonicalPath,
                    rootIdentity: opened.identity,
                    isPrimary: true
                )
            }

            if let linked = candidate.linkedWorktrees.first(where: {
                $0.rootIdentity == opened.identity
            }) {
                guard linked.path == opened.canonicalPath else {
                    throw GitSafetyError.unsafeRepository(
                        "registered worktree physical path changed"
                    )
                }
                try verifyLinkedWorktreeClaim(
                    linked,
                    opened: opened
                )
            } else {
                guard candidate.linkedWorktrees.isEmpty else {
                    throw GitSafetyError.unsafeRepository(
                        "worktree-list path is not a registered worktree"
                    )
                }
                try verifyDynamicallyLinkedWorktreeClaim(opened: opened)
            }
            return RepositoryWorktreeClaim(
                canonicalPath: opened.canonicalPath,
                rootIdentity: opened.identity,
                isPrimary: false
            )
        }
        try revalidate()
        return claim
    }

    private func verifyDynamicallyLinkedWorktreeClaim(
        opened: RepositoryRootPathIdentity.OpenedDirectory
    ) throws {
        let marker = try readWorktreeMetadata(
            ".git",
            directory: opened.descriptor,
            expected: nil,
            maximumBytes: 16_384
        )
        let markerLine = try Self.worktreeMetadataLine(
            marker,
            description: "linked worktree marker"
        )
        guard markerLine.hasPrefix("gitdir: ") else {
            throw GitSafetyError.unsafeRepository(
                "linked worktree marker is malformed"
            )
        }
        let registrationPath = try Self.resolveWorktreeMetadataPath(
            String(markerLine.dropFirst("gitdir: ".count)),
            relativeTo: opened.canonicalPath
        )
        try RepositoryRootPathIdentity.withVerifiedDirectory(
            path: registrationPath
        ) { registration in
            var worktreeConfig = stat()
            guard fstatat(
                registration.descriptor,
                "config.worktree",
                &worktreeConfig,
                AT_SYMLINK_NOFOLLOW
            ) != 0, errno == ENOENT else {
                throw GitSafetyError.unsafeRepository(
                    "linked worktree configuration changed"
                )
            }

            let gitdir = try readWorktreeMetadata(
                "gitdir",
                directory: registration.descriptor,
                expected: nil,
                maximumBytes: 16_384
            )
            let gitdirPath = try Self.resolveWorktreeMetadataPath(
                try Self.worktreeMetadataLine(
                    gitdir,
                    description: "registered worktree path"
                ),
                relativeTo: registration.canonicalPath
            )
            guard gitdirPath == opened.canonicalPath + "/.git" else {
                throw GitSafetyError.unsafeRepository(
                    "linked worktree backlink changed"
                )
            }

            let common = try readWorktreeMetadata(
                "commondir",
                directory: registration.descriptor,
                expected: nil,
                maximumBytes: 4_096
            )
            let commonPath = try Self.resolveWorktreeMetadataPath(
                try Self.worktreeMetadataLine(
                    common,
                    description: "linked common directory"
                ),
                relativeTo: registration.canonicalPath
            )
            try RepositoryRootPathIdentity.withVerifiedDirectory(
                path: commonPath,
                expected: candidate.commonDirectoryIdentity
            ) { commonDirectory in
                guard commonDirectory.canonicalPath
                        == candidate.path + "/.git" else {
                    throw GitSafetyError.unsafeRepository(
                        "linked worktree common directory changed"
                    )
                }
            }

            let head = try readWorktreeMetadata(
                "HEAD",
                directory: registration.descriptor,
                expected: nil,
                maximumBytes: 4_096
            )
            let headValue = try Self.worktreeMetadataLine(
                head,
                description: "linked worktree HEAD"
            )
            guard Self.validWorktreeHead(headValue) else {
                throw GitSafetyError.unsafeRepository(
                    "linked worktree HEAD is malformed"
                )
            }
        }
    }

    private func verifyLinkedWorktreeClaim(
        _ linked: RepositoryLinkedWorktree,
        opened: RepositoryRootPathIdentity.OpenedDirectory
    ) throws {
        let marker = try readWorktreeMetadata(
            ".git",
            directory: opened.descriptor,
            expected: linked.markerIdentity,
            maximumBytes: 16_384
        )
        let markerLine = try Self.worktreeMetadataLine(
            marker,
            description: "linked worktree marker"
        )
        guard markerLine.hasPrefix("gitdir: ") else {
            throw GitSafetyError.unsafeRepository(
                "linked worktree marker is malformed"
            )
        }
        let registrationPath = try Self.resolveWorktreeMetadataPath(
            String(markerLine.dropFirst("gitdir: ".count)),
            relativeTo: opened.canonicalPath
        )
        try RepositoryRootPathIdentity.withVerifiedDirectory(
            path: registrationPath,
            expected: linked.registrationDirectoryIdentity
        ) { registration in
            var worktreeConfig = stat()
            guard fstatat(
                registration.descriptor,
                "config.worktree",
                &worktreeConfig,
                AT_SYMLINK_NOFOLLOW
            ) != 0, errno == ENOENT else {
                throw GitSafetyError.unsafeRepository(
                    "linked worktree configuration changed"
                )
            }

            let gitdir = try readWorktreeMetadata(
                "gitdir",
                directory: registration.descriptor,
                expected: linked.registrationGitdirIdentity,
                maximumBytes: 16_384
            )
            let gitdirPath = try Self.resolveWorktreeMetadataPath(
                try Self.worktreeMetadataLine(
                    gitdir,
                    description: "registered worktree path"
                ),
                relativeTo: registration.canonicalPath
            )
            guard gitdirPath == opened.canonicalPath + "/.git" else {
                throw GitSafetyError.unsafeRepository(
                    "linked worktree backlink changed"
                )
            }

            let common = try readWorktreeMetadata(
                "commondir",
                directory: registration.descriptor,
                expected: linked.commonDirectoryMarkerIdentity,
                maximumBytes: 4_096
            )
            let commonPath = try Self.resolveWorktreeMetadataPath(
                try Self.worktreeMetadataLine(
                    common,
                    description: "linked common directory"
                ),
                relativeTo: registration.canonicalPath
            )
            try RepositoryRootPathIdentity.withVerifiedDirectory(
                path: commonPath,
                expected: candidate.commonDirectoryIdentity
            ) { commonDirectory in
                guard commonDirectory.canonicalPath
                        == candidate.path + "/.git" else {
                    throw GitSafetyError.unsafeRepository(
                        "linked worktree common directory changed"
                    )
                }
            }

            let head = try readWorktreeMetadata(
                "HEAD",
                directory: registration.descriptor,
                expected: linked.headIdentity,
                maximumBytes: 4_096
            )
            guard try Self.worktreeMetadataLine(
                head,
                description: "linked worktree HEAD"
            ) == linked.headValue else {
                throw GitSafetyError.unsafeRepository(
                    "linked worktree HEAD changed"
                )
            }
        }
    }

    private func freshOperationLinkedWorktree(
        _ targetWorktree: Worktree
    ) throws -> RepositoryLinkedWorktree {
        guard !targetWorktree.isPrimary,
              let expectedRoot = targetWorktree.rootIdentity else {
            throw GitSafetyError.unsafeRepository(
                "operation linked worktree identity is incomplete"
            )
        }
        return try RepositoryRootPathIdentity
            .withVerifiedDirectory(
                path: targetWorktree.path,
                expected: expectedRoot
            ) { opened in
                let marker = try readWorktreeMetadataSnapshot(
                    ".git",
                    directory: opened.descriptor,
                    expected: nil,
                    maximumBytes: 16_384
                )
                let markerLine = try Self.worktreeMetadataLine(
                    marker.data,
                    description:
                        "operation linked worktree marker"
                )
                guard markerLine.hasPrefix("gitdir: ") else {
                    throw GitSafetyError.unsafeRepository(
                        "operation linked worktree marker is malformed"
                    )
                }
                let registrationPath =
                    try Self.resolveWorktreeMetadataPath(
                        String(markerLine.dropFirst(
                            "gitdir: ".count
                        )),
                        relativeTo: opened.canonicalPath
                    )
                let registrationURL = URL(
                    fileURLWithPath: registrationPath
                )
                let registrationID =
                    registrationURL.lastPathComponent
                let registrationRoot =
                    registrationURL
                        .deletingLastPathComponent().path
                guard registrationRoot
                        == identity.commonDirectoryPath
                            + "/worktrees",
                      !registrationID.isEmpty,
                      registrationID != ".",
                      registrationID != "..",
                      !registrationID.contains("/"),
                      !registrationID.contains("\0") else {
                    throw GitSafetyError.unsafeRepository(
                        "operation linked worktree registration is invalid"
                    )
                }
                return try RepositoryRootPathIdentity
                    .withVerifiedDirectory(
                        path: registrationPath,
                        expected:
                            targetWorktree.registrationIdentity
                    ) { registration in
                        var worktreeConfig = stat()
                        guard fstatat(
                            registration.descriptor,
                            "config.worktree",
                            &worktreeConfig,
                            AT_SYMLINK_NOFOLLOW
                        ) != 0, errno == ENOENT else {
                            throw GitSafetyError.unsafeRepository(
                                "operation linked worktree configuration changed"
                            )
                        }
                        let gitdir =
                            try readWorktreeMetadataSnapshot(
                                "gitdir",
                                directory:
                                    registration.descriptor,
                                expected: nil,
                                maximumBytes: 16_384
                            )
                        let common =
                            try readWorktreeMetadataSnapshot(
                                "commondir",
                                directory:
                                    registration.descriptor,
                                expected: nil,
                                maximumBytes: 4_096
                            )
                        let head =
                            try readWorktreeMetadataSnapshot(
                                "HEAD",
                                directory:
                                    registration.descriptor,
                                expected: nil,
                                maximumBytes: 4_096
                            )
                        let gitdirPath =
                            try Self.resolveWorktreeMetadataPath(
                                try Self.worktreeMetadataLine(
                                    gitdir.data,
                                    description:
                                        "operation registered worktree path"
                                ),
                                relativeTo:
                                    registration.canonicalPath
                            )
                        let commonPath =
                            try Self.resolveWorktreeMetadataPath(
                                try Self.worktreeMetadataLine(
                                    common.data,
                                    description:
                                        "operation linked common directory"
                                ),
                                relativeTo:
                                    registration.canonicalPath
                            )
                        let headValue =
                            try Self.worktreeMetadataLine(
                                head.data,
                                description:
                                    "operation linked worktree HEAD"
                            )
                        let expectedHead: String
                        if let branch =
                            targetWorktree.attachedBranchRef {
                            expectedHead = "ref: \(branch)"
                        } else if let oid =
                            targetWorktree.detachedOID {
                            expectedHead = oid
                        } else {
                            throw GitSafetyError
                                .unsafeRepository(
                                    "operation linked worktree HEAD evidence is incomplete"
                                )
                        }
                        guard gitdirPath
                                == opened.canonicalPath + "/.git",
                              commonPath
                                == identity
                                    .commonDirectoryPath,
                              headValue == expectedHead,
                              Self.validWorktreeHead(
                                  headValue
                              ) else {
                            throw GitSafetyError.unsafeRepository(
                                "operation linked worktree metadata changed"
                            )
                        }
                        try RepositoryRootPathIdentity
                            .withVerifiedDirectory(
                                path: commonPath,
                                expected:
                                    candidate
                                        .commonDirectoryIdentity
                            ) { commonDirectory in
                                guard commonDirectory
                                    .canonicalPath
                                    == identity
                                        .commonDirectoryPath
                                else {
                                    throw GitSafetyError
                                        .unsafeRepository(
                                            "operation linked common directory changed"
                                        )
                                }
                            }
                        return RepositoryLinkedWorktree(
                            path: opened.canonicalPath,
                            rootIdentity: opened.identity,
                            markerIdentity:
                                marker.identity,
                            registrationDirectoryIdentity:
                                registration.identity,
                            registrationGitdirIdentity:
                                gitdir.identity,
                            commonDirectoryMarkerIdentity:
                                common.identity,
                            headIdentity: head.identity,
                            headValue: headValue
                        )
                    }
            }
    }

    private struct WorktreeMetadataSnapshot {
        let data: Data
        let identity: RepositoryMetadataFileIdentity
    }

    private func readWorktreeMetadata(
        _ name: String,
        directory: Int32,
        expected: RepositoryMetadataFileIdentity?,
        maximumBytes: Int
    ) throws -> Data {
        try readWorktreeMetadataSnapshot(
            name,
            directory: directory,
            expected: expected,
            maximumBytes: maximumBytes
        ).data
    }

    private func readWorktreeMetadataSnapshot(
        _ name: String,
        directory: Int32,
        expected: RepositoryMetadataFileIdentity?,
        maximumBytes: Int
    ) throws -> WorktreeMetadataSnapshot {
        let descriptor = openat(
            directory,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw GitSafetyError.unsafeRepository(
                "worktree metadata cannot be opened"
            )
        }
        defer { close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              FileIdentity(initial).isRegular,
              initial.st_uid == geteuid(),
              initial.st_nlink == 1,
              expected == nil
                || RepositoryMetadataFileIdentity(initial) == expected else {
            throw GitSafetyError.unsafeRepository(
                "worktree metadata identity changed"
            )
        }
        let data = try Self.readBounded(
            fd: descriptor,
            maximumBytes: maximumBytes
        )
        var final = stat()
        guard fstat(descriptor, &final) == 0,
              RepositoryMetadataFileIdentity(final)
                == RepositoryMetadataFileIdentity(initial),
              expected == nil
                || RepositoryMetadataFileIdentity(final) == expected else {
            throw GitSafetyError.unsafeRepository(
                "worktree metadata changed while read"
            )
        }
        return WorktreeMetadataSnapshot(
            data: data,
            identity: RepositoryMetadataFileIdentity(final)
        )
    }

    private static func validWorktreeHead(_ value: String) -> Bool {
        if value.hasPrefix("ref: refs/heads/") {
            let branch = String(value.dropFirst("ref: refs/heads/".count))
            return !branch.isEmpty
                && !branch.contains("..")
                && !branch.contains("@{")
                && !branch.contains("\\")
                && !branch.hasPrefix("/")
                && !branch.hasSuffix("/")
                && !branch.hasSuffix(".")
        }
        let lowercased = value.lowercased()
        return (lowercased.count == 40 || lowercased.count == 64)
            && lowercased.allSatisfy {
                $0.isNumber || ("a"..."f").contains($0)
            }
    }

    private static func worktreeMetadataLine(
        _ data: Data,
        description: String
    ) throws -> String {
        guard var value = String(data: data, encoding: .utf8),
              !value.contains("\r"),
              !value.contains("\0") else {
            throw GitSafetyError.unsafeRepository(
                "\(description) is malformed"
            )
        }
        if value.hasSuffix("\n") {
            value.removeLast()
        }
        guard !value.isEmpty, !value.contains("\n") else {
            throw GitSafetyError.unsafeRepository(
                "\(description) is malformed"
            )
        }
        return value
    }

    private static func resolveWorktreeMetadataPath(
        _ value: String,
        relativeTo base: String
    ) throws -> String {
        guard !value.isEmpty,
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              base.hasPrefix("/") else {
            throw GitSafetyError.unsafeRepository(
                "worktree metadata path is malformed"
            )
        }
        var components = value.hasPrefix("/")
            ? [String]()
            : base.split(separator: "/").map(String.init)
        for component in value.split(
            separator: "/",
            omittingEmptySubsequences: false
        ) {
            if component.isEmpty || component == "." {
                continue
            }
            if component == ".." {
                guard !components.isEmpty else {
                    throw GitSafetyError.unsafeRepository(
                        "worktree metadata path escaped root"
                    )
                }
                components.removeLast()
                continue
            }
            guard !component.contains("\\") else {
                throw GitSafetyError.unsafeRepository(
                    "worktree metadata path is malformed"
                )
            }
            components.append(String(component))
        }
        guard !components.isEmpty else {
            throw GitSafetyError.unsafeRepository(
                "worktree metadata path is empty"
            )
        }
        return "/" + components.joined(separator: "/")
    }

    public func readOnlyMainCommit() throws -> String? {
        try readOnlyLocalBranchCommit(
            "refs/heads/main"
        )
    }

    func readOnlyRemoteMainCommit() throws -> String? {
        try readOnlyReferenceCommit(
            "refs/remotes/origin/main"
        )
    }

    func readOnlyLooseCommitObject(
        _ objectID: String
    ) throws -> Bool? {
        guard Self.isObjectID(objectID) else {
            throw GitSafetyError.unsafeRepository(
                "object identity is malformed"
            )
        }
        try revalidate()
        guard let compressed = try readStableRefFile(
            "objects/\(objectID.prefix(2))/\(objectID.dropFirst(2))",
            maximumBytes: 1_048_576
        ) else {
            try revalidate()
            return nil
        }
        var stream = z_stream()
        guard inflateInit_(
            &stream,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK else {
            throw GitSafetyError.unsafeRepository(
                "loose object decompressor is unavailable"
            )
        }
        defer { inflateEnd(&stream) }
        var inflated = Data(count: 1_048_576)
        let status = compressed.withUnsafeBytes { source in
            inflated.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(
                    mutating: source.bindMemory(to: Bytef.self).baseAddress
                )
                stream.avail_in = uInt(source.count)
                stream.next_out = destination.bindMemory(
                    to: Bytef.self
                ).baseAddress
                stream.avail_out = uInt(destination.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        if status == Z_BUF_ERROR, stream.avail_out == 0 {
            try revalidate()
            return nil
        }
        guard status == Z_STREAM_END,
              stream.avail_in == 0 else {
            throw GitSafetyError.unsafeRepository(
                "loose object is malformed"
            )
        }
        inflated.count = Int(stream.total_out)
        let expected: String
        if objectID.count == 40 {
            expected = Insecure.SHA1.hash(data: inflated).map {
                String(format: "%02x", $0)
            }.joined()
        } else {
            expected = SHA256.hash(data: inflated).map {
                String(format: "%02x", $0)
            }.joined()
        }
        guard expected == objectID.lowercased(),
              let terminator = inflated.firstIndex(of: 0),
              let header = String(
                  data: inflated[..<terminator],
                  encoding: .ascii
              ),
              let separator = header.firstIndex(of: " "),
              Int(header[header.index(after: separator)...])
                == inflated.count - terminator - 1 else {
            throw GitSafetyError.unsafeRepository(
                "loose object identity is invalid"
            )
        }
        try revalidate()
        return header[..<separator] == "commit"
    }

    public func readOnlyLocalBranchCommit(
        _ reference: String
    ) throws -> String? {
        guard GitReferenceSyntax.isValidLocalBranchRef(
            reference
        ) else {
            throw GitSafetyError.unsafeRepository(
                "local branch ref is malformed"
            )
        }
        return try readOnlyReferenceCommit(reference)
    }

    private func readOnlyReferenceCommit(
        _ reference: String
    ) throws -> String? {
        try revalidate()
        try rejectReplacementAndGraftState()
        try rejectBusyState()
        if let bytes = try readStableRefFile(
            reference,
            maximumBytes: 256
        ) {
            let value = String(
                decoding: bytes,
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isObjectID(value) else {
                throw GitSafetyError.unsafeRepository(
                    "local branch ref is malformed"
                )
            }
            try revalidate()
            return value
        }
        guard let packed = try readStableRefFile(
            "packed-refs",
            maximumBytes: 1_048_576
        ) else {
            try revalidate()
            return nil
        }
        let text = String(decoding: packed, as: UTF8.self)
        var match: String?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("#") || line.hasPrefix("^") {
                continue
            }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count == 2,
               fields[1] == Substring(reference) {
                let value = String(fields[0])
                guard Self.isObjectID(value), match == nil else {
                    throw GitSafetyError.unsafeRepository(
                        "packed local branch is ambiguous"
                    )
                }
                match = value
            }
        }
        try revalidate()
        return match
    }

    func verifyNoRegisteredLinkedWorktrees() throws -> Bool {
        try revalidate()
        guard candidate.linkedWorktrees.isEmpty,
              candidate.linkedWorktreePaths.isEmpty else {
            return false
        }
        var info = stat()
        if fstatat(
            gitDescriptor.value,
            "worktrees",
            &info,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            return false
        }
        guard errno == ENOENT else {
            throw GitSafetyError.unsafeRepository(
                "worktree metadata cannot be inspected"
            )
        }
        try revalidate()
        return true
    }

    func readOnlyHiddenIndexState() throws -> Bool? {
        try revalidate()
        let directory = linkedWorktreeGitDescriptor?.value
            ?? gitDescriptor.value
        let descriptor = openat(
            directory,
            "index",
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                try revalidate()
                return false
            }
            throw GitSafetyError.unsafeRepository(
                "index metadata cannot be opened"
            )
        }
        defer { close(descriptor) }
        var opened = stat()
        var named = stat()
        guard fstat(descriptor, &opened) == 0,
              fstatat(
                  directory,
                  "index",
                  &named,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              FileIdentity(opened).isRegular,
              opened.st_uid == geteuid(),
              opened.st_nlink == 1,
              FileIdentity(opened) == FileIdentity(named) else {
            throw GitSafetyError.unsafeRepository(
                "index metadata identity is unsafe"
            )
        }
        let before = RepositoryMetadataFileIdentity(opened)
        let data = try Self.readBounded(
            fd: descriptor,
            maximumBytes: 16_777_216
        )
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              RepositoryMetadataFileIdentity(after) == before else {
            throw GitSafetyError.unsafeRepository(
                "index metadata changed while read"
            )
        }
        try revalidate()
        var parsed: [Bool?] = []
        for objectIDBytes in [20, 32] {
            do {
                parsed.append(
                    try GitIndexValidator.hiddenEntryState(
                        data,
                        objectIDBytes: objectIDBytes
                    )
                )
            } catch {
                continue
            }
        }
        guard parsed.count == 1 else {
            throw GitSafetyError.unsafeRepository(
                "index metadata is malformed"
            )
        }
        return parsed[0]
    }

    private func readStableRefFile(
        _ path: String,
        maximumBytes: Int
    ) throws -> Data? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let parent = try Self.noFollowParent(components: parts, directory: gitDescriptor.value),
              let leaf = parts.last else { return nil }
        let descriptor = openat(
            parent.value,
            leaf,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw GitSafetyError.unsafeRepository("ref metadata cannot be opened")
        }
        defer { close(descriptor) }
        var opened = stat()
        var named = stat()
        guard fstat(descriptor, &opened) == 0,
              fstatat(
                  parent.value,
                  leaf,
                  &named,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              FileIdentity(opened).isRegular,
              opened.st_uid == geteuid(),
              opened.st_nlink == 1,
              opened.st_dev == named.st_dev,
              opened.st_ino == named.st_ino else {
            throw GitSafetyError.unsafeRepository("ref metadata identity is unsafe")
        }
        let data = try Self.readBounded(fd: descriptor, maximumBytes: maximumBytes)
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == opened.st_dev,
              after.st_ino == opened.st_ino,
              after.st_size == opened.st_size,
              after.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec else {
            throw GitSafetyError.unsafeRepository("ref metadata changed during inspection")
        }
        return data
    }

    private static func isObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.unicodeScalars.allSatisfy {
                ("0"..."9").contains(Character(String($0)))
                    || ("a"..."f").contains(Character(String($0).lowercased()))
            }
    }

    public func freezeConfiguration(
        account: EffectiveAccount,
        additionalConfiguration: String? = nil
    ) throws -> FrozenGitConfiguration {
        #if SHADOW_SYNC_TESTING
        guard !GitConfigurationValidationTesting.forbidRawProbe else { throw SystemGitConfigurationError.unavailable }
        return try freezeConfiguration(account: account, additionalConfiguration: additionalConfiguration,
                                       systemPath: nil)
        #else
        throw SystemGitConfigurationError.unavailable
        #endif
    }

    func freezeConfiguration(account: EffectiveAccount, configurationProbe: SystemGitConfigurationProbe,
                             additionalConfiguration: String? = nil) throws -> FrozenGitConfiguration {
        try configurationProbe.validate(account: account)
        let value = try freezeConfiguration(account: account, additionalConfiguration: additionalConfiguration,
            systemPath: { try configurationProbe.activePath(account: account) })
        try configurationProbe.validate(account: account)
        return value
    }

    /// Capture once under actual caller-held custody. Subsequent parent-side
    /// preflight/postflight reuses this input and revalidates the same files.
    func freezeConfiguration(account: EffectiveAccount, retainedConfigurationProbe probe: SystemGitConfigurationProbe,
                             additionalConfiguration: String? = nil,
                             admitConfiguration: ((GitConfigurationPreflight, CustodyBudget) throws -> Void)? = nil) throws -> FrozenGitConfiguration {
        // Choose both future names lexically. No directory lookup, recovery scan,
        // contributor read or mkdir is permitted before every ancestor is admitted.
        #if SHADOW_SYNC_TESTING
        let budget = try probe.testingFreezeBudget ?? CustodyBudget.make(kind: .repositoryGit, workSeconds: 120)
        #else
        let budget = try CustodyBudget.make(kind: .repositoryGit, workSeconds: 120)
        #endif
        let directory = try Self.frozenSnapshotPrefix() + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6))
        let preflight = try probe.capturePreflight(account: account, budget: budget)
        let paths = try preflight.admissionPaths(account: account) + [directory, directory + "/config"]
        let admission = try probe.frozenConfigurationAdmission(expectedPolicySHA256: candidate.policyAdmissionSHA256,
            scratch: worktreeDescriptor, budget: budget, account: account)
        try admission.admit(paths)
        #if SHADOW_SYNC_TESTING
        try probe.testingBeforeConfigurationAdmission?(budget)
        #endif
        try admitConfiguration?(preflight, budget)
        try admission.revalidate()
        #if SHADOW_SYNC_TESTING
        probe.testingFrozenAccess?()
        #endif
        try Self.recoverStaleSnapshots(admit: admission.admit, revalidate: admission.revalidate, probe: probe)
        try admission.admit(paths)
        try admission.revalidate()
        let value = try freezeConfiguration(account: account, additionalConfiguration: additionalConfiguration,
            systemPath: { preflight.systemPath }, retainedPreflight: preflight, retainedProbe: probe,
            admittedDirectory: directory)
        try preflight.validate(configuration: value.snapshot, account: account)
        try probe.validate(account: account)
        return value
    }

    private func freezeConfiguration(account: EffectiveAccount, additionalConfiguration: String?,
                                     systemPath: (() throws -> String?)?,
                                     retainedPreflight: GitConfigurationPreflight? = nil,
                                     retainedProbe: SystemGitConfigurationProbe? = nil,
                                     admittedDirectory: String? = nil) throws -> FrozenGitConfiguration {
        try revalidate()
        try rejectReplacementAndGraftState()
        // The retained caller already recovered under exact path admission.
        if retainedProbe == nil { try Self.recoverStaleSnapshots() }
        let contributorPaths = try Self.configurationPaths(account: account, systemPath: systemPath)
        let captured = try captureConfiguration(account: account, contributorPaths: contributorPaths,
                                                additionalConfiguration: additionalConfiguration)
        let frozenBytes = captured.bytes
        let frozenDigest = Self.sha256(frozenBytes)
        let retained = try Self.makeRetainedSnapshot(contents: frozenBytes, admittedDirectory: admittedDirectory)
        var frozenInfo = stat()
        var directoryInfo = stat()
        guard fstat(retained.descriptor, &frozenInfo) == 0,
              fstat(retained.directoryDescriptor, &directoryInfo) == 0 else {
            close(retained.descriptor)
            close(retained.directoryDescriptor)
            throw SecureStateError.systemCall("stat frozen Git config", errno)
        }
        let snapshot = GitConfigurationSnapshot(
            contributors: captured.contributors,
            repositoryConfig: captured.repositoryConfig,
            frozenDirectoryPath: retained.directory,
            frozenDirectoryIdentity: FileIdentity(directoryInfo),
            frozenPath: retained.path,
            frozenIdentity: FileIdentity(frozenInfo),
            frozenOwnerPID: getpid(),
            frozenSHA256: frozenDigest,
            frozenSize: frozenBytes.count
        )
        return FrozenGitConfiguration(
            descriptor: retained.descriptor,
            directoryDescriptor: retained.directoryDescriptor,
            snapshot: snapshot,
            effectiveHooksDirectory: captured.effectiveHooksDirectory,
            retainedPreflight: retainedPreflight, retainedProbe: retainedProbe
        )
    }

    /// The completed preflight is an input commitment, not access authority.
    /// The discovery custodian owes policy admission for all paths/ancestors.
    /// Account validation precedes any repository or configuration access.
    func captureConfiguration(account: EffectiveAccount, configurationPreflight: GitConfigurationPreflight)
        throws -> CapturedGitConfiguration {
        let paths = try configurationPreflight.admissionPaths(account: account)
        try revalidate(); try rejectReplacementAndGraftState()
        let captured = try captureConfiguration(account: account, contributorPaths: paths,
                                                additionalConfiguration: nil)
        try revalidate(); try rejectReplacementAndGraftState()
        return captured
    }

    private func captureConfiguration(account: EffectiveAccount, contributorPaths: [String],
                                      additionalConfiguration: String?) throws -> CapturedGitConfiguration {
        var contributorDigests: [GitPathDigest] = []
        var frozenBytes = Data()
        for path in contributorPaths {
            let allowedOwners: Set<uid_t> = path.hasPrefix(account.homeDirectory + "/")
                ? [account.uid]
                : [0, account.uid]
            let captured = try Self.captureOptionalAbsoluteFile(
                path: path,
                maximumBytes: 262_144,
                allowedOwners: allowedOwners
            )
            contributorDigests.append(GitPathDigest(path: path, file: captured?.digest))
            if let captured {
                try Self.rejectIncludes(in: captured.contents, path: path)
                Self.appendConfigBytes(captured.contents, to: &frozenBytes)
            }
        }
        let local = try Self.captureRequiredFile(
            path: "config",
            directory: gitDescriptor.value,
            displayPath: ".git/config",
            maximumBytes: 1_048_576,
            allowedOwners: [geteuid()]
        )
        _ = try RawGitConfig.parse(local.contents)
        if let additionalConfiguration {
            guard additionalConfiguration.utf8.count <= 16_384 else {
                throw GitSafetyError.malformedConfig("test mapping exceeds its bound")
            }
            Self.appendConfigBytes(Data(additionalConfiguration.utf8), to: &frozenBytes)
        }
        guard frozenBytes.count <= 1_572_864 else {
            throw GitSafetyError.malformedConfig("effective configuration exceeds its bound")
        }
        let effectiveHooksDirectory =
            try? EffectiveHooksConfiguration.directory(
                global: frozenBytes,
                local: local.contents,
                worktreePath: worktreePath,
                commonDirectory:
                    identity.commonDirectoryPath,
                account: account
            )
        return CapturedGitConfiguration(contributors: contributorDigests, repositoryConfig: local.digest,
                                        bytes: frozenBytes, effectiveHooksDirectory: effectiveHooksDirectory)
    }

    /// No process is started and an explicitly absent system source stays absent.
    /// The helper supplies its retained frozen snapshot and separately validates
    /// the frozen descriptors before resume and again during postflight.
    func executionSnapshot(account: EffectiveAccount, configuration: GitConfigurationSnapshot,
                           admission: GitAdmissionSnapshot?, configurationPreflight: GitConfigurationPreflight)
        throws -> RepositoryExecutionSnapshot {
        try configurationPreflight.validate(configuration: configuration, account: account)
        return try executionSnapshot(account: account, configuration: configuration, admission: admission,
                                     systemPath: { configurationPreflight.systemPath })
    }

    public func executionSnapshot(
        account: EffectiveAccount,
        frozenConfiguration: FrozenGitConfiguration,
        admission: GitAdmissionSnapshot?
    ) throws -> RepositoryExecutionSnapshot {
        if let preflight = frozenConfiguration.retainedPreflight,
           let probe = frozenConfiguration.retainedProbe {
            try probe.validate(account: account)
            try Self.validateFrozenConfiguration(descriptor: frozenConfiguration.descriptor,
                directoryDescriptor: frozenConfiguration.directoryDescriptor, snapshot: frozenConfiguration.snapshot)
            let value = try executionSnapshot(account: account, configuration: frozenConfiguration.snapshot,
                admission: admission, configurationPreflight: preflight)
            try probe.validate(account: account)
            return value
        }
        #if SHADOW_SYNC_TESTING
        guard !GitConfigurationValidationTesting.forbidRawProbe else { throw SystemGitConfigurationError.unavailable }
        return try executionSnapshot(account: account, frozenConfiguration: frozenConfiguration,
                                     admission: admission, systemPath: nil)
        #else
        throw SystemGitConfigurationError.unavailable
        #endif
    }

    func executionSnapshot(account: EffectiveAccount, frozenConfiguration: FrozenGitConfiguration,
                           admission: GitAdmissionSnapshot?, configurationProbe: SystemGitConfigurationProbe)
        throws -> RepositoryExecutionSnapshot {
        try configurationProbe.validate(account: account)
        let value = try executionSnapshot(account: account, frozenConfiguration: frozenConfiguration,
            admission: admission, systemPath: { try configurationProbe.activePath(account: account) })
        try configurationProbe.validate(account: account)
        return value
    }

    private func executionSnapshot(account: EffectiveAccount, frozenConfiguration: FrozenGitConfiguration,
                                   admission: GitAdmissionSnapshot?, systemPath: (() throws -> String?)?)
        throws -> RepositoryExecutionSnapshot {
        try executionSnapshot(account: account, configuration: frozenConfiguration.snapshot,
                              admission: admission, systemPath: systemPath)
    }

    private func executionSnapshot(account: EffectiveAccount, configuration frozen: GitConfigurationSnapshot,
                                   admission: GitAdmissionSnapshot?, systemPath: (() throws -> String?)?)
        throws -> RepositoryExecutionSnapshot {
        try revalidate()
        try rejectReplacementAndGraftState()
        let configuration = try Self.captureConfigurationManifest(
            account: account,
            repositoryDirectory: gitDescriptor.value,
            frozen: frozen,
            systemPath: systemPath
        )
        if let admission,
           admission.frozenConfigSHA256 != configuration.frozenSHA256 {
            throw GitSafetyError.originChanged
        }
        return RepositoryExecutionSnapshot(
            repository: identity,
            rootPath: worktreePath,
            accountUID: UInt32(account.uid),
            accountUsername: account.username,
            accountHome: account.homeDirectory,
            packedRefs: try Self.capturePackedRefs(directory: gitDescriptor.value),
            configuration: configuration,
            admission: admission
        )
    }

    private static func captureConfigurationManifest(
        account: EffectiveAccount,
        repositoryDirectory: Int32,
        frozen: GitConfigurationSnapshot,
        systemPath: (() throws -> String?)? = nil
    ) throws -> GitConfigurationSnapshot {
        let paths = try configurationPaths(account: account, systemPath: systemPath)
        let contributors = try paths.map { path -> GitPathDigest in
            let allowedOwners: Set<uid_t> = path.hasPrefix(account.homeDirectory + "/")
                ? [account.uid]
                : [0, account.uid]
            let captured = try captureOptionalAbsoluteFile(
                path: path,
                maximumBytes: 262_144,
                allowedOwners: allowedOwners
            )
            if let captured {
                try rejectIncludes(in: captured.contents, path: path)
            }
            return GitPathDigest(path: path, file: captured?.digest)
        }
        let localCaptured = try captureRequiredFile(
            path: "config",
            directory: repositoryDirectory,
            displayPath: ".git/config",
            maximumBytes: 1_048_576,
            allowedOwners: [geteuid()]
        )
        _ = try RawGitConfig.parse(localCaptured.contents)
        guard contributors == frozen.contributors,
              localCaptured.digest == frozen.repositoryConfig else {
            throw GitSafetyError.unsafeRepository(
                "configuration contributor identity or digest changed"
            )
        }
        return GitConfigurationSnapshot(
            contributors: contributors,
            repositoryConfig: localCaptured.digest,
            frozenDirectoryPath: frozen.frozenDirectoryPath,
            frozenDirectoryIdentity: frozen.frozenDirectoryIdentity,
            frozenPath: frozen.frozenPath,
            frozenIdentity: frozen.frozenIdentity,
            frozenOwnerPID: frozen.frozenOwnerPID,
            frozenSHA256: frozen.frozenSHA256,
            frozenSize: frozen.frozenSize
        )
    }

    private static func configurationPaths(account: EffectiveAccount,
                                           systemPath: (() throws -> String?)? = nil) throws -> [String] {
        // A typed service's ordinary nil is authoritative. Never fall back to
        // the legacy raw probe after either nil or a thrown custody failure.
        let active: String?
        if let systemPath { active = try systemPath() }
        else {
            #if SHADOW_SYNC_TESTING
            active = try activeSystemConfigurationPath(account: account)
            #else
            throw SystemGitConfigurationError.unavailable
            #endif
        }
        var paths: [String] = []
        if let system = active {
            paths.append(system)
        }
        paths += [
            account.homeDirectory + "/.config/git/config",
            account.homeDirectory + "/.gitconfig",
        ]
        return paths
    }

    #if SHADOW_SYNC_TESTING
    private static func activeSystemConfigurationPath(
        account: EffectiveAccount
    ) throws -> String? {
        #if SHADOW_SYNC_TESTING
        if GitConfigurationValidationTesting.forbidRawProbe {
            throw GitSafetyError.unsafeRepository("raw configuration probe forbidden by fixture")
        }
        #endif
        return try runSystemConfigurationProbe(
            account: account,
            executablePath: "/usr/bin/git",
            arguments: [
                "/usr/bin/git", "config", "--system", "--show-origin",
                "--name-only", "--null", "--list",
            ]
        )
    }

    private static func runSystemConfigurationProbe(
        account: EffectiveAccount,
        executablePath: String,
        arguments: [String]
    ) throws -> String? {
        var outputPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0 else {
            throw SecureStateError.systemCall("pipe system Git config probe", errno)
        }
        let nullFD = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
        guard nullFD >= 0 else {
            close(outputPipe[0])
            close(outputPipe[1])
            throw SecureStateError.systemCall("open /dev/null", errno)
        }
        defer {
            close(outputPipe[0])
            close(nullFD)
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            close(outputPipe[1])
            throw SecureStateError.systemCall("system Git config probe init", errno)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        var code = posix_spawn_file_actions_adddup2(&actions, nullFD, STDIN_FILENO)
        if code == 0 {
            code = posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        }
        if code == 0 {
            code = posix_spawn_file_actions_adddup2(&actions, nullFD, STDERR_FILENO)
        }
        if code == 0 {
            code = posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
            )
        }
        guard code == 0 else {
            close(outputPipe[1])
            throw SecureStateError.systemCall("system Git config probe setup", code)
        }
        let environment = [
            "HOME=\(account.homeDirectory)",
            "USER=\(account.username)",
            "LOGNAME=\(account.username)",
            "PATH=\(ClosedGitEnvironment.fixedPath)",
            "LANG=C",
            "LC_ALL=C",
            "GIT_TERMINAL_PROMPT=0",
        ]
        var child: pid_t = 0
        code = withGitCStringArray(arguments) { argv in
            withGitCStringArray(environment) { envp in
                posix_spawn(&child, executablePath, &actions, &attributes, argv, envp)
            }
        }
        close(outputPipe[1])
        guard code == 0 else {
            throw SecureStateError.systemCall("spawn system Git config probe", code)
        }
        let identity = try ProcessIdentity.capture(
            processID: child,
            generation: RunIdentity.make(),
            expectedExecutablePath: executablePath
        )
        let flags = fcntl(outputPipe[0], F_GETFL)
        guard flags >= 0,
              fcntl(outputPipe[0], F_SETFL, flags | O_NONBLOCK) == 0 else {
            try terminateSystemConfigurationProbe(child: child, identity: identity)
            throw SecureStateError.systemCall("configure system Git config probe", errno)
        }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var status: Int32 = 0
        var reaped = false
        var reachedEOF = false
        let deadline = MonotonicDeadline(
            seconds: ChildProcessBudget.seconds(5)
        )
        while !reaped || !reachedEOF {
            let count = Darwin.read(outputPipe[0], &buffer, buffer.count)
            if count > 0 {
                guard output.count + count <= 65_536 else {
                    try terminateSystemConfigurationProbe(child: child, identity: identity)
                    throw GitSafetyError.unsafeRepository(
                        "system Git config origin output exceeded its bound"
                    )
                }
                output.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            if count == 0 {
                reachedEOF = true
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                try terminateSystemConfigurationProbe(child: child, identity: identity)
                throw SecureStateError.systemCall("read system Git config probe", errno)
            }
            if !reaped {
                let waited = waitpid(child, &status, WNOHANG)
                if waited == child || (waited < 0 && errno == ECHILD) {
                    reaped = true
                } else if waited < 0, errno != EINTR {
                    try terminateSystemConfigurationProbe(child: child, identity: identity)
                    throw SecureStateError.systemCall("wait system Git config probe", errno)
                }
            }
            guard !deadline.hasExpired else {
                try terminateSystemConfigurationProbe(child: child, identity: identity)
                throw GitSafetyError.commandFailed("system Git config probe timeout", 124, "")
            }
            var item = pollfd(
                fd: outputPipe[0],
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            _ = poll(&item, 1, 20)
        }
        let exitCode = (status & 0x7F) == 0
            ? (status >> 8) & 0xFF
            : 128 + (status & 0x7F)
        if exitCode != 0 {
            guard output.isEmpty else {
                throw GitSafetyError.unsafeRepository(
                    "failed system Git config probe emitted unexpected output"
                )
            }
            return nil
        }
        return try activeSystemPath(from: output)
    }

    #if SHADOW_SYNC_TESTING
    public static func testingSystemConfigurationProbe(
        account: EffectiveAccount,
        executablePath: String,
        arguments: [String]
    ) throws -> String? {
        try runSystemConfigurationProbe(
            account: account,
            executablePath: executablePath,
            arguments: arguments
        )
    }
    #endif

    private static func terminateSystemConfigurationProbe(
        child: pid_t,
        identity: ProcessIdentity
    ) throws {
        var status: Int32 = 0
        let initial = waitpid(child, &status, WNOHANG)
        if initial == child || (initial < 0 && errno == ECHILD) {
            return
        }
        guard initial == 0 || (initial < 0 && errno == EINTR),
              identity.isCurrent(
                expectedGeneration: identity.generation,
                requireGroupLeader: false
              ) else {
            throw ProcessOwnershipError.unverifiedOwner
        }
        _ = kill(child, SIGKILL)
        let deadline = MonotonicDeadline(seconds: ProcessOwnershipTiming.postKillReap)
        while !deadline.hasExpired {
            let waited = waitpid(child, &status, WNOHANG)
            if waited == child || (waited < 0 && errno == ECHILD) {
                return
            }
            if waited < 0, errno != EINTR {
                throw SecureStateError.systemCall(
                    "wait killed system Git config probe",
                    errno
                )
            }
            usleep(20_000)
        }
        throw ProcessOwnershipError.unavailable("system Git config probe reap")
    }

    #endif

    static func activeSystemPath(from output: Data) throws -> String? {
        let fields = output.split(separator: 0, omittingEmptySubsequences: true)
        guard fields.count.isMultiple(of: 2) else {
            throw GitSafetyError.unsafeRepository("system Git config origin output is malformed")
        }
        var origins: Set<String> = []
        for index in stride(from: 0, to: fields.count, by: 2) {
            guard let origin = String(data: fields[index], encoding: .utf8),
                  origin.hasPrefix("file:"),
                  !origin.contains("\n"),
                  !origin.contains("\0") else {
                throw GitSafetyError.unsafeRepository(
                    "system Git config origin is unparseable"
                )
            }
            origins.insert(String(origin.dropFirst(5)))
        }
        guard origins.count <= 1 else {
            throw GitSafetyError.malformedConfig(
                "system Git config includes or multiple origins are unsupported"
            )
        }
        return origins.first
    }

    public func rejectReplacementAndGraftState() throws {
        for path in ["refs/replace", "info/grafts", "objects/info/alternates"] {
            if try Self.metadataEntryExistsWithoutFollowingLinks(path, directory: gitDescriptor.value) {
                throw GitSafetyError.replacementOrGraft
            }
        }
        if let bytes = try readStableRefFile("packed-refs", maximumBytes: 1_048_576),
           String(decoding: bytes, as: UTF8.self).contains(" refs/replace/") {
            throw GitSafetyError.replacementOrGraft
        }
    }

    public func rejectBusyState() throws {
        try rejectBusyState(defaultBranch: "main")
    }

    public func rejectBusyState(defaultBranch: String) throws {
        guard GitReferenceSyntax.isValidBranchName(defaultBranch) else {
            throw GitSafetyError.unsafeRepository(
                "default branch name is invalid"
            )
        }
        let worktreeDirectory = linkedWorktreeGitDescriptor?.value
            ?? gitDescriptor.value
        let worktreeMarkers = [
            "index.lock", "HEAD.lock", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD",
            "BISECT_LOG", "rebase-apply", "rebase-merge", "sequencer",
        ]
        for marker in worktreeMarkers {
            if try Self.metadataEntryExistsWithoutFollowingLinks(marker, directory: worktreeDirectory) {
                throw GitSafetyError.busy
            }
        }
        let commonMarkers = [
            "packed-refs.lock", "config.lock", "shallow.lock",
            "refs/heads/\(defaultBranch).lock",
            "refs/remotes/origin/\(defaultBranch).lock",
        ]
        for marker in commonMarkers {
            if try Self.metadataEntryExistsWithoutFollowingLinks(marker, directory: gitDescriptor.value) {
                throw GitSafetyError.busy
            }
        }
    }

    public func acquireCommonDirectoryOperationLock(
        account: EffectiveAccount
    )
        throws -> CommonDirectoryOperationLock {
        guard let lock = try openCommonDirectoryOperationLock(
            account: account,
            createIfNeeded: true
        ) else {
            throw GitSafetyError.unsafeRepository(
                "common-directory lock could not be created"
            )
        }
        return lock
    }

    public func probeCommonDirectoryOperationLock(
        account: EffectiveAccount
    ) throws -> CommonDirectoryOperationLock? {
        try openCommonDirectoryOperationLock(
            account: account,
            createIfNeeded: false
        )
    }

    private func openCommonDirectoryOperationLock(
        account: EffectiveAccount,
        createIfNeeded: Bool
    ) throws -> CommonDirectoryOperationLock? {
        let home = Darwin.open(
            account.homeDirectory,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard home >= 0 else {
            throw SecureStateError.systemCall(
                "open account home for common-directory lock",
                errno
            )
        }
        defer { close(home) }
        var homeInfo = stat()
        guard fstat(home, &homeInfo) == 0,
              FileIdentity(homeInfo).isDirectory,
              homeInfo.st_uid == account.uid,
              (homeInfo.st_mode & 0o022) == 0 else {
            throw GitSafetyError.unsafeRepository(
                "common-directory lock home is unsafe"
            )
        }
        var parent = fcntl(home, F_DUPFD_CLOEXEC, 0)
        guard parent >= 0 else {
            throw SecureStateError.systemCall(
                "retain common-directory lock parent",
                errno
            )
        }
        defer { close(parent) }
        var directoryIdentities: [(name: String, identity: FileIdentity)] = []
        for component in [".local", "state", "awa", "locks"] {
            if createIfNeeded,
               mkdirat(parent, component, 0o700) != 0,
               errno != EEXIST {
                throw SecureStateError.systemCall(
                    "create common-directory lock parent",
                    errno
                )
            }
            let child = openat(
                parent,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            if child < 0, errno == ENOENT, !createIfNeeded {
                return nil
            }
            guard child >= 0 else {
                throw SecureStateError.systemCall(
                    "open common-directory lock parent",
                    errno
                )
            }
            var childInfo = stat()
            guard fstat(child, &childInfo) == 0,
                  FileIdentity(childInfo).isDirectory,
                  childInfo.st_uid == account.uid,
                  (childInfo.st_mode & 0o022) == 0,
                  component != "locks"
                    || (childInfo.st_mode & 0o077) == 0 else {
                close(child)
                throw GitSafetyError.unsafeRepository(
                    "common-directory lock parent is unsafe"
                )
            }
            directoryIdentities.append(
                (
                    name: component,
                    identity: FileIdentity(childInfo)
                )
            )
            close(parent)
            parent = child
        }
        let lockKey = String(
            SHA256.hash(
                data: Data(identity.commonDirectoryPath.utf8)
            ).map {
                String(format: "%02x", $0)
            }.joined().prefix(24)
        )
        let name = "common-\(lockKey).lock"
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC
            | (createIfNeeded ? O_CREAT : 0)
        let descriptor = openat(
            parent,
            name,
            flags,
            0o600
        )
        if descriptor < 0, errno == ENOENT, !createIfNeeded {
            return nil
        }
        guard descriptor >= 0 else {
            throw SecureStateError.systemCall(
                "open common-directory lock",
                errno
            )
        }
        var descriptorInfo = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0,
              fstatat(
                  parent,
                  name,
                  &pathInfo,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              FileIdentity(descriptorInfo) == FileIdentity(pathInfo),
              FileIdentity(descriptorInfo).isRegular,
              descriptorInfo.st_uid == account.uid,
              descriptorInfo.st_nlink == 1,
              (descriptorInfo.st_mode & 0o077) == 0 else {
            close(descriptor)
            throw GitSafetyError.unsafeRepository(
                "common-directory lock file is unsafe"
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw GitSafetyError.busy
            }
            throw SecureStateError.systemCall(
                "lock shared common-directory operation",
                code
            )
        }
        let retainedParent = fcntl(
            parent,
            F_DUPFD_CLOEXEC,
            0
        )
        guard retainedParent >= 0 else {
            let code = errno
            close(descriptor)
            throw SecureStateError.systemCall(
                "retain common-directory lock parent",
                code
            )
        }
        let retainedRoot = fcntl(
            home,
            F_DUPFD_CLOEXEC,
            0
        )
        guard retainedRoot >= 0 else {
            let code = errno
            close(retainedParent)
            close(descriptor)
            throw SecureStateError.systemCall(
                "retain common-directory lock root",
                code
            )
        }
        let lock = CommonDirectoryOperationLock(
            descriptor: descriptor,
            parent: retainedParent,
            root: retainedRoot,
            rootPath: account.homeDirectory,
            rootIdentity: FileIdentity(homeInfo),
            directoryIdentities: directoryIdentities,
            name: name,
            identity: FileIdentity(descriptorInfo)
        )
        try lock.revalidate()
        return lock
    }

    public static func validateCurrentDirectory(
        _ expected: RepositoryIdentity,
        requireWorktreeMarkerIdentity: Bool = true
    ) throws {
        let rootFD = Darwin.open(".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            throw GitSafetyError.unsafeRepository("child worktree open failed")
        }
        defer { close(rootFD) }
        try validateDirectory(expected, rootFD: rootFD, requireWorktreeMarkerIdentity: requireWorktreeMarkerIdentity)
    }

    private static func validateDirectory(_ expected: RepositoryIdentity, rootFD: Int32,
                                          requireWorktreeMarkerIdentity: Bool) throws {
        var rootStat = stat()
        guard fstat(rootFD, &rootStat) == 0,
              FileIdentity(rootStat).matchesStableNode(expected.root) else {
            throw GitSafetyError.unsafeRepository("child worktree identity changed")
        }
        let markerFD = openat(
            rootFD,
            ".git",
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard markerFD >= 0 else {
            throw GitSafetyError.unsafeRepository(
                "child Git marker open failed"
            )
        }
        defer { close(markerFD) }
        var markerStat = stat()
        guard fstat(markerFD, &markerStat) == 0 else {
            throw GitSafetyError.unsafeRepository(
                "child Git marker identity changed"
            )
        }
        if requireWorktreeMarkerIdentity {
            guard FileIdentity(markerStat).matchesStableNode(
                expected.worktreeMarker
            ),
            expected.worktreeMarkerSize == nil
                || (
                    Int64(markerStat.st_size)
                        == expected.worktreeMarkerSize
                        && Int64(markerStat.st_mtimespec.tv_sec)
                            == expected.worktreeMarkerModifiedSeconds
                        && Int64(markerStat.st_mtimespec.tv_nsec)
                            == expected.worktreeMarkerModifiedNanoseconds
                ) else {
                throw GitSafetyError.unsafeRepository(
                    "child Git marker identity changed"
                )
            }
        } else {
            guard FileIdentity(markerStat).isRegular,
                  markerStat.st_uid == uid_t(expected.worktreeMarker.owner),
                  markerStat.st_nlink == 1,
                  (markerStat.st_mode & 0o022) == 0 else {
                throw GitSafetyError.unsafeRepository(
                    "child Git marker poststate is unsafe"
                )
            }
        }
        let gitFD = try openValidatedCommonDirectory(expected)
        defer { close(gitFD) }
        var configStat = stat()
        guard fstatat(
            gitFD,
            "config",
            &configStat,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
        FileIdentity(configStat) == expected.config,
        Int64(configStat.st_size)
            == expected.configSize,
        Int64(configStat.st_mtimespec.tv_sec)
            == expected.configModifiedSeconds,
        Int64(configStat.st_mtimespec.tv_nsec)
            == expected.configModifiedNanoseconds else {
            throw GitSafetyError.unsafeRepository(
                "child Git metadata identity changed"
            )
        }
        try requireAbsent(relativePath: "config.worktree", directory: gitFD)
        try requireAbsent(relativePath: "commondir", directory: gitFD)
        var objectsStat = stat()
        guard fstatat(gitFD, "objects", &objectsStat, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity(objectsStat).matchesStableNode(expected.objectsDirectory) else {
            throw GitSafetyError.unsafeRepository("child object directory identity changed")
        }
    }

    public static func validateExecutionSnapshot(
        _ snapshot: RepositoryExecutionSnapshot,
        account: EffectiveAccount,
        requirePackedIdentity: Bool = true,
        requireWorktreeMarkerIdentity: Bool = true
    ) throws {
        #if !SHADOW_SYNC_TESTING
        throw SystemGitConfigurationError.unavailable
        #else
        try validateCurrentDirectory(
            snapshot.repository,
            requireWorktreeMarkerIdentity:
                requireWorktreeMarkerIdentity
        )
        try validateCommonExecutionSnapshot(
            snapshot,
            account: account,
            requirePackedIdentity: requirePackedIdentity
        )
        #endif
    }

    public static func validateCommonExecutionSnapshot(
        _ snapshot: RepositoryExecutionSnapshot,
        account: EffectiveAccount,
        requirePackedIdentity: Bool = true
    ) throws {
        #if !SHADOW_SYNC_TESTING
        throw SystemGitConfigurationError.unavailable
        #else
        try validateCommonExecutionSnapshot(snapshot, account: account,
            requirePackedIdentity: requirePackedIdentity, systemPath: nil)
        #endif
    }

    /// Custodian route: use a completed, closed configuration preflight and never
    /// spawn a nested/raw probe from repository validation. The enclosing helper
    /// must first authenticate the request and admit every path under current
    /// policy. This overload retains all repository/config/ref checks below.
    static func validateExecutionSnapshot(
        _ snapshot: RepositoryExecutionSnapshot, account: EffectiveAccount,
        configurationPreflight: GitConfigurationPreflight, rootDescriptor: Int32? = nil,
        requirePackedIdentity: Bool = true, requireWorktreeMarkerIdentity: Bool = true
    ) throws {
        try configurationPreflight.validate(snapshot, account: account)
        if let rootDescriptor {
            try validateDirectory(snapshot.repository, rootFD: rootDescriptor,
                                  requireWorktreeMarkerIdentity: requireWorktreeMarkerIdentity)
        } else {
            try validateCurrentDirectory(snapshot.repository, requireWorktreeMarkerIdentity: requireWorktreeMarkerIdentity)
        }
        try validateCommonExecutionSnapshot(snapshot, account: account,
            configurationPreflight: configurationPreflight, requirePackedIdentity: requirePackedIdentity)
    }

    static func validateCommonExecutionSnapshot(
        _ snapshot: RepositoryExecutionSnapshot, account: EffectiveAccount,
        configurationPreflight: GitConfigurationPreflight, requirePackedIdentity: Bool = true
    ) throws {
        try configurationPreflight.validate(snapshot, account: account)
        try validateCommonExecutionSnapshot(snapshot, account: account,
            requirePackedIdentity: requirePackedIdentity, systemPath: { configurationPreflight.systemPath })
    }

    private static func validateCommonExecutionSnapshot(
        _ snapshot: RepositoryExecutionSnapshot, account: EffectiveAccount,
        requirePackedIdentity: Bool, systemPath: (() throws -> String?)?
    ) throws {
        let gitFD = try openValidatedCommonDirectory(
            snapshot.repository
        )
        defer { close(gitFD) }
        _ = try captureConfigurationManifest(
            account: account,
            repositoryDirectory: gitFD,
            frozen: snapshot.configuration,
            systemPath: systemPath
        )
        try validateGraphState(
            directory: gitFD,
            expectedPackedRefs: snapshot.packedRefs,
            requirePackedIdentity: requirePackedIdentity
        )
        guard snapshot.admission?.frozenConfigSHA256 == nil
                || snapshot.admission?.frozenConfigSHA256
                    == snapshot.configuration.frozenSHA256 else {
            throw GitSafetyError.unsafeRepository("admission configuration digest changed")
        }
    }

    public static func captureRepositoryConfiguration(
        _ snapshot: RepositoryExecutionSnapshot
    ) throws -> Data {
        let gitFD = try openValidatedCommonDirectory(
            snapshot.repository
        )
        defer { close(gitFD) }
        let captured = try captureRequiredFile(
            path: "config",
            directory: gitFD,
            displayPath: ".git/config",
            maximumBytes: 1_048_576,
            allowedOwners: [geteuid()]
        )
        guard captured.digest
                == snapshot.configuration.repositoryConfig else {
            throw GitSafetyError.unsafeRepository(
                "Git config changed before Branch deletion"
            )
        }
        return captured.contents
    }

    public static func validateBranchDeletionSnapshot(
        _ snapshot: RepositoryExecutionSnapshot,
        account: EffectiveAccount,
        branchName: String,
        configurationBefore: Data,
        commandSucceeded: Bool
    ) throws {
        try validateBranchDeletionSnapshot(snapshot, account: account, branchName: branchName,
            configurationBefore: configurationBefore, commandSucceeded: commandSucceeded,
            configurationPreflight: nil)
    }

    static func validateBranchDeletionSnapshot(
        _ snapshot: RepositoryExecutionSnapshot,
        account: EffectiveAccount,
        branchName: String,
        configurationBefore: Data,
        commandSucceeded: Bool,
        configurationPreflight: GitConfigurationPreflight?
    ) throws {
        if let configurationPreflight { try configurationPreflight.validate(snapshot, account: account) }
        #if !SHADOW_SYNC_TESTING
        guard configurationPreflight != nil else { throw SystemGitConfigurationError.unavailable }
        #endif
        try validateWorktreePathAfterBranchDeletion(
            snapshot.repository,
            rootPath: snapshot.rootPath
        )
        let gitFD = try openValidatedCommonDirectory(
            snapshot.repository
        )
        defer { close(gitFD) }
        let contributors =
            try configurationPaths(account: account, systemPath: configurationPreflight.map { captured in { captured.systemPath } }).map {
                path -> GitPathDigest in
                let allowedOwners: Set<uid_t> =
                    path.hasPrefix(
                        account.homeDirectory + "/"
                    )
                        ? [account.uid]
                        : [0, account.uid]
                let captured =
                    try captureOptionalAbsoluteFile(
                        path: path,
                        maximumBytes: 262_144,
                        allowedOwners: allowedOwners
                    )
                if let captured {
                    try rejectIncludes(
                        in: captured.contents,
                        path: path
                    )
                }
                return GitPathDigest(
                    path: path,
                    file: captured?.digest
                )
            }
        guard contributors
                == snapshot.configuration.contributors else {
            throw GitSafetyError.unsafeRepository(
                "configuration contributor changed during Branch deletion"
            )
        }
        let local = try captureRequiredFile(
            path: "config",
            directory: gitFD,
            displayPath: ".git/config",
            maximumBytes: 1_048_576,
            allowedOwners: [account.uid]
        )
        _ = try RawGitConfig.parse(local.contents)
        let expectedAfter =
            removingBranchSection(
                from: configurationBefore,
                branchName: branchName
            )
        let removedOnlyExpectedSection =
            expectedAfter.map {
                local.contents == $0
            } ?? false
        guard local.contents == configurationBefore
                || (
                    commandSucceeded
                        && removedOnlyExpectedSection
                ) else {
            throw GitSafetyError.unsafeRepository(
                "Git config changed beyond the deleted Branch section"
            )
        }
        try validateGraphState(
            directory: gitFD,
            expectedPackedRefs: snapshot.packedRefs,
            requirePackedIdentity: false
        )
        guard snapshot.admission?.frozenConfigSHA256
                == nil
                || snapshot.admission?
                    .frozenConfigSHA256
                    == snapshot.configuration
                        .frozenSHA256 else {
            throw GitSafetyError.unsafeRepository(
                "admission configuration digest changed"
            )
        }
    }

    private static func validateWorktreePathAfterBranchDeletion(
        _ expected: RepositoryIdentity,
        rootPath: String
    ) throws {
        guard rootPath.hasPrefix("/"),
              !rootPath.contains("\n"),
              !rootPath.contains("\r"),
              !rootPath.contains("\0") else {
            throw GitSafetyError.unsafeRepository(
                "Branch deletion worktree path is invalid"
            )
        }
        let rootFD = Darwin.open(
            rootPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
                | O_CLOEXEC
        )
        guard rootFD >= 0 else {
            throw GitSafetyError.unsafeRepository(
                "Branch deletion worktree open failed"
            )
        }
        defer { close(rootFD) }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0,
              FileIdentity(rootInfo).matchesStableNode(
                expected.root
              ) else {
            throw GitSafetyError.unsafeRepository(
                "Branch deletion worktree identity changed"
            )
        }
        let markerFD = openat(
            rootFD,
            ".git",
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard markerFD >= 0 else {
            throw GitSafetyError.unsafeRepository(
                "Branch deletion Git marker open failed"
            )
        }
        defer { close(markerFD) }
        var markerInfo = stat()
        guard fstat(markerFD, &markerInfo) == 0,
              FileIdentity(markerInfo).matchesStableNode(
                expected.worktreeMarker
              ),
              expected.worktreeMarkerSize == nil
                || (
                    Int64(markerInfo.st_size)
                        == expected.worktreeMarkerSize
                        && Int64(
                            markerInfo.st_mtimespec.tv_sec
                        )
                            == expected
                                .worktreeMarkerModifiedSeconds
                        && Int64(
                            markerInfo.st_mtimespec.tv_nsec
                        )
                            == expected
                                .worktreeMarkerModifiedNanoseconds
                ) else {
            throw GitSafetyError.unsafeRepository(
                "Branch deletion Git marker changed"
            )
        }
    }

    private static func removingBranchSection(
        from data: Data,
        branchName: String
    ) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let lines = text.components(
            separatedBy: "\n"
        )
        var output: [String] = []
        var removing = false
        var found = false
        for (index, line) in lines.enumerated() {
            if index == lines.count - 1,
               line.isEmpty,
               text.hasSuffix("\n") {
                output.append(line)
                continue
            }
            if let section = configurationSection(line) {
                removing =
                    section.name == "branch"
                    && section.subsection == branchName
                found = found || removing
                if removing {
                    continue
                }
            }
            if !removing {
                output.append(line)
            }
        }
        guard found else { return nil }
        return Data(
            output.joined(separator: "\n").utf8
        )
    }

    private static func configurationSection(
        _ line: String
    ) -> (name: String, subsection: String?)? {
        let trimmed = line.trimmingCharacters(
            in: .whitespaces
        )
        guard trimmed.first == "[",
              let close = trimmed.firstIndex(of: "]") else {
            return nil
        }
        let trailing = trimmed[
            trimmed.index(after: close)...
        ].trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty
                || trailing.hasPrefix("#")
                || trailing.hasPrefix(";") else {
            return nil
        }
        let bodyStart = trimmed.index(
            after: trimmed.startIndex
        )
        let body = String(
            trimmed[bodyStart..<close]
        ).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        if let quote = body.firstIndex(of: "\"") {
            let name = String(body[..<quote])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let encoded = body[
                body.index(after: quote)...
            ]
            guard encoded.last == "\"" else {
                return nil
            }
            let subsection = String(
                encoded.dropLast()
            )
            return (
                name,
                decodeConfigurationSubsection(
                    subsection
                )
            )
        }
        if let dot = body.firstIndex(of: ".") {
            return (
                String(body[..<dot]).lowercased(),
                String(body[body.index(after: dot)...])
            )
        }
        return (body.lowercased(), nil)
    }

    private static func decodeConfigurationSubsection(
        _ value: String
    ) -> String? {
        var result = ""
        var escaping = false
        for character in value {
            if escaping {
                guard character == "\\"
                        || character == "\"" else {
                    return nil
                }
                result.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return escaping ? nil : result
    }

    private static func openValidatedCommonDirectory(
        _ expected: RepositoryIdentity
    ) throws -> Int32 {
        guard expected.commonDirectoryPath.hasPrefix("/"),
              !expected.commonDirectoryPath.contains("\n"),
              !expected.commonDirectoryPath.contains("\r"),
              !expected.commonDirectoryPath.contains("\0") else {
            throw GitSafetyError.unsafeRepository(
                "common Git directory path is invalid"
            )
        }
        let components = expected.commonDirectoryPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw GitSafetyError.unsafeRepository("cannot open common directory root") }
        defer { close(root) }
        guard components.first == "", let parent = try noFollowParent(components: Array(components.dropFirst()), directory: root),
              let leaf = components.last else { throw GitSafetyError.unsafeRepository("common directory parent missing") }
        let descriptor = openat(parent.value, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw GitSafetyError.unsafeRepository(
                "child common Git directory open failed"
            )
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              FileIdentity(info).matchesStableNode(
                  expected.gitDirectory
              ),
              (try? descriptorPath(descriptor))
                == expected.commonDirectoryPath else {
            close(descriptor)
            throw GitSafetyError.unsafeRepository(
                "child common Git directory identity changed"
            )
        }
        return descriptor
    }

    public func validateExecutionSnapshot(
        _ snapshot: RepositoryExecutionSnapshot,
        account: EffectiveAccount,
        requirePackedIdentity: Bool
    ) throws {
        #if !SHADOW_SYNC_TESTING
        throw SystemGitConfigurationError.unavailable
        #else
        try validateExecutionSnapshot(snapshot, account: account, requirePackedIdentity: requirePackedIdentity,
                                      systemPath: nil)
        #endif
    }

    func validateExecutionSnapshot(_ snapshot: RepositoryExecutionSnapshot, account: EffectiveAccount,
                                   requirePackedIdentity: Bool, frozenConfiguration: FrozenGitConfiguration) throws {
        if let preflight = frozenConfiguration.retainedPreflight,
           let probe = frozenConfiguration.retainedProbe {
            try probe.validateRetainedEvidence(account: account)
            try preflight.validate(snapshot, account: account)
            guard snapshot.configuration == frozenConfiguration.snapshot else {
                throw SystemGitConfigurationError.unavailable
            }
            try Self.validateFrozenConfiguration(descriptor: frozenConfiguration.descriptor,
                directoryDescriptor: frozenConfiguration.directoryDescriptor, snapshot: frozenConfiguration.snapshot)
            try validateExecutionSnapshot(snapshot, account: account, requirePackedIdentity: requirePackedIdentity,
                                          systemPath: { preflight.systemPath })
            try probe.validateRetainedEvidence(account: account)
            return
        }
        #if SHADOW_SYNC_TESTING
        try validateExecutionSnapshot(snapshot, account: account, requirePackedIdentity: requirePackedIdentity)
        #else
        throw SystemGitConfigurationError.unavailable
        #endif
    }

    func validateExecutionSnapshot(_ snapshot: RepositoryExecutionSnapshot, account: EffectiveAccount,
                                   requirePackedIdentity: Bool, configurationProbe: SystemGitConfigurationProbe) throws {
        try configurationProbe.validate(account: account)
        try validateExecutionSnapshot(snapshot, account: account, requirePackedIdentity: requirePackedIdentity,
            systemPath: { try configurationProbe.activePath(account: account) })
        try configurationProbe.validate(account: account)
    }

    private func validateExecutionSnapshot(_ snapshot: RepositoryExecutionSnapshot, account: EffectiveAccount,
                                          requirePackedIdentity: Bool, systemPath: (() throws -> String?)?) throws {
        try revalidate()
        _ = try Self.captureConfigurationManifest(
            account: account,
            repositoryDirectory: gitDescriptor.value,
            frozen: snapshot.configuration,
            systemPath: systemPath
        )
        try Self.validateGraphState(
            directory: gitDescriptor.value,
            expectedPackedRefs: snapshot.packedRefs,
            requirePackedIdentity: requirePackedIdentity
        )
    }

    public static func validateFrozenConfiguration(
        descriptor: Int32,
        directoryDescriptor: Int32,
        snapshot: GitConfigurationSnapshot
    ) throws {
        var pathInfo = stat()
        var descriptorInfo = stat()
        var relativeInfo = stat()
        var directoryPathInfo = stat()
        var directoryDescriptorInfo = stat()
        guard lstat(snapshot.frozenPath, &pathInfo) == 0,
              fstat(descriptor, &descriptorInfo) == 0,
              fstatat(directoryDescriptor, "config", &relativeInfo, AT_SYMLINK_NOFOLLOW) == 0,
              lstat(snapshot.frozenDirectoryPath, &directoryPathInfo) == 0,
              fstat(directoryDescriptor, &directoryDescriptorInfo) == 0,
              FileIdentity(pathInfo) == snapshot.frozenIdentity,
              FileIdentity(descriptorInfo) == snapshot.frozenIdentity,
              FileIdentity(relativeInfo) == snapshot.frozenIdentity,
              FileIdentity(directoryPathInfo) == snapshot.frozenDirectoryIdentity,
              FileIdentity(directoryDescriptorInfo) == snapshot.frozenDirectoryIdentity,
              pathInfo.st_uid == geteuid(),
              pathInfo.st_nlink == 1,
              (pathInfo.st_mode & 0o777) == 0o600,
              (pathInfo.st_flags & UInt32(UF_IMMUTABLE)) != 0,
              directoryPathInfo.st_uid == geteuid(),
              (directoryPathInfo.st_mode & 0o777) == 0o700,
              (directoryPathInfo.st_flags & UInt32(UF_IMMUTABLE)) != 0,
              snapshot.frozenPath
                == snapshot.frozenDirectoryPath + "/config",
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw GitSafetyError.unsafeRepository("frozen Git config path identity changed")
        }
        // dup/spawn retains the same open file description. Validation may run
        // while a target reads its inherited copy, so never change that shared
        // offset with lseek/read. Immutable bytes remain bounded and rechecked.
        guard snapshot.frozenSize >= 0, snapshot.frozenSize <= 1_572_864,
              descriptorInfo.st_size == Int64(snapshot.frozenSize) else {
            throw GitSafetyError.unsafeRepository("frozen Git configuration size changed")
        }
        var bytes = Data(count: snapshot.frozenSize)
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = pread(descriptor, buffer.baseAddress!.advanced(by: offset),
                                  buffer.count - offset, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw GitSafetyError.unsafeRepository("frozen Git configuration read failed")
                }
                offset += count
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, FileIdentity(after) == snapshot.frozenIdentity,
              after.st_size == descriptorInfo.st_size,
              after.st_flags & UInt32(UF_IMMUTABLE) != 0,
              sha256(bytes) == snapshot.frozenSHA256 else {
            throw GitSafetyError.unsafeRepository("frozen Git configuration changed")
        }
    }

    public static func cleanupFrozenConfiguration(
        descriptor: Int32,
        directoryDescriptor: Int32,
        snapshot: GitConfigurationSnapshot
    ) throws {
        try validateFrozenConfiguration(
            descriptor: descriptor,
            directoryDescriptor: directoryDescriptor,
            snapshot: snapshot
        )
        guard fchflags(directoryDescriptor, 0) == 0,
              fchflags(descriptor, 0) == 0,
              unlinkat(directoryDescriptor, "config", 0) == 0 else {
            throw SecureStateError.systemCall("remove frozen Git config", errno)
        }
        guard rmdir(snapshot.frozenDirectoryPath) == 0 else {
            throw SecureStateError.systemCall("remove frozen Git config directory", errno)
        }
    }

    private static func readBounded(fd: Int32, maximumBytes: Int) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0, info.st_size <= maximumBytes else {
            throw GitSafetyError.malformedConfig("config exceeds size limit")
        }
        var data = Data(count: Int(info.st_size))
        let count: Int = try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                return 0
            }
            var offset = 0
            while offset < raw.count {
                let amount = Darwin.read(fd, base.advanced(by: offset), raw.count - offset)
                if amount < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw GitSafetyError.malformedConfig("config read failed")
                }
                if amount == 0 {
                    break
                }
                offset += amount
            }
            return offset
        }
        data.count = count
        return data
    }

    private static func validateGraphState(
        directory: Int32,
        expectedPackedRefs: PackedRefsSnapshot,
        requirePackedIdentity: Bool
    ) throws {
        for path in [
            "refs/replace",
            "info/grafts",
            "objects/info/alternates",
            "config.worktree",
            "commondir",
        ] {
            try requireAbsent(relativePath: path, directory: directory)
        }
        let packed = try capturePackedRefs(directory: directory)
        guard packed.containsNoReplacementRefs else {
            throw GitSafetyError.replacementOrGraft
        }
        guard !requirePackedIdentity || packed == expectedPackedRefs else {
            throw GitSafetyError.unsafeRepository("packed refs changed before Git execution")
        }
    }

    /// Retain every intermediate component with O_NOFOLLOW. AT_SYMLINK_NOFOLLOW
    /// on a multi-component leaf alone would still traverse an ancestor alias.
    /// Returning nil means an actually absent component, never a traversal error.
    private static func noFollowParent(components: [String], directory: Int32) throws -> OwnedFileDescriptor? {
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".."
            && !$0.utf8.contains(where: { $0 < 32 || $0 == 127 }) && !$0.contains("/") }) else {
            throw GitSafetyError.unsafeRepository("invalid Git resource components")
        }
        let copy = fcntl(directory, F_DUPFD_CLOEXEC, 201)
        guard copy >= 0 else { throw GitSafetyError.unsafeRepository("cannot retain Git resource parent") }
        var parent = OwnedFileDescriptor(copy)
        for component in components.dropLast() {
            let child = openat(parent.value, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child < 0, errno == ENOENT { return nil }
            guard child >= 0 else { throw GitSafetyError.unsafeRepository("cannot traverse Git resource without following links") }
            parent = OwnedFileDescriptor(child)
        }
        return parent
    }

    /// Check only the final entry after each ancestor has been opened without
    /// following links. Missing ancestors mean absent metadata; aliases and
    /// traversal failures are refusals, never an absent/busy success shortcut.
    private static func metadataEntryExistsWithoutFollowingLinks(_ path: String, directory: Int32) throws -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let parent = try noFollowParent(components: parts, directory: directory),
              let leaf = parts.last else { return false }
        var value = stat()
        if fstatat(parent.value, leaf, &value, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw GitSafetyError.unsafeRepository("cannot inspect Git metadata entry") }
        return false
    }

    private static func requireAbsent(relativePath: String, directory: Int32) throws {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let parent = try noFollowParent(components: parts, directory: directory), let leaf = parts.last else { return }
        var value = stat()
        if fstatat(parent.value, leaf, &value, AT_SYMLINK_NOFOLLOW) == 0 {
            if relativePath == "config.worktree" {
                throw GitSafetyError.malformedConfig(".git/config.worktree is unsupported in M1")
            }
            throw GitSafetyError.replacementOrGraft
        }
        guard errno == ENOENT else {
            throw GitSafetyError.unsafeRepository("cannot inspect \(relativePath)")
        }
    }

    private struct CapturedFileData {
        let digest: GitFileDigest
        let contents: Data
    }

    private static func captureOptionalFile(
        path: String,
        directory: Int32,
        displayPath: String,
        maximumBytes: Int,
        allowedOwners: Set<uid_t>
    ) throws -> CapturedFileData? {
        var pathInfo = stat()
        guard fstatat(directory, path, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw GitSafetyError.unsafeRepository("cannot inspect \(displayPath)")
        }
        guard FileIdentity(pathInfo).isRegular,
              pathInfo.st_nlink == 1,
              allowedOwners.contains(pathInfo.st_uid) else {
            throw GitSafetyError.unsafeRepository("\(displayPath) owner, type, or links")
        }
        let fd = openat(directory, path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw GitSafetyError.unsafeRepository("cannot open \(displayPath)")
        }
        defer { close(fd) }
        var descriptorInfo = stat()
        guard fstat(fd, &descriptorInfo) == 0,
              FileIdentity(descriptorInfo) == FileIdentity(pathInfo) else {
            throw GitSafetyError.unsafeRepository("\(displayPath) changed while opening")
        }
        let contents = try readBounded(fd: fd, maximumBytes: maximumBytes)
        return CapturedFileData(
            digest: fileDigest(path: displayPath, info: descriptorInfo, contents: contents),
            contents: contents
        )
    }

    private static func captureRequiredFile(
        path: String,
        directory: Int32,
        displayPath: String,
        maximumBytes: Int,
        allowedOwners: Set<uid_t>
    ) throws -> CapturedFileData {
        guard let captured = try captureOptionalFile(
            path: path,
            directory: directory,
            displayPath: displayPath,
            maximumBytes: maximumBytes,
            allowedOwners: allowedOwners
        ) else {
            throw GitSafetyError.unsafeRepository("required \(displayPath) is absent")
        }
        return captured
    }

    private static func captureOptionalAbsoluteFile(
        path: String,
        maximumBytes: Int,
        allowedOwners: Set<uid_t>
    ) throws -> CapturedFileData? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.first == "" else { throw GitSafetyError.unsafeRepository("invalid absolute Git contributor") }
        let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw GitSafetyError.unsafeRepository("cannot open contributor root") }
        defer { close(root) }
        let parts = Array(components.dropFirst())
        guard let parent = try noFollowParent(components: parts, directory: root), let leaf = parts.last else { return nil }
        var pathInfo = stat()
        guard fstatat(parent.value, leaf, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw GitSafetyError.unsafeRepository("cannot inspect Git config contributor")
        }
        guard FileIdentity(pathInfo).isRegular, pathInfo.st_nlink == 1, allowedOwners.contains(pathInfo.st_uid) else {
            throw GitSafetyError.unsafeRepository("Git config contributor owner, type, or links")
        }
        let fd = openat(parent.value, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw GitSafetyError.unsafeRepository("cannot open Git config contributor") }
        defer { close(fd) }
        var descriptorInfo = stat()
        guard fstat(fd, &descriptorInfo) == 0,
              FileIdentity(descriptorInfo) == FileIdentity(pathInfo) else {
            throw GitSafetyError.unsafeRepository("Git config contributor changed while opening")
        }
        let contents = try readBounded(fd: fd, maximumBytes: maximumBytes)
        return CapturedFileData(
            digest: fileDigest(path: path, info: descriptorInfo, contents: contents),
            contents: contents
        )
    }

    private static func rejectIncludes(in data: Data, path: String) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitSafetyError.malformedConfig("\(path) is not bounded UTF-8")
        }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces).lowercased()
            if line.hasPrefix("[include") {
                throw GitSafetyError.malformedConfig("Git config includes are unsupported in M1")
            }
        }
    }

    private static func capturePackedRefs(directory: Int32) throws -> PackedRefsSnapshot {
        let captured = try captureOptionalFile(
            path: "packed-refs",
            directory: directory,
            displayPath: ".git/packed-refs",
            maximumBytes: 1_048_576,
            allowedOwners: [geteuid()]
        )
        let noReplacement = captured.map {
            !String(decoding: $0.contents, as: UTF8.self).contains(" refs/replace/")
        } ?? true
        return PackedRefsSnapshot(
            path: GitPathDigest(path: ".git/packed-refs", file: captured?.digest),
            containsNoReplacementRefs: noReplacement
        )
    }

    private static func fileDigest(
        path: String,
        info: stat,
        contents: Data
    ) -> GitFileDigest {
        GitFileDigest(
            path: path,
            identity: FileIdentity(info),
            size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            sha256: sha256(contents)
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func appendConfigBytes(_ bytes: Data, to result: inout Data) {
        result.append(bytes)
        if result.last != 0x0A {
            result.append(0x0A)
        }
    }

    private static func frozenSnapshotPrefix() throws -> String {
        #if SHADOW_SYNC_TESTING
        return try RuntimeFixtureSession.fixturePrefix("shadow-sync-fixture-config.")
        #else
        return "/private/tmp/shadow-sync-config."
        #endif
    }

    private static func recoverStaleSnapshots(admit: (([String]) throws -> Void)? = nil,
                                              revalidate: (() throws -> Void)? = nil,
                                              probe: SystemGitConfigurationProbe? = nil) throws {
        try admit?(["/private/tmp"])
        #if SHADOW_SYNC_TESTING
        try probe?.testingFrozenRecoveryBoundary?("root-admitted")
        #endif
        try revalidate?()
        #if SHADOW_SYNC_TESTING
        probe?.testingFrozenRecoveryAccess?("root-open")
        #endif
        let prefix = URL(fileURLWithPath: try frozenSnapshotPrefix()).lastPathComponent
        let temporaryFD = Darwin.open(
            "/private/tmp",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard temporaryFD >= 0 else {
            throw SecureStateError.systemCall("open snapshot recovery root", errno)
        }
        defer { close(temporaryFD) }
        let names = try directoryEntryNames(descriptor: temporaryFD, maximumEntries: 4096, revalidate: revalidate,
            probe: probe, recoveryAccess: "root-read")
        let candidates = names.filter { $0.hasPrefix(prefix) }
        guard candidates.count <= 256 else { throw SystemGitConfigurationError.unavailable }
        // Admit the entire bounded candidate set before opening any candidate;
        // a refusal therefore cannot partially delete an earlier stale entry.
        for name in candidates {
            let suffix = name.dropFirst(prefix.count)
            guard suffix.count == 6, suffix.utf8.allSatisfy({
                ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
            }) else { throw GitSafetyError.unsafeRepository("questionable frozen Git config recovery entry") }
            try admit?(["/private/tmp/" + name, "/private/tmp/" + name + "/config"])
        }
        #if SHADOW_SYNC_TESTING
        try probe?.testingFrozenRecoveryBoundary?("candidates-admitted")
        #endif
        for name in candidates {
            #if SHADOW_SYNC_TESTING
            try probe?.testingFrozenRecoveryBoundary?("candidate-open")
            #endif
            try revalidate?()
            // The whole-set check prevents partial deletion on an initial refusal;
            // this exact-path check grants access only under current admission.
            try admit?(["/private/tmp/" + name, "/private/tmp/" + name + "/config"])
            try revalidate?()
            let suffix = name.dropFirst(prefix.count)
            guard suffix.count == 6,
                  suffix.utf8.allSatisfy({
                      $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")
                          || $0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z")
                          || $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")
                  }) else {
                throw GitSafetyError.unsafeRepository(
                    "questionable frozen Git config recovery entry"
                )
            }
            #if SHADOW_SYNC_TESTING
            probe?.testingFrozenRecoveryAccess?("candidate-open")
            #endif
            let directoryFD = openat(
                temporaryFD,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard directoryFD >= 0 else {
                throw GitSafetyError.unsafeRepository(
                    "questionable frozen Git config recovery directory"
                )
            }
            defer { close(directoryFD) }
            var directoryInfo = stat()
            guard fstat(directoryFD, &directoryInfo) == 0,
                  FileIdentity(directoryInfo).isDirectory,
                  directoryInfo.st_uid == geteuid(),
                  (directoryInfo.st_mode & 0o777) == 0o700,
                  (directoryInfo.st_flags & UInt32(UF_IMMUTABLE)) != 0,
                  try directoryEntryNames(descriptor: directoryFD, revalidate: revalidate,
                      probe: probe, recoveryAccess: "candidate-read") == ["config"] else {
                throw GitSafetyError.unsafeRepository(
                    "questionable frozen Git config recovery shape"
                )
            }
            #if SHADOW_SYNC_TESTING
            try probe?.testingFrozenRecoveryBoundary?("config-open")
            #endif
            try revalidate?()
            #if SHADOW_SYNC_TESTING
            probe?.testingFrozenRecoveryAccess?("config-open")
            #endif
            let configFD = openat(directoryFD, "config", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard configFD >= 0 else {
                throw GitSafetyError.unsafeRepository(
                    "questionable frozen Git config recovery file"
                )
            }
            var configInfo = stat()
            guard fstat(configFD, &configInfo) == 0,
                  FileIdentity(configInfo).isRegular,
                  configInfo.st_uid == geteuid(),
                  configInfo.st_nlink == 1,
                  (configInfo.st_mode & 0o777) == 0o600,
                  (configInfo.st_flags & UInt32(UF_IMMUTABLE)) != 0 else {
                close(configFD)
                throw GitSafetyError.unsafeRepository(
                    "questionable frozen Git config recovery file shape"
                )
            }
            if flock(configFD, LOCK_EX | LOCK_NB) != 0 {
                let lockError = errno
                close(configFD)
                if lockError == EWOULDBLOCK || lockError == EAGAIN {
                    continue
                }
                throw SecureStateError.systemCall(
                    "lock stale frozen Git config",
                    lockError
                )
            }
            do {
                #if SHADOW_SYNC_TESTING
                try probe?.testingFrozenRecoveryBoundary?("candidate-delete")
                #endif
                try revalidate?()
                try admit?(["/private/tmp/" + name, "/private/tmp/" + name + "/config"])
                try revalidate?()
            } catch { close(configFD); throw error }
            #if SHADOW_SYNC_TESTING
            probe?.testingFrozenRecoveryAccess?("candidate-delete")
            #endif
            guard fchflags(directoryFD, 0) == 0,
                  fchflags(configFD, 0) == 0,
                  unlinkat(directoryFD, "config", 0) == 0 else {
                let removalError = errno
                close(configFD)
                throw SecureStateError.systemCall(
                    "recover stale frozen Git config",
                    removalError
                )
            }
            close(configFD)
            guard unlinkat(temporaryFD, name, AT_REMOVEDIR) == 0 else {
                throw SecureStateError.systemCall(
                    "recover stale frozen Git config directory",
                    errno
                )
            }
        }
    }

    private static func directoryEntryNames(descriptor: Int32, maximumEntries: Int = 4096,
                                            revalidate: (() throws -> Void)? = nil,
                                            probe: SystemGitConfigurationProbe? = nil,
                                            recoveryAccess: String? = nil) throws -> [String] {
        try revalidate?()
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 {
                close(duplicate)
            }
            throw SecureStateError.systemCall("read snapshot directory", errno)
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            #if SHADOW_SYNC_TESTING
            if let recoveryAccess { try probe?.testingFrozenRecoveryBoundary?(recoveryAccess) }
            #endif
            try revalidate?()
            #if SHADOW_SYNC_TESTING
            if let recoveryAccess { probe?.testingFrozenRecoveryAccess?(recoveryAccess) }
            #endif
            guard let entry = readdir(directory) else { break }
            guard names.count < maximumEntries else { throw SystemGitConfigurationError.unavailable }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(cString: $0) }
            }
            if name != "." && name != ".." {
                names.append(name)
            }
        }
        return names.sorted()
    }

    private static func makeRetainedSnapshot(
        contents: Data, admittedDirectory: String? = nil
    ) throws -> (
        descriptor: Int32,
        directoryDescriptor: Int32,
        path: String,
        directory: String
    ) {
        let directory: String
        if let admittedDirectory {
            guard mkdir(admittedDirectory, 0o700) == 0 else {
                throw SecureStateError.systemCall("create admitted frozen Git config directory", errno)
            }
            directory = admittedDirectory
        } else {
            var template = Array((try frozenSnapshotPrefix() + "XXXXXX").utf8CString)
            guard let created = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) else {
                throw SecureStateError.systemCall("mkdtemp frozen Git config", errno)
            }
            directory = String(cString: created)
        }
        guard chmod(directory, 0o700) == 0 else {
            _ = rmdir(directory)
            throw SecureStateError.systemCall("chmod frozen Git config directory", errno)
        }
        let directoryDescriptor = Darwin.open(
            directory,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            _ = rmdir(directory)
            throw SecureStateError.systemCall("open frozen Git config directory", errno)
        }
        let path = URL(fileURLWithPath: directory).appendingPathComponent("config").path
        let descriptor = openat(
            directoryDescriptor,
            "config",
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            close(directoryDescriptor)
            _ = rmdir(directory)
            throw SecureStateError.systemCall("create frozen Git config", errno)
        }
        do {
            guard fchmod(descriptor, 0o600) == 0 else {
                throw SecureStateError.systemCall("chmod frozen Git config", errno)
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw SecureStateError.systemCall("lock frozen Git config", errno)
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  FileIdentity(info).isRegular,
                  info.st_uid == geteuid(),
                  info.st_nlink == 1,
                  (info.st_mode & 0o777) == 0o600 else {
                throw GitSafetyError.unsafeRepository("frozen Git config tempfile is unsafe")
            }
            try writeAll(contents, descriptor: descriptor)
            guard fsync(descriptor) == 0,
                  fsync(directoryDescriptor) == 0,
                  lseek(descriptor, 0, SEEK_SET) >= 0,
                  fstat(descriptor, &info) == 0,
                  info.st_nlink == 1 else {
                throw SecureStateError.systemCall("seal frozen Git config", errno)
            }
            guard fchflags(descriptor, UInt32(UF_IMMUTABLE)) == 0,
                  fchflags(directoryDescriptor, UInt32(UF_IMMUTABLE)) == 0 else {
                throw SecureStateError.systemCall("protect frozen Git config", errno)
            }
            return (descriptor, directoryDescriptor, path, directory)
        } catch {
            _ = fchflags(directoryDescriptor, 0)
            _ = fchflags(descriptor, 0)
            _ = unlinkat(directoryDescriptor, "config", 0)
            close(descriptor)
            close(directoryDescriptor)
            _ = rmdir(directory)
            throw error
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                return
            }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    raw.count - offset
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw SecureStateError.systemCall("write frozen Git config", errno)
                }
                offset += count
            }
        }
    }

    private static func descriptorPath(_ descriptor: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
            throw GitSafetyError.unsafeRepository("opened repository path is unavailable")
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let path = String(bytes: bytes, encoding: .utf8),
              path.hasPrefix("/"),
              !path.contains("\n"),
              !path.contains("\r"),
              !path.contains("\0") else {
            throw GitSafetyError.unsafeRepository("opened repository path is invalid")
        }
        return path
    }
}

public enum ValidatedSSHAgentEnvironment {
    public static func socketPath(
        inherited: [String: String],
        accountUID: uid_t
    ) -> String? {
        guard accountUID == geteuid(),
              let path = inherited["SSH_AUTH_SOCK"],
              path.utf8.count < Int(PATH_MAX),
              path.hasPrefix("/"),
              !path.contains("\n"),
              !path.contains("\r"),
              !path.contains("\0") else {
            return nil
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == accountUID,
              access(path, W_OK) == 0 else {
            return nil
        }
        return path
    }
}

public enum ClosedGitEnvironment {
    public static let fixedPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    public static let fixedSSHCommand =
        "/usr/bin/ssh -oBatchMode=yes -oRequestTTY=no -oNumberOfPasswordPrompts=0"

    public static func make(
        account: EffectiveAccount,
        transport: GitTransport,
        frozenConfigPath: String = "/dev/fd/196",
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result = [
            "HOME": account.homeDirectory,
            "USER": account.username,
            "LOGNAME": account.username,
            "PATH": fixedPath,
            "LANG": "C",
            "LC_ALL": "C",
            "TMPDIR": "/private/tmp",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ASKPASS": "/usr/bin/false",
            "SSH_ASKPASS": "/usr/bin/false",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_CONFIG_GLOBAL": frozenConfigPath,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_GRAFT_FILE": "/dev/null",
        ]
        if transport == .ssh {
            result["GIT_SSH_COMMAND"] = fixedSSHCommand
            result["GIT_SSH_VARIANT"] = "ssh"
            if let socket = ValidatedSSHAgentEnvironment.socketPath(
                inherited: inherited,
                accountUID: account.uid
            ) {
                result["SSH_AUTH_SOCK"] = socket
            }
        }
        return result
    }
}

public struct CommandInvocation: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environmentKeys: [String]
    public let spawnArguments: [String]

    public init(
        executable: String,
        arguments: [String],
        environmentKeys: [String],
        spawnArguments: [String] = []
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environmentKeys = environmentKeys
        self.spawnArguments = spawnArguments
    }
}

public final class CommandAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CommandInvocation] = []

    public init() {}

    public func record(_ invocation: CommandInvocation) {
        lock.lock()
        storage.append(invocation)
        lock.unlock()
    }

    public var invocations: [CommandInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func withGitCStringArray<T>(
    _ values: [String],
    body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> T
) -> T {
    let pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
    defer {
        for pointer in pointers {
            free(pointer)
        }
    }
    var mutable = pointers
    mutable.append(nil)
    return mutable.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress)
    }
}
