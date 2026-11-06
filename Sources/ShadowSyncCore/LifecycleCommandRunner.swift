import Darwin
import Foundation

/// Fixed lifecycle commands use the same suspended-admission, direct-child
/// signal/reap owner as other closed commands. No Foundation reaper participates.
/// This adapter does not make an unresolved cleanup deadline into success; the
/// shared runner's retained cleanup/deadline qualification remains separate.
enum LifecycleCommandRunner {
    static let outputLimit = 65_536

    static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        do {
            let result = try execute(
                executable: "/bin/launchctl", arguments: arguments,
                account: EffectiveAccount.current(), timeout: 10
            )
            // An incomplete diagnostic must never be interpreted as "absent".
            guard !result.timedOut, !result.cancelled,
                  result.outputDisposition == .complete else { return (-1, "") }
            return (result.status, String(decoding: result.output, as: UTF8.self))
        } catch {
            return (-1, "")
        }
    }

    static func verifySignature(at path: String) -> Bool {
        do {
            return try execute(
                executable: "/usr/bin/codesign",
                arguments: ["--verify", "--strict", "--verbose=2", path],
                account: EffectiveAccount.current(), timeout: 10
            ).succeeded
        } catch {
            return false
        }
    }

    private static func execute(
        executable: String, arguments: [String], account: EffectiveAccount,
        timeout: TimeInterval, validateSuspendedChild: ((pid_t) throws -> Void)? = nil
    ) throws -> ProcessResult {
        // Neither command needs the caller's working directory or inherited
        // stdin. A root descriptor avoids inheriting a repository cwd.
        let directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            throw SecureStateError.systemCall("open lifecycle command directory", errno)
        }
        defer { Darwin.close(directory) }
        return try ClosedProcessRunner(outputLimit: outputLimit).run(
            command: ClosedProcessCommand(executable: executable, arguments: arguments),
            environment: ClosedProcessRunner.environment(account: account),
            workingDirectoryDescriptor: directory, account: account,
            timeout: timeout, cancellation: CancellationToken(),
            validateSuspendedChild: validateSuspendedChild
        )
    }

    #if SHADOW_SYNC_TESTING
    static func testingExecute(
        executable: String, arguments: [String], account: EffectiveAccount,
        timeout: TimeInterval = 10,
        validateSuspendedChild: ((pid_t) throws -> Void)? = nil
    ) throws -> ProcessResult {
        try execute(executable: executable, arguments: arguments, account: account,
                    timeout: timeout, validateSuspendedChild: validateSuspendedChild)
    }
    #endif
}
