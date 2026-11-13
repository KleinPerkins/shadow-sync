import AppKit
import ShadowSyncCore
import Darwin
import Foundation

signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments
let executablePath = arguments[0]

if let status = CommandCustodian.dispatch(arguments) { exit(status) }

#if SHADOW_SYNC_TESTING
if let status = NativeFixtureChild.dispatch(arguments) { exit(status) }
#endif

if let status = LifecycleMain.dispatch(
    arguments: arguments,
    executablePath: executablePath
) {
    exit(status)
}

if arguments.count == 2, arguments[1] == "--check" {
    let info = Bundle.main.infoDictionary ?? [:]
    guard info["CFBundleIdentifier"] as? String == "com.kleinperkins.shadow-sync",
          info["CFBundleExecutable"] as? String == "ShadowSync",
          info["LSUIElement"] as? Bool == false else {
        FileHandle.standardError.write(Data("ShadowSync bundle check failed.\n".utf8))
        exit(1)
    }
    print("ShadowSync bundle check OK")
    exit(0)
}

#if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
if let status = SignedInstallationFixtureApp.dispatch(arguments) { exit(status) }
#endif

#if SHADOW_SYNC_TESTING
if let status = GitChildTrampoline.dispatch(arguments: arguments) {
    exit(status)
}
if let status = WorkerMain.dispatch(arguments: arguments, executablePath: executablePath) {
    exit(status)
}
if let status = M1Harness.dispatch(arguments: arguments, executablePath: executablePath) {
    exit(status)
}
if let status = M1AppKitDriver.dispatch(arguments: arguments, executablePath: executablePath) {
    exit(status)
}
if let status = V3ChooserProbeDriver.dispatch(arguments: arguments) {
    exit(status)
}
if let status = V3LifecycleProbeDriver.dispatch(arguments: arguments) {
    exit(status)
}
if let status = M5AppKitDriver.dispatch(arguments: arguments) {
    exit(status)
}
if let status = M6AppDriver.dispatch(arguments: arguments) {
    exit(status)
}
FileHandle.standardError.write(
    Data("ShadowSync testing bundle requires an inherited isolated test channel.\n".utf8)
)
exit(2)
#else
do {
    let installed = try InstallationPaths.production().app
        + "/Contents/MacOS/ShadowSync"
    let observedPath = URL(fileURLWithPath: executablePath)
        .resolvingSymlinksInPath().path
    let installedPath = URL(fileURLWithPath: installed)
        .resolvingSymlinksInPath().path
    guard observedPath == installedPath else {
        throw InstallationLifecycleError.unverifiedInstalledState
    }
    if let status = GitChildTrampoline.dispatch(arguments: arguments) {
        exit(status)
    }
    if let status = WorkerMain.dispatch(arguments: arguments, executablePath: executablePath) {
        exit(status)
    }
    let paths = try InstallationPaths.production()
    let launchAgent = SystemLaunchAgentController()
    guard let startup = try InstalledHostStartup.enter(
        arguments: arguments,
        paths: paths,
        launchAgent: launchAgent,
        host: SystemInstalledHostController(),
        processID: getpid()
    ) else {
        exit(0)
    }
    try startup.validateBeforeApplication()
    let relay = HostActivationRelay()
    let application = NSApplication.shared
    let delegate = ShadowSyncAppDelegate(executablePath: executablePath)
    relay.install(target: delegate)
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    let server = try startup.makeServer(
        executablePath: executablePath,
        releaseIdentity: try ReleaseIdentity.load(
            bundlePath: try InstallationPaths.production().app
        ),
        onActivation: relay.activate,
        onLifecycleExit: {
            Task { @MainActor in
                delegate.requestLifecycleExit()
            }
            return true
        }
    )
    try server.start()
    delegate.installationInitialized = {
        try startup.didInitialize(server: server, onStop: {
            Task { @MainActor in delegate.requestLifecycleExit() }
        })
    }
    delegate.installationApplicationDrained = { try startup.applicationDrained(server: server) }
    defer { server.stop() }
    application.run()
} catch {
    FileHandle.standardError.write(
        Data("ShadowSync host start failed.\n".utf8)
    )
    exit(1)
}
#endif
