import Darwin
import CryptoKit
import Foundation

enum RepositoryPolicyPathDisposition: Equatable, Sendable {
    case allowed
    case excluded
    case readOnlyReference
    case artifact
}

struct RepositoryPolicy: Equatable, Sendable {
    let excludedPaths: [String]
    let readOnlyPaths: [String]
    let artifactPaths: [String]
    let excludedOrigins: Set<String>
    let foreignHookMarkers: [String]
    let managedPreCommitDispatcher: Data
    let permanentNoTouchOrigins: Set<String>
    let writablePaths: [String]
    private let sourceAdmissionSHA256: String?

    init(excludedPaths: [String], readOnlyPaths: [String], artifactPaths: [String],
         excludedOrigins: Set<String>, foreignHookMarkers: [String],
         managedPreCommitDispatcher: Data) {
        self.excludedPaths = excludedPaths
        self.readOnlyPaths = readOnlyPaths
        self.artifactPaths = artifactPaths
        self.excludedOrigins = excludedOrigins
        self.foreignHookMarkers = foreignHookMarkers
        self.managedPreCommitDispatcher = managedPreCommitDispatcher
        permanentNoTouchOrigins = []
        writablePaths = ["."]
        sourceAdmissionSHA256 = nil
    }

    /// Projects already verified owner data. This is not permission to access
    /// a candidate: the AWA path decision still precedes every such access.
    init(snapshot: HostPolicySnapshot) throws {
        try snapshot.revalidate()
        let projection = snapshot.projection
        excludedPaths = projection.paths.excluded
        readOnlyPaths = projection.paths.readOnly
        artifactPaths = projection.paths.artifacts
        excludedOrigins = Set(projection.permanentNoTouchRepositoryIDs)
        foreignHookMarkers = projection.foreignHookMarkers
        managedPreCommitDispatcher = projection.hookDispatcher
        permanentNoTouchOrigins = Set(projection.permanentNoTouchRepositoryIDs)
        writablePaths = projection.paths.writable
        sourceAdmissionSHA256 = snapshot.admissionSHA256
    }

    func identityBlockReason(origin: GitHubIdentity?) -> RepositoryBlockReason? {
        guard let origin else { return nil }
        if permanentNoTouchOrigins.contains(origin.canonicalName) {
            return .permanentNoTouch
        }
        return excludedOrigins.contains(origin.canonicalName) ? .excludedByPolicy : nil
    }

    var admissionSHA256: String {
        if let sourceAdmissionSHA256 { return sourceAdmissionSHA256 }
        var snapshot = Data()
        for (label, values) in [
            ("excluded_paths", excludedPaths.sorted()),
            ("read_only_paths", readOnlyPaths.sorted()),
            ("artifact_paths", artifactPaths.sorted()),
            ("excluded_origins", excludedOrigins.sorted()),
            ("permanent_no_touch_origins", permanentNoTouchOrigins.sorted()),
            ("writable_paths", writablePaths.sorted()),
            ("foreign_hook_markers", foreignHookMarkers.sorted()),
        ] {
            Self.appendDigestField(label, to: &snapshot)
            for value in values {
                Self.appendDigestField(value, to: &snapshot)
            }
        }
        Self.appendDigestField(
            Self.sha256(managedPreCommitDispatcher),
            to: &snapshot
        )
        return Self.sha256(snapshot)
    }

    func hookAdmissionSHA256(
        repositoryPath: String
    ) -> String? {
        try? hookAdmissionSHA256(repositoryPath: repositoryPath, beforeAccess: { _ in })
    }

    func hookAdmissionRelativePaths() -> [String] {
        var relativePaths: Set<String> = [
            ".git/hooks",
            ".git/hooks/pre-commit",
            ".git/hooks/pre-commit.local",
        ]
        for marker in foreignHookMarkers {
            for name in [
                marker,
                ".\(marker)",
                "\(marker).yml",
                "\(marker).yaml",
                ".\(marker).yml",
                ".\(marker).yaml",
                ".\(marker)-config.yml",
                ".\(marker)-config.yaml",
            ] {
                relativePaths.insert(name)
            }
            if marker.lowercased() != "pre-commit" {
                relativePaths.insert(".git/hooks/\(marker)")
            }
        }

        return relativePaths.sorted()
    }

