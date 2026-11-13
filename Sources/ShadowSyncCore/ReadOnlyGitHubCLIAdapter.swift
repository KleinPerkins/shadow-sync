import Darwin
import Foundation

public enum PullRequestUnavailableReason:
    String, Codable, Equatable, Sendable {
    case adapterAbsent
    case unqualified
    case executableDrift
    case invalidInput
    case authentication
    case network
    case rateLimited
    case timeout
    case truncated
    case malformed
    case cancelled
    case busy

    public var operatorExplanation: String {
        switch self {
        case .adapterAbsent:
            return "Pull-request status is unavailable because the approved GitHub CLI is not installed."
        case .unqualified:
            return "Pull-request status is unavailable in this build."
        case .executableDrift:
            return "Pull-request status is unavailable because the GitHub CLI identity could not be verified."
        case .invalidInput:
            return "Pull-request status is unavailable because the repository or branch identity is invalid."
        case .authentication:
            return "Pull-request status is unavailable because GitHub authentication is unavailable."
        case .network:
            return "Pull-request status is unavailable because GitHub could not be reached."
        case .rateLimited:
            return "Pull-request status is unavailable because GitHub rate-limited the request."
        case .timeout:
            return "Pull-request status is unavailable because the read-only query timed out."
        case .truncated:
            return "Pull-request status is unavailable because the bounded response was too large."
        case .malformed:
            return "Pull-request status is unavailable because GitHub returned an invalid response."
        case .cancelled:
            return "Pull-request status is unavailable because the read-only query was cancelled."
        case .busy:
            return "Pull-request status is unavailable because another GitHub query is active."
        }
    }
}

public struct PullRequestLookupResult: Codable, Equatable, Sendable {
    public let records: [PullRequestRecord]
    public let unavailableReason: PullRequestUnavailableReason?

    public init(
        records: [PullRequestRecord],
        unavailableReason: PullRequestUnavailableReason?
    ) {
        self.records = records
        self.unavailableReason = unavailableReason
    }

    public static func unavailable(
        _ reason: PullRequestUnavailableReason
    ) -> PullRequestLookupResult {
        PullRequestLookupResult(records: [], unavailableReason: reason)
    }

    public var availability: PullRequestAvailability {
        unavailableReason == nil ? .available : .unavailable
    }
}

public protocol PullRequestLookingUp: Sendable {
    func lookup(
        repositoryID: String,
        branch: String,
        tipOID: String,
        cancellation: CancellationToken
    ) -> PullRequestLookupResult
}

public struct UnavailablePullRequestLookup:
    PullRequestLookingUp, Sendable {
    public init() {}

    public func lookup(
        repositoryID: String,
        branch: String,
        tipOID: String,
        cancellation: CancellationToken
    ) -> PullRequestLookupResult {
        .unavailable(
            cancellation.isCancelled ? .cancelled : .adapterAbsent
        )
    }
}

public struct GitHubCLIInvocation: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environmentKeys: [String]
}

private final class GitHubChildAdmission: @unchecked Sendable {
    static let shared = GitHubChildAdmission(maximumActive: 1)
    private let lock = NSLock()
    private let maximumActive: Int
    private var active = 0

    init(maximumActive: Int) {
        self.maximumActive = max(1, maximumActive)
    }

    func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active < maximumActive else { return false }
        active += 1
        return true
    }

    func release() {
        lock.lock()
        active = max(0, active - 1)
        lock.unlock()
    }
}

