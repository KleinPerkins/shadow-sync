import Foundation

enum SystemGitConfigurationError: Error, Sendable, Equatable {
    case unavailable, cleanupPending
}

/// Captured configuration inputs, not repository-access or process authority.
/// Custody must authenticate the enclosing command, revalidate current policy,
/// and admit these exact paths before a child-side validator consumes this value.
/// An ordinary absent system configuration is explicit and cannot select the
/// legacy probe. Keeping construction here prevents a saved execution snapshot
/// from silently choosing a new configuration source.
struct GitConfigurationPreflight {
    let systemPath: String?
    let paths: [String]
    private let account: EffectiveAccount

    fileprivate init(systemPath: String?, account: EffectiveAccount) throws {
        self.account = account; self.systemPath = systemPath
        paths = (systemPath.map { [$0] } ?? [])
            + [account.homeDirectory + "/.config/git/config", account.homeDirectory + "/.gitconfig"]
        for path in paths {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.utf8.count <= 4096, components.count > 1,
                  components.first == "", components.dropFirst().allSatisfy({
                      !$0.isEmpty && $0 != "." && $0 != ".."
                          && !$0.utf8.contains(where: { $0 < 32 || $0 == 127 })
                  }) else { throw SystemGitConfigurationError.unavailable }
        }
        guard Set(paths.map { Data($0.utf8) }).count == paths.count else {
            throw SystemGitConfigurationError.unavailable
        }
    }

    /// Derive the resource set without touching it. Only the fixed system probe
    /// and this account's two normal user sources can enter configuration
    /// admission; a saved repository snapshot cannot supply extra path strings.
    func admissionPaths(account expected: EffectiveAccount) throws -> [String] {
        guard account.uid == expected.uid,
              account.username.utf8.elementsEqual(expected.username.utf8),
              account.homeDirectory.utf8.elementsEqual(expected.homeDirectory.utf8) else {
            throw SystemGitConfigurationError.unavailable
        }
        return paths
    }

    /// Decode only complete successful fixed-probe output. The custodian owes
    /// actual zero-status reaping and EOF before calling this lexical constructor.
    static func successfulSystemOutput(_ output: Data, account: EffectiveAccount) throws -> Self {
        guard output.count <= SystemGitConfigurationCommand.outputLimit else { throw SystemGitConfigurationError.unavailable }
        return try Self(systemPath: RepositoryHandle.activeSystemPath(from: output), account: account)
    }

    /// Called only after actual child retirement and complete bounded streams.
    /// Ordinary missing system configuration retains its existing nil meaning;
    /// a signal, partial failure output, or malformed success never does.
    static func completedSystemOutput(waitStatus: Int32, stdout: Data, stderr: Data,
                                      account: EffectiveAccount) throws -> Self {
        guard waitStatus & 0x7f == 0, stdout.count <= SystemGitConfigurationCommand.outputLimit,
              stderr.count <= SystemGitConfigurationCommand.outputLimit else { throw SystemGitConfigurationError.unavailable }
        if waitStatus == 0 {
            guard stderr.isEmpty else { throw SystemGitConfigurationError.unavailable }
            return try successfulSystemOutput(stdout, account: account)
        }
        guard stdout.isEmpty else { throw SystemGitConfigurationError.unavailable }
        return try Self(systemPath: nil, account: account)
    }

    #if SHADOW_SYNC_TESTING
    static func testing(systemPath: String?, account: EffectiveAccount) throws -> Self {
        try Self(systemPath: systemPath, account: account)
    }
    #endif

