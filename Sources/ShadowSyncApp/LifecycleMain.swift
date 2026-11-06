import ShadowSyncCore
import Foundation

enum LifecycleMain {
    private enum Route { case unhandled, retired, doctor, invalid }
    private static let mutationModes = ["--lifecycle-reconcile", "--lifecycle-repair", "--lifecycle-remove"]
    private static let doctorMode = "--lifecycle-doctor"

    /// Decide before resolving production paths, reading user state or executing
    /// any caller-provided installer. The signed coordinator owns future setup,
    /// migration and removal; Sparkle owns normal distribution updates.
    private static func route(_ arguments: [String]) -> Route {
        guard arguments.count >= 2 else { return .unhandled }
        if mutationModes.contains(arguments[1]) { return .retired }
        if arguments[1] == doctorMode { return arguments.count == 2 ? .doctor : .invalid }
        return .unhandled
    }

    static func dispatch(arguments: [String], executablePath: String) -> Int32? {
        switch route(arguments) {
        case .unhandled: return nil
        case .retired:
            FileHandle.standardError.write(Data("Source-built lifecycle mutation is retired; use the signed ShadowSync coordinator.\n".utf8))
            return 64
        case .invalid:
            FileHandle.standardError.write(Data("ShadowSync lifecycle arguments are invalid.\n".utf8))
            return 64
        case .doctor: break
        }
        #if SHADOW_SYNC_TESTING
        FileHandle.standardError.write(Data("Testing bundles cannot inspect production lifecycle state.\n".utf8))
        return 2
        #else
        do {
            let paths = try InstallationPaths.production()
            guard isCurrentInstalledExecutable(executablePath: executablePath, paths: paths) else {
                throw InstallationLifecycleError.unverifiedInstalledState
            }
            let lifecycle = InstallationLifecycle(paths: paths,
                launchAgent: SystemLaunchAgentController(), host: SystemInstalledHostController())
            printReport(try lifecycle.doctor())
            return 0
        } catch {
            FileHandle.standardError.write(Data("ShadowSync lifecycle failed: \(Redactor.sanitize(String(describing: error)))\n".utf8))
            return 1
        }
        #endif
    }

    #if SHADOW_SYNC_TESTING
    static func testingAdmissionMatrix() -> Bool {
        for mode in mutationModes {
            guard route(["ShadowSync", mode]) == .retired,
                  route(["ShadowSync", mode, "--source-installer", "/private/tmp/fixture/install.sh"]) == .retired else { return false }
        }
        return route(["ShadowSync", doctorMode]) == .doctor
            && route(["ShadowSync", doctorMode, "--source-installer", "/private/tmp/fixture/install.sh"]) == .invalid
            && route(["ShadowSync"]) == .unhandled
            && route(["ShadowSync", "--unrecognized"]) == .unhandled
    }
    #endif

    #if !SHADOW_SYNC_TESTING
    private static func isCurrentInstalledExecutable(executablePath: String, paths: InstallationPaths) -> Bool {
        let expected = paths.app + "/Contents/MacOS/ShadowSync"
        guard let identity = try? ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make(),
            expectedExecutablePath: expected) else { return false }
        return identity.userID == geteuid()
            && identity.isCurrent(expectedGeneration: identity.generation, requireGroupLeader: false)
            && URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: expected).resolvingSymlinksInPath().path
    }

    private static func printReport(_ report: InstallationDoctorReport) {
        print("ShadowSync doctor OK "
            + "version=\(report.release.version) build=\(report.release.buildNumber) "
            + "source=\(report.release.sourceRevision) source-sha256=\(report.release.sourceInputSHA256) "
            + "release-contract-sha256=\(report.release.releaseContractSHA256) bundle-sha256=\(report.bundleSHA256) "
            + "launcher-loaded=\(report.launcherLoaded) launcher-running=\(report.launcherRunning)")
    }
    #endif
}
