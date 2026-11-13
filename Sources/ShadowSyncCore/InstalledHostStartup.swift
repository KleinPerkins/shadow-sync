import Darwin
import Foundation

/// App-facing retained ownership. Construction is restricted to the existing
/// normal admission or the actual one-use, mutually authenticated staged host.
/// No caller-supplied proof, descriptor, generation or alternate owner is accepted.
public final class InstalledHostStartup {
    private let normal: LauncherAuthority?
    private let staged: InstallationPrecommitHost.RetainedOwnership?
    #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
    // Assigned while the new owner is private to enterSignedFixture, before
    // publication to AppKit. Retains exact policy file identities until drain.
    private var signedFixturePolicy: HostPolicySnapshot?
    #endif
    private init(normal: LauncherAuthority) { self.normal = normal; staged = nil }
    private init(staged: InstallationPrecommitHost.RetainedOwnership) { self.staged = staged; normal = nil }

    public static func enter(arguments: [String], paths: InstallationPaths,
                             launchAgent: any LaunchAgentControlling,
                             host: any InstalledHostControlling, processID: pid_t) throws -> InstalledHostStartup? {
        // Capture once on entry. The coordinator independently enforces the
        // smaller original invocation / actual kickstart-retirement+5s ceiling.
        let invocationDeadline = MonotonicDeadline(seconds: 5)
        guard processID == getpid(), processID > 1 else { throw CustodyRecordError.fenced }
        if try InstalledStateAdmission.invocationRole(arguments: arguments) == .managedHost,
           let precommit = try InstallationPrecommitHost.openIfActive(deadline: invocationDeadline) {
            let admission = try precommit.run()
            let retained = try admission.take()
            try retained.validateBeforeStartup()
            return InstalledHostStartup(staged: retained)
        }
        guard let normal = try InstalledStateAdmission.enterInstalledApplication(arguments: arguments,
            paths: paths, launchAgent: launchAgent, host: host, processID: processID) else { return nil }
        return InstalledHostStartup(normal: normal)
    }
    #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
    public struct SignedFixtureEntry {
        public let startup: InstalledHostStartup
        public let paths: InstallationPaths
        public let release: ReleaseIdentity
        fileprivate init(startup: InstalledHostStartup, paths: InstallationPaths, release: ReleaseIdentity) {
            self.startup = startup; self.paths = paths; self.release = release
        }
    }
    public enum SignedFixtureOutcome {
        case admitted(SignedFixtureEntry)
        // Authenticated readiness stop completed before AppKit admission.
        // This outcome is not normal startup or process-death evidence.
        case readinessStopped
    }
    /// Exact inherited route; refusal never falls back to ordinary admission.
    /// The admitted outcome requires the real mutual session, durable commit
    /// and one-use Admission.take before AppKit. readinessStopped ends the
    /// authenticated precommit exchange without constructing an application.
    public static func enterSignedFixture(arguments: [String]) throws -> SignedFixtureOutcome {
        guard arguments.count == 2, arguments[1] == InstallationPaths.managedHostArgument else { throw CustodyRecordError.fenced }
        let parent = try SignedInstallationFixtureHostChannel.Inherited.consume()
        let profile = try SignedInstallationFixtureContext.captureHostProfile(parent)
        let precommit = try InstallationPrecommitHost.openSignedFixture(parent, profile: profile)
        do {
            let admission = try precommit.run()
            let retained = try admission.take()
            try retained.validateBeforeStartup()
            guard case let .signedFixture(fixture) = profile else { throw CustodyRecordError.fenced }
            let policy = try fixture.loadCommittedHostPolicy()
            try retained.validateBeforeStartup()
            let startup = InstalledHostStartup(staged: retained)
            startup.signedFixturePolicy = policy
            return try .admitted(SignedFixtureEntry(startup: startup,
                paths: .isolated(root: parent.request.root), release: parent.request.release))
        } catch InstallationPrecommitHost.Failure.readinessStopped { return .readinessStopped }
    }
    #endif
    public func validateBeforeApplication() throws {
        try staged?.validateBeforeStartup()
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        try signedFixturePolicy?.revalidate()
        #endif
    }
    public func makeServer(executablePath: String, releaseIdentity: ReleaseIdentity,
                           onActivation: @escaping @Sendable () -> Bool,
                           onLifecycleExit: @escaping @Sendable () -> Bool) throws -> HostControlServer {
        if let staged {
            return try staged.makeServer(executablePath: executablePath, releaseIdentity: releaseIdentity,
                onActivation: onActivation, onLifecycleExit: onLifecycleExit)
        }
        guard let normal else { throw CustodyRecordError.fenced }
        return try HostControlServer(authority: normal, executablePath: executablePath,
            releaseIdentity: releaseIdentity, onActivation: onActivation, onLifecycleExit: onLifecycleExit)
    }
    /// Called after delegate chrome/shortcut initialization AND server start,
    /// before recovery, policy or repository work can await operation exclusion.
    public func didInitialize(server: HostControlServer, onStop: @escaping @Sendable () -> Void) throws {
        #if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
        try signedFixturePolicy?.revalidate()
        #endif
        try staged?.didInitialize(server, onStop: onStop)
    }
    /// The app calls this only from its established successful drain gate.
    /// The core independently joins the real server and closes its actual owners.
    public func applicationDrained(server: HostControlServer) throws {
        try staged?.applicationDrained(server)
    }
}