    /// No filesystem work occurs before account and exact ordered source-set
    /// validation. Callers still owe policy admission; this is only integrity.
    func validate(configuration: GitConfigurationSnapshot, account expected: EffectiveAccount) throws {
        _ = try admissionPaths(account: expected)
        guard configuration.contributors.count == paths.count,
              zip(configuration.contributors, paths).allSatisfy({
                  $0.path.utf8.elementsEqual($1.utf8)
              }) else { throw SystemGitConfigurationError.unavailable }
    }
    func validate(_ snapshot: RepositoryExecutionSnapshot, account expected: EffectiveAccount) throws {
        guard snapshot.accountUID == UInt32(expected.uid),
              snapshot.accountUsername.utf8.elementsEqual(expected.username.utf8),
              snapshot.accountHome.utf8.elementsEqual(expected.homeDirectory.utf8) else {
            throw SystemGitConfigurationError.unavailable
        }
        try validate(configuration: snapshot.configuration, account: expected)
    }
}

/// One fixed, repository-independent command. Neither a candidate path nor an
/// executable, argument or environment override is accepted by this adapter.
enum SystemGitConfigurationCommand {
    static let arguments = ["config", "--system", "--show-origin", "--name-only", "--null", "--list"]
    static let outputLimit: UInt64 = 65_536
    static func environment(account: EffectiveAccount) -> [String: String] {
        ["HOME": account.homeDirectory, "USER": account.username, "LOGNAME": account.username,
         "PATH": ClosedGitEnvironment.fixedPath, "LANG": "C", "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0"]
    }
    static func validate(_ request: UnvalidatedCustodyRequest, account: EffectiveAccount) throws {
        guard request.kind == .systemGitConfig,
              request.authority == .read || request.authority == .mutation,
              request.arguments == arguments, request.environment == environment(account: account),
              request.inputSHA256 == nil, request.traceLimit == 0,
              request.stdoutLimit <= outputLimit, request.stderrLimit <= outputLimit else {
            throw CustodyResourceError.invalidResource
        }
    }
    /// A fully retired, ordinary nonzero exit with no output retains the existing
    /// no-system-config meaning. Signals, pending, overflow, partial output and
    /// ownership/receipt failures never acquire that meaning.
    static func path(from result: CustodyRegistryResult) throws -> String? {
        if result.phase == .cleanupPending { throw SystemGitConfigurationError.cleanupPending }
        guard result.phase == .finished,
              result.reason == nil || result.reason == CustodyReason.none,
              let journal = result.journal, journal.phase == .terminal,
              journal.kind == .systemGitConfig, journal.reason == CustodyReason.none,
              let raw = journal.waitStatus, raw & 0x7f == 0,
              result.stdout.count <= outputLimit, result.stderr.count <= outputLimit,
              result.trace.isEmpty else { throw SystemGitConfigurationError.unavailable }
        if raw == 0 {
            guard journal.outcome == .completed else { throw SystemGitConfigurationError.unavailable }
            return try RepositoryHandle.activeSystemPath(from: result.stdout)
        }
        guard journal.outcome == .commandFailed, result.stdout.isEmpty else {
            throw SystemGitConfigurationError.unavailable
        }
        return nil
    }

    static func preflight(from result: CustodyRegistryResult, account: EffectiveAccount) throws -> GitConfigurationPreflight {
        let path = try path(from: result)
        guard result.journal?.binding.uid == UInt32(account.uid) else {
            throw SystemGitConfigurationError.unavailable
        }
        return try GitConfigurationPreflight(systemPath: path, account: account)
    }
}

