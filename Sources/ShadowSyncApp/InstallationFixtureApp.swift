#if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
import AppKit
import ShadowSyncCore

@MainActor
enum SignedInstallationFixtureApp {
    static func dispatch(_ arguments: [String]) -> Int32? {
        guard arguments.dropFirst().contains(InstallationPaths.managedHostArgument) else { return nil }
        do {
            let entry: InstalledHostStartup.SignedFixtureEntry
            switch try InstalledHostStartup.enterSignedFixture(arguments: arguments) {
            case let .admitted(value): entry = value
            case .readinessStopped:
                // Intentional pre-AppKit termination; no normal-start claim.
                return 0
            }
            try entry.startup.validateBeforeApplication()
            let application = NSApplication.shared
            let relay = HostActivationRelay()
            let delegate = ShadowSyncAppDelegate(executablePath: entry.paths.executable, signedFixture: entry)
            relay.install(target: delegate)
            application.delegate = delegate
            application.setActivationPolicy(.regular)
            let server = try entry.startup.makeServer(executablePath: entry.paths.executable,
                releaseIdentity: entry.release, onActivation: relay.activate,
                onLifecycleExit: {
                    Task { @MainActor in delegate.requestLifecycleExit() }
                    return true
                })
            try server.start()
            delegate.installationInitialized = {
                try entry.startup.didInitialize(server: server, onStop: {
                    Task { @MainActor in delegate.requestLifecycleExit() }
                })
            }
            delegate.installationApplicationDrained = { try entry.startup.applicationDrained(server: server) }
            defer { server.stop() }
            // The AppKit delegate callback is never invoked manually. Normal
            // started is sent only when that real callback reaches Core.
            application.run()
            return 0
        } catch { return 78 }
    }
}
#endif