public final class ReadOnlyGitHubCLIAdapter:
    PullRequestLookingUp, @unchecked Sendable {
    public static let approvedPaths = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
    ]
    public static let timeoutSeconds: TimeInterval = 15
    public static let streamLimit = 65_536
    public static let jsonFields =
        "number,url,state,isDraft,headRefName,headRefOid,isCrossRepository,updatedAt,closedAt,mergedAt"

    private struct ExecutableAdmission {
        let entrypoint: String
        let entrypointIdentity: FileIdentity
        let entrypointSize: Int64
        let entrypointModifiedSeconds: Int64
        let entrypointModifiedNanoseconds: Int64
        let path: String
        let identity: FileIdentity
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    private struct CacheKey: Hashable {
        let repositoryID: String
        let branch: String
        let oid: String
    }

    private static let cacheCapacity = 512
    private let account: EffectiveAccount
    private let audit: (@Sendable (GitHubCLIInvocation) -> Void)?
    private let childAdmission: GitHubChildAdmission
    private let cacheLock = NSLock()
    private var cache: [CacheKey: PullRequestLookupResult] = [:]
    private var cacheOrder: [CacheKey] = []
    #if SHADOW_SYNC_TESTING
    private let testingExecutablePath: String?
    private let testingTimeoutSeconds: TimeInterval?
    private let testingBeforeIdentityPublication:
        (@Sendable () -> Void)?
    #endif

    public init(
        account: EffectiveAccount,
        maximumConcurrentChildren: Int = 1,
        audit: (@Sendable (GitHubCLIInvocation) -> Void)? = nil
    ) {
        self.account = account
        self.audit = audit
        childAdmission = maximumConcurrentChildren == 1
            ? .shared
            : GitHubChildAdmission(
                maximumActive:
                    min(4, max(1, maximumConcurrentChildren))
            )
        #if SHADOW_SYNC_TESTING
        testingExecutablePath = nil
        testingTimeoutSeconds = nil
        testingBeforeIdentityPublication = nil
        #endif
    }

    #if SHADOW_SYNC_TESTING
    public init(
        account: EffectiveAccount,
        testingExecutablePath: String,
        testingTimeoutSeconds: TimeInterval? = nil,
        maximumConcurrentChildren: Int = 1,
        testingBeforeIdentityPublication:
            (@Sendable () -> Void)? = nil,
        audit: (@Sendable (GitHubCLIInvocation) -> Void)? = nil
    ) {
        self.account = account
        self.audit = audit
        childAdmission = maximumConcurrentChildren == 1
            ? .shared
            : GitHubChildAdmission(
                maximumActive:
                    min(4, max(1, maximumConcurrentChildren))
            )
        self.testingExecutablePath = testingExecutablePath
        self.testingTimeoutSeconds = testingTimeoutSeconds
        self.testingBeforeIdentityPublication =
            testingBeforeIdentityPublication
    }
    #endif

    public func lookup(
        repositoryID: String,
        branch: String,
        tipOID: String,
        cancellation: CancellationToken
    ) -> PullRequestLookupResult {
        guard Self.validRepositoryID(repositoryID),
              Self.validShortBranch(branch),
              Self.validOID(tipOID) else {
            return .unavailable(.invalidInput)
        }
        let key = CacheKey(
            repositoryID: repositoryID,
            branch: branch,
            oid: tipOID.lowercased()
        )
        cacheLock.lock()
        if let cached = cache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let result: PullRequestLookupResult
        if cancellation.isCancelled {
            result = .unavailable(.cancelled)
        } else {
            result = execute(
                repositoryID: repositoryID,
                branch: branch,
                cancellation: cancellation
            )
        }
        if result.availability == .available {
            cacheLock.lock()
            if cache[key] == nil {
                cacheOrder.append(key)
            }
            cache[key] = result
            while cacheOrder.count > Self.cacheCapacity {
                let evicted = cacheOrder.removeFirst()
                cache.removeValue(forKey: evicted)
            }
            cacheLock.unlock()
        }
        return result
    }

    #if SHADOW_SYNC_TESTING
    var testingCacheCount: Int {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache.count
    }
    #endif

    public static func arguments(
        repositoryID: String,
        branch: String
    ) throws -> [String] {
        guard validRepositoryID(repositoryID),
              validShortBranch(branch) else {
            throw GitSafetyError.unsafeRepository(
                "GitHub query identity is invalid"
            )
        }
        return [
            "pr", "list",
            "--repo", repositoryID,
            "--head", branch,
            "--state", "all",
            "--limit", "100",
            "--json", jsonFields,
        ]
    }

    public static func environment(
        account: EffectiveAccount
    ) -> [String: String] {
        [
            "HOME": account.homeDirectory,
            "LANG": "C",
            "LC_ALL": "C",
            "GH_PROMPT_DISABLED": "1",
            "GH_PAGER": "cat",
            "PAGER": "cat",
            "NO_COLOR": "1",
            "CLICOLOR": "0",
        ]
    }

    public static func parse(
        _ data: Data,
        repositoryID: String
    ) throws -> [PullRequestRecord] {
        guard data.count <= streamLimit,
              validRepositoryID(repositoryID),
              let value = try JSONSerialization.jsonObject(
                  with: data,
                  options: []
              ) as? [Any],
              value.count < 100 else {
            throw GitSafetyError.unsafeRepository(
                "GitHub pull-request response is malformed"
            )
        }
        let exactKeys = Set([
            "number", "url", "state", "isDraft", "headRefName",
            "headRefOid", "isCrossRepository", "updatedAt",
            "closedAt", "mergedAt",
        ])
        var records: [PullRequestRecord] = []
        for raw in value {
            guard let object = raw as? [String: Any],
                  Set(object.keys) == exactKeys,
                  let number = object["number"] as? Int,
                  let url = object["url"] as? String,
                  let rawState = object["state"] as? String,
                  let isDraft = object["isDraft"] as? Bool,
                  let head = object["headRefName"] as? String,
                  let crossRepository =
                    object["isCrossRepository"] as? Bool,
                  let updatedAt = object["updatedAt"] as? String else {
                throw GitSafetyError.unsafeRepository(
                    "GitHub pull-request response is malformed"
                )
            }
            let headOID = try optionalString(
                object["headRefOid"]
            )
            let closedAt = try optionalString(object["closedAt"])
            let mergedAt = try optionalString(object["mergedAt"])
            let state: PullRequestState
            switch rawState {
            case "OPEN" where isDraft:
                state = .draft
            case "OPEN" where !isDraft:
                state = .open
            case "MERGED" where !isDraft && mergedAt != nil:
                state = .merged
            case "CLOSED" where !isDraft
                    && mergedAt == nil && closedAt != nil:
                state = .closed
            default:
                throw GitSafetyError.unsafeRepository(
                    "GitHub pull-request state is contradictory"
                )
            }
            records.append(try PullRequestRecord(
                number: number,
                url: url,
                repositoryID: repositoryID,
                state: state,
                headRefName: head,
                headRefOID: headOID,
                isCrossRepository: crossRepository,
                updatedAt: updatedAt,
                closedAt: closedAt,
                mergedAt: mergedAt
            ))
        }
        guard Set(records.map(\.number)).count == records.count else {
            throw GitSafetyError.unsafeRepository(
                "GitHub pull-request response contains duplicate records"
            )
        }
        return records.sorted { $0.number < $1.number }
    }

    private static func optionalString(_ value: Any?) throws -> String? {
        if value is NSNull || value == nil {
            return nil
        }
        guard let value = value as? String, !value.isEmpty else {
            throw GitSafetyError.unsafeRepository(
                "GitHub pull-request response is malformed"
            )
        }
        return value
    }

    private func execute(
        repositoryID: String,
        branch: String,
        cancellation: CancellationToken
    ) -> PullRequestLookupResult {
        let admission: ExecutableAdmission
        do {
            admission = try executableAdmission()
        } catch let reason as AdapterAdmissionError {
            return .unavailable(reason.reason)
        } catch {
            return .unavailable(.executableDrift)
        }
        guard childAdmission.acquire() else {
            return .unavailable(.busy)
        }
        defer { childAdmission.release() }
        let arguments: [String]
        do {
            arguments = try Self.arguments(
                repositoryID: repositoryID,
                branch: branch
            )
        } catch {
            return .unavailable(.invalidInput)
        }
        let environment = Self.environment(account: account)
        audit?(GitHubCLIInvocation(
            executable: admission.path,
            arguments: arguments,
            environmentKeys: environment.keys.sorted()
        ))
        let result: ProcessResult
        do {
            result = try run(
                admission: admission,
                arguments: arguments,
                environment: environment,
                cancellation: cancellation
            )
        } catch {
            return .unavailable(
                cancellation.isCancelled ? .cancelled : .executableDrift
            )
        }
        if result.cancelled {
            return .unavailable(.cancelled)
        }
        if result.timedOut {
            return .unavailable(.timeout)
        }
        if result.stdoutTruncated || result.stderrTruncated {
            return .unavailable(.truncated)
        }
        guard result.status == 0 else {
            return .unavailable(Self.classifyFailure(result.stderr))
        }
        do {
            return PullRequestLookupResult(
                records: try Self.parse(
                    result.stdout,
                    repositoryID: repositoryID
                ),
                unavailableReason: nil
            )
        } catch {
            return .unavailable(.malformed)
        }
    }

    private enum AdapterAdmissionError: Error {
        case unavailable(PullRequestUnavailableReason)

        var reason: PullRequestUnavailableReason {
            switch self {
            case let .unavailable(reason): return reason
            }
        }
    }

    private func executableAdmission() throws -> ExecutableAdmission {
        #if SHADOW_SYNC_TESTING
        if let testingExecutablePath {
            return try admitExecutable(
                testingExecutablePath,
                requireApprovedPath: false
            )
        }
        #endif
        // No production GitHub graph is qualified. Refuse before inspecting an
        // installed executable; a pathname or signature observation cannot enroll
        // this optional adapter. Explicit isolated fixtures above remain separate.
        throw AdapterAdmissionError.unavailable(.unqualified)
    }

    private func admitExecutable(
        _ path: String,
        requireApprovedPath: Bool
    ) throws -> ExecutableAdmission {
        guard path.hasPrefix("/"),
              (!requireApprovedPath || Self.approvedPaths.contains(path)),
              !path.contains("\n"),
              !path.contains("\r"),
              !path.contains("\0") else {
            throw AdapterAdmissionError.unavailable(.executableDrift)
        }
        var entrypointInfo = stat()
        guard lstat(path, &entrypointInfo) == 0,
              let resolvedPointer = realpath(path, nil) else {
            throw AdapterAdmissionError.unavailable(.executableDrift)
        }
        defer { free(resolvedPointer) }
        let resolved = String(cString: resolvedPointer)
        let descriptor = Darwin.open(
            resolved,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw AdapterAdmissionError.unavailable(.executableDrift)
        }
        defer { close(descriptor) }
        var info = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &info) == 0,
              lstat(resolved, &pathInfo) == 0,
              FileIdentity(info) == FileIdentity(pathInfo),
              FileIdentity(info).isRegular,
              info.st_uid == 0 || info.st_uid == account.uid,
              (info.st_mode & 0o022) == 0,
              (info.st_mode & 0o111) != 0,
              info.st_nlink == 1 else {
            throw AdapterAdmissionError.unavailable(.executableDrift)
        }
        return ExecutableAdmission(
            entrypoint: path,
            entrypointIdentity: FileIdentity(entrypointInfo),
            entrypointSize: Int64(entrypointInfo.st_size),
            entrypointModifiedSeconds:
                Int64(entrypointInfo.st_mtimespec.tv_sec),
            entrypointModifiedNanoseconds:
                Int64(entrypointInfo.st_mtimespec.tv_nsec),
            path: resolved,
            identity: FileIdentity(info),
            size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
    }

    private func revalidate(_ admission: ExecutableAdmission) -> Bool {
        var entrypointInfo = stat()
        var info = stat()
        guard lstat(admission.entrypoint, &entrypointInfo) == 0,
              FileIdentity(entrypointInfo)
                == admission.entrypointIdentity,
              Int64(entrypointInfo.st_size)
                == admission.entrypointSize,
              Int64(entrypointInfo.st_mtimespec.tv_sec)
                == admission.entrypointModifiedSeconds,
              Int64(entrypointInfo.st_mtimespec.tv_nsec)
                == admission.entrypointModifiedNanoseconds,
              let resolvedPointer = realpath(
                  admission.entrypoint,
                  nil
              ) else {
            return false
        }
        defer { free(resolvedPointer) }
        guard String(cString: resolvedPointer) == admission.path else {
            return false
        }
        return lstat(admission.path, &info) == 0
            && FileIdentity(info) == admission.identity
            && Int64(info.st_size) == admission.size
            && Int64(info.st_mtimespec.tv_sec)
                == admission.modifiedSeconds
            && Int64(info.st_mtimespec.tv_nsec)
                == admission.modifiedNanoseconds
            && FileIdentity(info).isRegular
            && (info.st_uid == 0 || info.st_uid == account.uid)
            && (info.st_mode & 0o022) == 0
            && (info.st_mode & 0o111) != 0
            && info.st_nlink == 1
    }

    private func run(
        admission: ExecutableAdmission,
        arguments: [String],
        environment: [String: String],
        cancellation: CancellationToken
    ) throws -> ProcessResult {
        guard !cancellation.isCancelled, revalidate(admission) else {
            throw AdapterAdmissionError.unavailable(
                cancellation.isCancelled ? .cancelled : .executableDrift
            )
        }
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            closeAll(stdoutPipe + stderrPipe)
            throw SecureStateError.systemCall("pipe GitHub output", errno)
        }
        defer {
            close(stdoutPipe[0])
            close(stderrPipe[0])
        }
        for descriptor in [stdoutPipe[0], stderrPipe[0]] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0,
                  fcntl(
                      descriptor,
                      F_SETFL,
                      flags | O_NONBLOCK
                  ) == 0 else {
                close(stdoutPipe[1])
                close(stderrPipe[1])
                throw SecureStateError.systemCall(
                    "configure GitHub output",
                    errno
                )
            }
        }
        let nullFD = Darwin.open(
            "/dev/null",
            O_RDONLY | O_CLOEXEC
        )
        guard nullFD >= 0 else {
            close(stdoutPipe[1])
            close(stderrPipe[1])
            throw SecureStateError.systemCall("open /dev/null", errno)
        }
        defer { close(nullFD) }

        let pid = try spawnSuspended(
            executable: admission.path,
            arguments: arguments,
            environment: environment,
            standardInput: nullFD,
            standardOutput: stdoutPipe[1],
            standardError: stderrPipe[1]
        )
        close(stdoutPipe[1])
        close(stderrPipe[1])
        let generation = RunIdentity.make()
        #if SHADOW_SYNC_TESTING
        testingBeforeIdentityPublication?()
        #endif
        let identity: ProcessIdentity
        do {
            identity = try ProcessIdentity.capture(
                processID: pid,
                generation: generation,
                expectedExecutablePath: admission.path
            )
            guard identity.processGroupID == pid,
                  identity.userID == account.uid,
                  revalidate(admission),
                  !cancellation.isCancelled else {
                throw ProcessOwnershipError.identityMismatch
            }
        } catch {
            _ = kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            throw error
        }
        guard OwnedProcessSignal.send(
            SIGCONT,
            to: identity,
            expectedGeneration: generation
        ) else {
            _ = kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            throw ProcessOwnershipError.identityMismatch
        }

        #if SHADOW_SYNC_TESTING
        let timeout = testingTimeoutSeconds
            ?? Self.timeoutSeconds
        #else
        let timeout = Self.timeoutSeconds
        #endif
        let deadline = MonotonicDeadline(seconds: timeout)
        var termDeadline: MonotonicDeadline?
        var killed = false
        var timedOut = false
        var stdout = Capture()
        var stderr = Capture()
        var waitStatus: Int32 = 0
        var reaped = false
        while !reaped {
            drain(stdoutPipe[0], into: &stdout)
            drain(stderrPipe[0], into: &stderr)
            let waited = waitpid(pid, &waitStatus, WNOHANG)
            if waited == pid {
                reaped = true
                break
            }
            if waited < 0, errno != EINTR {
                throw SecureStateError.systemCall(
                    "waitpid GitHub child",
                    errno
                )
            }
            let shouldStop =
                cancellation.isCancelled || deadline.hasExpired
            if deadline.hasExpired {
                timedOut = true
            }
            if shouldStop, termDeadline == nil {
                _ = OwnedProcessSignal.send(
                    SIGTERM,
                    to: identity,
                    expectedGeneration: generation
                )
                termDeadline = MonotonicDeadline(seconds: 2)
            }
            if let termDeadline,
               termDeadline.hasExpired,
               !killed {
                _ = OwnedProcessSignal.send(
                    SIGKILL,
                    to: identity,
                    expectedGeneration: generation
                )
                killed = true
            }
            var polls = [
                pollfd(
                    fd: stdoutPipe[0],
                    events: Int16(POLLIN | POLLHUP),
                    revents: 0
                ),
                pollfd(
                    fd: stderrPipe[0],
                    events: Int16(POLLIN | POLLHUP),
                    revents: 0
                ),
            ]
            _ = poll(&polls, 2, 50)
        }
        drainUntilEOF(stdoutPipe[0], into: &stdout)
        drainUntilEOF(stderrPipe[0], into: &stderr)
        return ProcessResult(
            status: decode(waitStatus),
            stdout: stdout.data,
            stderr: stderr.data,
            stdoutTruncated: stdout.truncated,
            stderrTruncated: stderr.truncated,
            outputByteLimit: Self.streamLimit,
            timedOut: timedOut,
            cancelled: cancellation.isCancelled,
            terminationRequested: termDeadline != nil,
            processID: pid
        )
    }

    private func spawnSuspended(
        executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: Int32,
        standardOutput: Int32,
        standardError: Int32
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            throw SecureStateError.systemCall(
                "initialize GitHub child",
                errno
            )
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        var code = posix_spawn_file_actions_adddup2(
            &actions,
            standardInput,
            STDIN_FILENO
        )
        if code == 0 {
            code = posix_spawn_file_actions_adddup2(
                &actions,
                standardOutput,
                STDOUT_FILENO
            )
        }
        if code == 0 {
            code = posix_spawn_file_actions_adddup2(
                &actions,
                standardError,
                STDERR_FILENO
            )
        }
        guard code == 0 else {
            throw SecureStateError.systemCall(
                "configure GitHub child",
                code
            )
        }
        let flags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_START_SUSPENDED
        )
        code = posix_spawnattr_setflags(&attributes, flags)
        if code == 0 {
            code = posix_spawnattr_setpgroup(&attributes, 0)
        }
        guard code == 0 else {
            throw SecureStateError.systemCall(
                "configure GitHub child identity",
                code
            )
        }
        let argv = [executable] + arguments
        let env = environment.keys.sorted().map {
            "\($0)=\(environment[$0]!)"
        }
        return try withCStringArray(argv) { argvPointer in
            try withCStringArray(env) { envPointer in
                var pid: pid_t = 0
                let status = posix_spawn(
                    &pid,
                    executable,
                    &actions,
                    &attributes,
                    argvPointer,
                    envPointer
                )
                guard status == 0 else {
                    throw SecureStateError.systemCall(
                        "spawn GitHub child",
                        status
                    )
                }
                return pid
            }
        }
    }

    private struct Capture {
        var data = Data()
        var truncated = false
    }

    private func drain(_ descriptor: Int32, into capture: inout Capture) {
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(
                descriptor,
                &bytes,
                bytes.count
            )
            if count > 0 {
                let remaining = max(
                    0,
                    Self.streamLimit - capture.data.count
                )
                if remaining > 0 {
                    capture.data.append(
                        contentsOf: bytes.prefix(
                            min(count, remaining)
                        )
                    )
                }
                if count > remaining {
                    capture.truncated = true
                }
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    private func drainUntilEOF(
        _ descriptor: Int32,
        into capture: inout Capture
    ) {
        for _ in 0..<20 {
            let before = capture.data.count
            drain(descriptor, into: &capture)
            if before == capture.data.count {
                var item = pollfd(
                    fd: descriptor,
                    events: Int16(POLLIN | POLLHUP),
                    revents: 0
                )
                let result = poll(&item, 1, 10)
                if result <= 0
                    || (item.revents & Int16(POLLHUP)) != 0 {
                    drain(descriptor, into: &capture)
                    return
                }
            }
        }
    }

    private static func classifyFailure(
        _ stderr: Data
    ) -> PullRequestUnavailableReason {
        let text = Redactor.subprocessBytes(stderr).lowercased()
        if text.contains("auth")
            || text.contains("login")
            || text.contains("credential") {
            return .authentication
        }
        if text.contains("rate limit")
            || text.contains("secondary rate") {
            return .rateLimited
        }
        if text.contains("network")
            || text.contains("connect")
            || text.contains("resolve")
            || text.contains("timeout") {
            return .network
        }
        return .malformed
    }

    private static func validRepositoryID(_ value: String) -> Bool {
        value == value.lowercased()
            && !value.hasPrefix("-")
            && GitHubIdentity.parse(
                "git@github.com:\(value).git"
            )?.canonicalName == value
    }

    private static func validShortBranch(_ value: String) -> Bool {
        !value.hasPrefix("-")
            && !value.hasPrefix("refs/")
            && GitReferenceSyntax.isValidBranchName(value)
    }

    private static func validOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy {
                $0.isNumber || ("a"..."f").contains($0.lowercased())
            }
    }

    private func closeAll(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 {
            close(descriptor)
        }
    }

    private func decode(_ status: Int32) -> Int32 {
        if (status & 0x7F) == 0 {
            return (status >> 8) & 0xFF
        }
        return 128 + (status & 0x7F)
    }
}

private func withCStringArray<T>(
    _ values: [String],
    body: (
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) throws -> T
) rethrows -> T {
    let pointers: [UnsafeMutablePointer<CChar>?] =
        values.map { strdup($0) }
    defer {
        for pointer in pointers {
            free(pointer)
        }
    }
    var mutable = pointers
    mutable.append(nil)
    return try mutable.withUnsafeMutableBufferPointer {
        try body($0.baseAddress)
    }
}