/// The enclosing phase retains authority. This adapter cannot prolong the phase
/// or reacquire a shared lock underneath an existing mutation lease.
final class SystemGitConfigurationProbe {
    private weak var context: CommandCustodyContext?
    private let cancellation: CancellationToken
    private let failureLock = NSLock()
    private var failure: SystemGitConfigurationError?
    #if SHADOW_SYNC_TESTING
    private let testingResolve: (() throws -> String?)?
    #endif
    init(context: CommandCustodyContext, cancellation: CancellationToken) {
        self.context = context; self.cancellation = cancellation
        #if SHADOW_SYNC_TESTING
        testingResolve = nil
        #endif
    }
    #if SHADOW_SYNC_TESTING
    init(testingContext context: CommandCustodyContext, cancellation: CancellationToken,
         resolve: @escaping () throws -> String?) {
        self.context = context; self.cancellation = cancellation; testingResolve = resolve
    }
    #endif
    func validate(account: EffectiveAccount) throws {
        try validate()
        guard let context else { throw SystemGitConfigurationError.unavailable }
        do { try context.validatePhaseAdmission(account: account) }
        catch { throw SystemGitConfigurationError.unavailable }
    }
    func validate() throws {
        try throwIfFailed()
        guard let context, !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else {
            throw SystemGitConfigurationError.unavailable
        }
        do { try context.validatePhaseAdmission() }
        catch { throw SystemGitConfigurationError.unavailable }
    }
    /// Only validates already collected evidence. This neither resolves a new
    /// configuration source nor reopens command admission after cancellation.
    func validateRetainedEvidence(account: EffectiveAccount) throws {
        try throwIfFailed()
        guard let context else { throw SystemGitConfigurationError.unavailable }
        do { try context.validatePhaseAdmission(account: account) }
        catch { throw SystemGitConfigurationError.unavailable }
        try throwIfFailed()
    }
    func activePath(account: EffectiveAccount) throws -> String? {
        try validate(account: account)
        let path = try activePath()
        try validate(account: account)
        return path
    }

    func capturePreflight(account: EffectiveAccount) throws -> GitConfigurationPreflight {
        do {
            try validate(account: account)
            let value = try GitConfigurationPreflight(systemPath: activePath(account: account), account: account)
            try validate(account: account)
            return value
        } catch { throw recordFailure(error) }
    }
    /// A caller may catch a command failure to construct a per-repository
    /// warning. That must never erase unresolved cleanup at phase completion,
    /// including when the caller subsequently throws a different error.
    func withValidatedCompletion<Value>(_ body: () throws -> Value) throws -> Value {
        try validate()
        do {
            let value = try body()
            try validate()
            return value
        } catch {
            try throwIfFailed()
            throw error
        }
    }
    func activePath() throws -> String? {
        do {
            try throwIfFailed()
            return try resolvePath()
        } catch { throw recordFailure(error) }
    }
    private func recordFailure(_ error: Error) -> SystemGitConfigurationError {
        let reason = error as? SystemGitConfigurationError ?? .unavailable
        failureLock.lock()
        if failure == nil || reason == .cleanupPending { failure = reason }
        let retained = failure!
        failureLock.unlock()
        context?.close()
        cancellation.closeFutureChildAdmissions()
        return retained
    }
    private func throwIfFailed() throws {
        failureLock.lock(); let value = failure; failureLock.unlock()
        if let value { throw value }
    }
    private func resolvePath() throws -> String? {
        guard let context, !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else {
            throw SystemGitConfigurationError.unavailable
        }
        try context.validatePhaseAdmission()
        #if SHADOW_SYNC_TESTING
        if let testingResolve {
            do {
                let path = try testingResolve()
                guard !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else {
                    throw SystemGitConfigurationError.unavailable
                }
                try context.validatePhaseAdmission()
                return path
            } catch SystemGitConfigurationError.cleanupPending {
                context.close(); cancellation.closeFutureChildAdmissions()
                throw SystemGitConfigurationError.cleanupPending
            }
        }
        #endif
        let budget = try CustodyBudget.make(kind: .systemGitConfig, workSeconds: 5)
        let command = try context.prepareSystemConfiguration(budget: budget, cancellation: cancellation)
        let handle = try RetainedCleanupRegistry.shared.start(command)
        let observer = cancellation.observeCustodyCancellation(handle)
        defer { cancellation.removeCustodyCancellation(observer) }
        let result = handle.wait()
        if result.phase == .cleanupPending {
            context.close(); cancellation.closeFutureChildAdmissions()
            throw SystemGitConfigurationError.cleanupPending
        }
        guard !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else {
            throw SystemGitConfigurationError.unavailable
        }
        try context.validatePhaseAdmission()
        return try SystemGitConfigurationCommand.path(from: result)
    }
}