    func hookAdmissionSHA256(repositoryPath: String,
                             beforeAccess: (String) throws -> Void) throws -> String? {
        var snapshot = Data()
        for relativePath in hookAdmissionRelativePaths() {
            Self.appendDigestField(relativePath, to: &snapshot)
            let path = repositoryPath + "/" + relativePath
            try beforeAccess(path)
            var info = stat()
            if lstat(path, &info) == 0 {
                for value in [
                    UInt64(info.st_dev),
                    UInt64(info.st_ino),
                    UInt64(info.st_uid),
                    UInt64(info.st_mode),
                    UInt64(info.st_nlink),
                    UInt64(bitPattern: Int64(info.st_size)),
                    UInt64(bitPattern: Int64(info.st_mtimespec.tv_sec)),
                    UInt64(bitPattern: Int64(info.st_mtimespec.tv_nsec)),
                ] {
                    var bigEndian = value.bigEndian
                    withUnsafeBytes(of: &bigEndian) {
                        snapshot.append(contentsOf: $0)
                    }
                }
            } else if errno == ENOENT {
                Self.appendDigestField("absent", to: &snapshot)
            } else {
                return nil
            }
        }
        return Self.sha256(snapshot)
    }

    func pathDisposition(
        relativePath: String
    ) -> RepositoryPolicyPathDisposition {
        if artifactPaths.contains(where: {
            Self.matches(relativePath, pattern: $0)
        }) {
            return .artifact
        }
        if writablePaths.contains(relativePath) {
            return .allowed
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
        return .allowed
    }

    func excludes(relativePath: String, origin: GitHubIdentity?) -> Bool {
        if pathDisposition(relativePath: relativePath) != .allowed {
            return true
        }
        if let origin, excludedOrigins.contains(origin.canonicalName) {
            return true
        }
        return false
    }

    func hasUnsupportedHookMarker(repositoryPath: String) -> Bool {
        for marker in foreignHookMarkers {
            let names = [
                marker,
                ".\(marker)",
                "\(marker).yml",
                "\(marker).yaml",
                ".\(marker).yml",
                ".\(marker).yaml",
                ".\(marker)-config.yml",
                ".\(marker)-config.yaml",
            ]
            for name in names {
                let path = URL(fileURLWithPath: repositoryPath)
                    .appendingPathComponent(name).path
                var info = stat()
                if lstat(path, &info) == 0 {
                    return true
                }
                if errno != ENOENT {
                    return true
                }
            }
            if marker.lowercased() == "pre-commit" {
                continue
            }
            let installedHook = URL(fileURLWithPath: repositoryPath)
                .appendingPathComponent(".git/hooks/\(marker)").path
            var hookInfo = stat()
            if lstat(installedHook, &hookInfo) == 0 || errno != ENOENT {
                return true
            }
        }
        if foreignHookMarkers.contains(where: {
            $0.lowercased() == "pre-commit"
        }), hasUnsupportedPreCommit(repositoryPath: repositoryPath) {
            return true
        }
        let configPath = URL(fileURLWithPath: repositoryPath)
            .appendingPathComponent(".git/config").path
        var configInfo = stat()
        if lstat(configPath, &configInfo) != 0 {
            return errno != ENOENT
        }
        guard (configInfo.st_mode & S_IFMT) == S_IFREG,
              configInfo.st_uid == geteuid(),
              configInfo.st_nlink == 1,
              configInfo.st_size >= 0,
              configInfo.st_size <= 1_048_576,
              let config = try? String(contentsOfFile: configPath, encoding: .utf8)
        else {
            return true
        }
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard line.hasPrefix("hookspath") else {
                continue
            }
            if foreignHookMarkers.contains(where: { line.contains($0.lowercased()) }) {
                return true
            }
        }
        return false
    }

    private func hasUnsupportedPreCommit(repositoryPath: String) -> Bool {
        let gitDirectory = Darwin.open(
            repositoryPath + "/.git",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard gitDirectory >= 0 else {
            return true
        }
        defer { close(gitDirectory) }
        let hooksDirectory = openat(
            gitDirectory,
            "hooks",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if hooksDirectory < 0, errno == ENOENT {
            return false
        }
        guard hooksDirectory >= 0 else {
            return true
        }
        defer { close(hooksDirectory) }
        var hooksInfo = stat()
        guard fstat(hooksDirectory, &hooksInfo) == 0,
              FileIdentity(hooksInfo).isDirectory,
              hooksInfo.st_uid == geteuid(),
              (hooksInfo.st_mode & 0o022) == 0 else {
            return true
        }
        let preCommit = openat(
            hooksDirectory,
            "pre-commit",
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if preCommit < 0, errno == ENOENT {
            return false
        }
        guard preCommit >= 0 else {
            return true
        }
        defer { close(preCommit) }
        guard isExactManagedPreCommit(descriptor: preCommit) else {
            return true
        }
        var chainedInfo = stat()
        return fstatat(
            hooksDirectory,
            "pre-commit.local",
            &chainedInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0 || errno != ENOENT
    }

    private func isExactManagedPreCommit(descriptor: Int32) -> Bool {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              FileIdentity(info).isRegular,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o111) != 0,
              (info.st_mode & 0o022) == 0,
              info.st_size == managedPreCommitDispatcher.count else {
            return false
        }
        let initialIdentity = RepositoryMetadataFileIdentity(info)
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while bytes.count <= managedPreCommitDispatcher.count {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                bytes.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count == 0 else {
                return false
            }
            var finalInfo = stat()
            return fstat(descriptor, &finalInfo) == 0
                && RepositoryMetadataFileIdentity(finalInfo)
                    == initialIdentity
                && bytes == managedPreCommitDispatcher
        }
        return false
    }

    private static func matches(_ relativePath: String, pattern: String) -> Bool {
        if pattern == "." {
            return relativePath == "."
        }
        if pattern.hasSuffix("/*") {
            let prefix = String(pattern.dropLast(2))
            return relativePath == prefix || relativePath.hasPrefix(prefix + "/")
        }
        return relativePath == pattern
    }

    private static func appendDigestField(
        _ value: String,
        to data: inout Data
    ) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) {
            data.append(contentsOf: $0)
        }
        data.append(bytes)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

enum OperationHookEvidence {
    static func updateRefSHA256(
        hooksDirectory: String,
        account: EffectiveAccount
    ) -> String? {
        guard hooksDirectory.hasPrefix("/"),
              hooksDirectory.hasPrefix(
                  account.homeDirectory + "/"
              ),
              !hooksDirectory.contains("\0"),
              !hooksDirectory.contains("\n"),
              !hooksDirectory.contains("\r") else {
            return nil
        }
        let hooks = Darwin.open(
            hooksDirectory,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard hooks >= 0 else { return nil }
        defer { Darwin.close(hooks) }
        var directoryInfo = stat()
        guard fstat(hooks, &directoryInfo) == 0,
              FileIdentity(directoryInfo).isDirectory,
              directoryInfo.st_uid == account.uid,
              (directoryInfo.st_mode & 0o022) == 0,
              descriptorPath(hooks) == hooksDirectory else {
            return nil
        }

        var snapshot = Data()
        append(hooksDirectory, to: &snapshot)
        append("reference-transaction", to: &snapshot)
        let hook = openat(
            hooks,
            "reference-transaction",
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if hook < 0 {
            guard errno == ENOENT else { return nil }
            append("absent", to: &snapshot)
            return sha256(snapshot)
        }
        defer { Darwin.close(hook) }
        var before = stat()
        guard fstat(hook, &before) == 0,
              FileIdentity(before).isRegular,
              before.st_uid == account.uid,
              before.st_nlink == 1,
              (before.st_mode & 0o022) == 0,
              before.st_size >= 0,
              before.st_size <= 1_048_576 else {
            return nil
        }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while bytes.count <= 1_048_576 {
            let count = Darwin.read(hook, &buffer, buffer.count)
            if count > 0 {
                bytes.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                break
            } else if errno != EINTR {
                return nil
            }
        }
        var after = stat()
        var named = stat()
        guard bytes.count <= 1_048_576,
              fstat(hook, &after) == 0,
              fstatat(
                  hooks,
                  "reference-transaction",
                  &named,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              sameSnapshot(before, after),
              sameSnapshot(before, named) else {
            return nil
        }
        append(before, to: &snapshot)
        append(sha256(bytes), to: &snapshot)
        return sha256(snapshot)
    }

    private static func descriptorPath(_ descriptor: Int32)
        -> String? {
        var buffer = [CChar](
            repeating: 0,
            count: Int(MAXPATHLEN)
        )
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0,
              let terminator = buffer.firstIndex(of: 0) else {
            return nil
        }
        return String(
            bytes: buffer[..<terminator].map {
                UInt8(bitPattern: $0)
            },
            encoding: .utf8
        )
    }

    private static func sameSnapshot(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_uid == rhs.st_uid
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
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

    private static func append(
        _ info: stat,
        to data: inout Data
    ) {
        for value in [
            UInt64(info.st_dev),
            UInt64(info.st_ino),
            UInt64(info.st_uid),
            UInt64(info.st_mode),
            UInt64(info.st_nlink),
            UInt64(bitPattern: Int64(info.st_size)),
            UInt64(bitPattern: Int64(info.st_mtimespec.tv_sec)),
            UInt64(bitPattern: Int64(info.st_mtimespec.tv_nsec)),
            UInt64(bitPattern: Int64(info.st_ctimespec.tv_sec)),
            UInt64(bitPattern: Int64(info.st_ctimespec.tv_nsec)),
        ] {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) {
                data.append(contentsOf: $0)
            }
        }
    }

    private static func append(
        _ value: String,
        to data: inout Data
    ) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) {
            data.append(contentsOf: $0)
        }
        data.append(bytes)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

enum RepositoryPolicyLoader {
    static func load(rootPath: String) throws -> RepositoryPolicy {
        #if SHADOW_SYNC_TESTING
        let worktreePolicy = try readOwnedBoundedFile(
            URL(fileURLWithPath: rootPath)
                .appendingPathComponent("_ops/policy/worktree-policy.yml").path,
            maximumBytes: 262_144
        )
        let baselineClassifier = try readOwnedBoundedFile(
            URL(fileURLWithPath: rootPath)
                .appendingPathComponent("_ops/bin/baseline-lib.sh").path,
            maximumBytes: 1_048_576
        )
        let hookInstaller = try readOwnedBoundedFile(
            URL(fileURLWithPath: rootPath)
                .appendingPathComponent("_ops/bin/install-identity-guard.sh").path,
            maximumBytes: 262_144
        )
        let parsed = try parseWorktreePolicy(worktreePolicy)
        let origins = try parseBaselineOrigins(baselineClassifier)
        let managedDispatcher = try parseManagedPreCommitDispatcher(hookInstaller)
        guard !origins.isEmpty else {
            throw M1RepositoryDiscoveryError.policyUnavailable
        }
        return RepositoryPolicy(
            excludedPaths: Array(Set(parsed.excludedPaths)).sorted(),
            readOnlyPaths: Array(Set(parsed.readOnlyPaths)).sorted(),
            artifactPaths: Array(Set(parsed.artifactPaths)).sorted(),
            excludedOrigins: origins,
            foreignHookMarkers: Array(Set(parsed.foreignHookMarkers)).sorted(),
            managedPreCommitDispatcher: managedDispatcher
        )
        #else
        // Source-bound host scripts are not production policy authority.
        // Callers must migrate to a publisher-qualified HostPolicySnapshot.
        throw M1RepositoryDiscoveryError.policyUnavailable
        #endif
    }

    #if SHADOW_SYNC_TESTING
    static func load(
        worktreePolicy: Data,
        baselineClassifier: Data,
        hookInstaller: Data
    ) throws -> RepositoryPolicy {
        let parsed = try parseWorktreePolicy(worktreePolicy)
        let origins = try parseBaselineOrigins(baselineClassifier)
        let managedDispatcher = try parseManagedPreCommitDispatcher(hookInstaller)
        guard !origins.isEmpty else {
            throw M1RepositoryDiscoveryError.policyUnavailable
        }
        return RepositoryPolicy(
            excludedPaths: Array(Set(parsed.excludedPaths)).sorted(),
            readOnlyPaths: Array(Set(parsed.readOnlyPaths)).sorted(),
            artifactPaths: Array(Set(parsed.artifactPaths)).sorted(),
            excludedOrigins: origins,
            foreignHookMarkers: Array(Set(parsed.foreignHookMarkers)).sorted(),
            managedPreCommitDispatcher: managedDispatcher
        )
    }
    #endif

    private struct ParsedWorktreePolicy {
        let excludedPaths: [String]
        let readOnlyPaths: [String]
        let artifactPaths: [String]
        let foreignHookMarkers: [String]
    }

    private static func parseWorktreePolicy(_ data: Data) throws -> ParsedWorktreePolicy {
        guard data.count <= 262_144,
              let text = String(data: data, encoding: .utf8),
              !text.contains("\t"),
              text.split(whereSeparator: \.isNewline).contains(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "version: 1"
              }),
              text.split(whereSeparator: \.isNewline).contains(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "default: include"
              }) else {
            throw M1RepositoryDiscoveryError.policyUnavailable
        }
        var section: String?
        var subsection: String?
        var excluded: [String] = []
        var readOnly: [String] = []
        var artifacts: [String] = []
        var hooks: [String] = []
        var governedRoot = false
        let supportedTopLevel = Set([
            "version", "governed_roots", "managed_location", "modes_file",
            "default", "include", "exclude", "detectors", "overrides",
        ])
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            let indentation = line.prefix { $0 == " " }.count
            if indentation == 0 {
                guard let separator = trimmed.firstIndex(of: ":") else {
                    throw M1RepositoryDiscoveryError.policyUnavailable
                }
                let key = String(trimmed[..<separator])
                guard supportedTopLevel.contains(key) else {
                    throw M1RepositoryDiscoveryError.policyUnavailable
                }
                section = key
                subsection = nil
                continue
            }
            if indentation == 2, trimmed.hasSuffix(":"), section == "detectors" {
                subsection = String(trimmed.dropLast())
                guard [
                    "governed_markers",
                    "foreign_hook_frameworks",
                    "read_only_paths",
                    "artifact_paths",
                ]
                    .contains(subsection!) else {
                    throw M1RepositoryDiscoveryError.policyUnavailable
                }
                continue
            }
            if indentation == 2, section == "overrides" {
                guard trimmed == "include: []" || trimmed == "exclude: []" else {
                    throw M1RepositoryDiscoveryError.policyUnavailable
                }
                continue
            }
            guard trimmed.hasPrefix("- ") else {
                continue
            }
            let value = String(trimmed.dropFirst(2))
            guard !value.isEmpty,
                  !value.contains(".."),
                  !value.hasPrefix("/") else {
                throw M1RepositoryDiscoveryError.policyUnavailable
            }
            if section == "governed_roots", value == "~/dev" {
                governedRoot = true
            } else if section == "exclude" {
                guard supportedPathPattern(value) else {
                    throw M1RepositoryDiscoveryError.policyUnavailable
                }
                excluded.append(value)
            } else if section == "detectors", subsection == "read_only_paths" {
                guard supportedPathPattern(value) else {
                    throw M1RepositoryDiscoveryError.policyUnavailable
                }
                readOnly.append(value)
            } else if section == "detectors", subsection == "artifact_paths" {
                guard value != ".",
                      supportedPathPattern(value) else {
                    throw M1RepositoryDiscoveryError.policyUnavailable
                }
                artifacts.append(value)
            } else if section == "detectors", subsection == "foreign_hook_frameworks" {
                hooks.append(value)
            }
        }
        guard governedRoot, !excluded.isEmpty, !hooks.isEmpty else {
            throw M1RepositoryDiscoveryError.policyUnavailable
        }
        guard Set(artifacts).count == artifacts.count,
              !artifactsContainAmbiguity(
                  artifacts,
                  safetyPaths: excluded + readOnly
              ) else {
            throw M1RepositoryDiscoveryError.policyUnavailable
        }
        return ParsedWorktreePolicy(
            excludedPaths: excluded,
            readOnlyPaths: readOnly,
            artifactPaths: artifacts,
            foreignHookMarkers: hooks
        )
    }

    private static func supportedPathPattern(_ value: String) -> Bool {
        if value == "." {
            return true
        }
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              !value.contains("\\"),
              !value.contains("//"),
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              value.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({
                    !$0.isEmpty && $0 != "." && $0 != ".."
                }),
              !value.contains("?"),
              !value.contains("["),
              !value.contains("]") else {
            return false
        }
        let stars = value.filter { $0 == "*" }.count
        return stars == 0 || (stars == 1 && value.hasSuffix("/*"))
    }

    private static func artifactsContainAmbiguity(
        _ artifacts: [String],
        safetyPaths: [String]
    ) -> Bool {
        for (index, artifact) in artifacts.enumerated() {
            if safetyPaths.contains(where: {
                patternsOverlap(artifact, $0)
            }) {
                return true
            }
            if artifacts.dropFirst(index + 1).contains(where: {
                patternsOverlap(artifact, $0)
            }) {
                return true
            }
        }
        return false
    }

    private static func patternsOverlap(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        let left = lhs.hasSuffix("/*")
            ? String(lhs.dropLast(2))
            : lhs
        let right = rhs.hasSuffix("/*")
            ? String(rhs.dropLast(2))
            : rhs
        return left == right
            || left.hasPrefix(right + "/")
            || right.hasPrefix(left + "/")
    }

    private static func parseBaselineOrigins(_ data: Data) throws -> Set<String> {
        guard data.count <= 1_048_576,
              let text = String(data: data, encoding: .utf8),
              text.contains("bl_classify_repo()") else {
            throw M1RepositoryDiscoveryError.policyUnavailable
        }
        let expression = try NSRegularExpression(
            pattern: #"\[\s+"\$ownerrepo_lc"\s+=\s+"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)"\s+\]"#
        )
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var values: Set<String> = []
        for match in expression.matches(in: text, range: range) {
            guard let valueRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            values.insert(String(text[valueRange]).lowercased())
        }
        return values
    }

    private static func parseManagedPreCommitDispatcher(
        _ data: Data
    ) throws -> Data {
        guard data.count <= 262_144,
              let text = String(data: data, encoding: .utf8) else {
            throw M1RepositoryDiscoveryError.policyUnavailable
        }
        let markerLines = text.split(whereSeparator: \.isNewline).compactMap {
            line -> String? in
            let value = String(line)
            let prefix = "MARKER='"
            guard value.hasPrefix(prefix), value.hasSuffix("'") else {
                return nil
            }
            return String(value.dropFirst(prefix.count).dropLast())
        }
        guard markerLines.count == 1,
              let marker = markerLines.first,
              !marker.isEmpty,
              marker.utf8.count <= 256,
              marker.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw M1RepositoryDiscoveryError.policyUnavailable
        }
        let startToken = "cat > \"$disp_tmp\" <<EOF\n"
        guard let start = text.range(of: startToken),
              text.range(
                of: startToken,
                range: start.upperBound..<text.endIndex
              ) == nil,
              let end = text.range(
                of: "\nEOF",
                range: start.upperBound..<text.endIndex
              ) else {
            throw M1RepositoryDiscoveryError.policyUnavailable
        }
        var template = String(text[start.upperBound..<end.lowerBound])
        guard template.components(separatedBy: "$MARKER").count == 2 else {
            throw M1RepositoryDiscoveryError.policyUnavailable
        }
        template = template.replacingOccurrences(of: "$MARKER", with: marker)
        var index = template.startIndex
        while let dollar = template[index...].firstIndex(of: "$") {
            guard dollar > template.startIndex,
                  template[template.index(before: dollar)] == "\\" else {
                throw M1RepositoryDiscoveryError.policyUnavailable
            }
            index = template.index(after: dollar)
        }
        template = template.replacingOccurrences(of: "\\$", with: "$")
        let dispatcher = Data((template + "\n").utf8)
        guard !dispatcher.isEmpty, dispatcher.count <= 16_384 else {
            throw M1RepositoryDiscoveryError.policyUnavailable
        }
        return dispatcher
    }

    private static func readOwnedBoundedFile(
        _ path: String,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw M1RepositoryDiscoveryError.policyUnavailable
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              FileIdentity(info).isRegular,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= maximumBytes else {
            throw M1RepositoryDiscoveryError.policyUnavailable
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= maximumBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count == 0 else {
                throw M1RepositoryDiscoveryError.policyUnavailable
            }
            return data
        }
        throw M1RepositoryDiscoveryError.policyUnavailable
    }
}
