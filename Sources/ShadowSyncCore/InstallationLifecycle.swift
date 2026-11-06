import Darwin
import Foundation

public struct InstallationPaths: Equatable, Sendable {
    public static let label = "com.kleinperkins.shadow-sync"
    public static let managedHostArgument = "--managed-host"
    public let home: String
    public let app: String
    public let launchAgent: String
    public let state: StateLocation

    public var executable: String {
        app + "/Contents/MacOS/ShadowSync"
    }

    public var predecessorApp: String {
        home + "/Applications/Dev Main Sync.app"
    }

    public var predecessorExecutable: String {
        predecessorApp + "/Contents/MacOS/ShadowSync"
    }

    public static func production() throws -> InstallationPaths {
        let account = try EffectiveAccount.current()
        return InstallationPaths(
            home: account.homeDirectory,
            app: account.homeDirectory + "/Applications/ShadowSync.app",
            launchAgent: account.homeDirectory
                + "/Library/LaunchAgents/com.kleinperkins.shadow-sync.plist",
            state: try StateLocation.production()
        )
    }

    #if SHADOW_SYNC_TESTING
    public static func isolated(root: String) throws -> InstallationPaths {
        let root = try TestIsolation.validateRoot(root)
        let home = root + "/home"
        try TestIsolation.validateContainedDirectory(home, root: root)
        return InstallationPaths(
            home: home,
            app: home + "/Applications/ShadowSync.app",
            launchAgent: home
                + "/Library/LaunchAgents/com.kleinperkins.shadow-sync.plist",
            state: try StateLocation.isolated(root: root)
        )
    }
    #endif
}

public enum LaunchAgentState: Equatable, Sendable {
    case absent
    case loaded(program: String, processID: pid_t?)
    case queryFailure
}

public enum LaunchAgentProcessDisposition: Equatable, Sendable {
    case absent
    case matching
    case mismatch
}

public enum InstalledApplicationRole: Equatable, Sendable {
    case managedHost
    case manual
}

public protocol LaunchAgentControlling: Sendable {
    func state(label: String) -> LaunchAgentState
    func processDisposition(
        processID: pid_t,
        expectedProgram: String
    ) -> LaunchAgentProcessDisposition
    func bootstrap(label: String, plist: String, expectedProgram: String) throws
    func kickstart(label: String, expectedProgram: String) throws
    func bootout(label: String, expectedProgram: String) throws
}

public protocol InstalledHostControlling: Sendable {
    func requestExit(
        location: StateLocation,
        executable: String,
        release: ReleaseIdentity
    ) throws
    func isReady(
        location: StateLocation,
        executable: String,
        release: ReleaseIdentity,
        timeout: TimeInterval
    ) -> Bool
    func readyIdentity(
        location: StateLocation,
        executable: String,
        release: ReleaseIdentity,
        timeout: TimeInterval
    ) -> ProcessIdentity?
}

public extension InstalledHostControlling {
    func readyIdentity(
        location: StateLocation,
        executable: String,
        release: ReleaseIdentity,
        timeout: TimeInterval
    ) -> ProcessIdentity? {
        nil
    }
}

public struct SystemLaunchAgentController: LaunchAgentControlling {
    public init() {}

    public func processDisposition(
        processID: pid_t,
        expectedProgram: String
    ) -> LaunchAgentProcessDisposition {
        guard processID > 1 else { return .mismatch }
        errno = 0
        guard kill(processID, 0) == 0 else {
            return errno == ESRCH ? .absent : .mismatch
        }
        guard let identity = try? ProcessIdentity.capture(
            processID: processID,
            generation: RunIdentity.make(),
            expectedExecutablePath: expectedProgram
        ), identity.userID == geteuid() else {
            return .mismatch
        }
        return .matching
    }

    public func state(label: String) -> LaunchAgentState {
        let result = Self.run(["print", "gui/\(geteuid())/\(label)"])
        guard result.status == 0 else {
            if result.output.localizedCaseInsensitiveContains("could not find service")
                || result.output.localizedCaseInsensitiveContains("service not found") {
                return .absent
            }
            return .queryFailure
        }
        var program: String?
        var processID: pid_t?
        for line in result.output.split(separator: "\n") {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("program = ") {
                program = String(value.dropFirst("program = ".count))
            } else if value.hasPrefix("pid = "),
                      let parsed = pid_t(value.dropFirst("pid = ".count)) {
                processID = parsed
            }
        }
        guard let program else { return .queryFailure }
        return .loaded(program: program, processID: processID)
    }

    public func bootstrap(label: String, plist: String, expectedProgram: String) throws {
        let result = Self.run(["bootstrap", "gui/\(geteuid())", plist])
        guard result.status == 0 else {
            throw InstallationLifecycleError.launchctl("bootstrap", result.status)
        }
        guard case let .loaded(program, _) = state(label: label),
              program == expectedProgram else {
            throw InstallationLifecycleError.launchctl("print", -1)
        }
    }

    public func kickstart(label: String, expectedProgram: String) throws {
        switch state(label: label) {
        case let .loaded(program, processID):
            guard program == expectedProgram else {
                throw InstallationLifecycleError.launchAgentMismatch
            }
            if let processID {
                guard processDisposition(
                    processID: processID,
                    expectedProgram: expectedProgram
                ) == .absent else {
                    throw InstallationLifecycleError.launchAgentMismatch
                }
            }
        case .absent:
            throw InstallationLifecycleError.launchAgentMismatch
        case .queryFailure:
            throw InstallationLifecycleError.launchctl("print", -1)
        }
        let result = Self.run(["kickstart", "gui/\(geteuid())/\(label)"])
        guard result.status == 0 else {
            throw InstallationLifecycleError.launchctl("kickstart", result.status)
        }
        guard case let .loaded(program, processID) = state(label: label),
              program == expectedProgram else {
            throw InstallationLifecycleError.launchAgentMismatch
        }
        if let processID {
            guard processID > 1,
                  processDisposition(
                    processID: processID,
                    expectedProgram: expectedProgram
                  ) != .mismatch else {
                throw InstallationLifecycleError.launchAgentMismatch
            }
        }
    }

    public func bootout(label: String, expectedProgram: String) throws {
        switch state(label: label) {
        case .absent:
            return
        case let .loaded(program, _):
            guard program == expectedProgram else {
                throw InstallationLifecycleError.launchAgentMismatch
            }
        case .queryFailure:
            throw InstallationLifecycleError.launchctl("print", -1)
        }
        let result = Self.run(["bootout", "gui/\(geteuid())/\(label)"])
        guard result.status == 0, state(label: label) == .absent else {
            throw InstallationLifecycleError.launchctl("bootout", result.status)
        }
    }

    private static func run(_ arguments: [String]) -> (status: Int32, output: String) {
        LifecycleCommandRunner.launchctl(arguments)
    }

}

public struct SystemInstalledHostController: InstalledHostControlling {
    public init() {}

    public func requestExit(
        location: StateLocation,
        executable: String,
        release: ReleaseIdentity
    ) throws {
        _ = try HostControlClient.requestLifecycleExit(
            at: location,
            expectedExecutablePath: executable,
            expectedRelease: release
        )
    }

    public func isReady(
        location: StateLocation,
        executable: String,
        release: ReleaseIdentity,
        timeout: TimeInterval
    ) -> Bool {
        readyIdentity(
            location: location,
            executable: executable,
            release: release,
            timeout: timeout
        ) != nil
    }

    public func readyIdentity(
        location: StateLocation,
        executable: String,
        release: ReleaseIdentity,
        timeout: TimeInterval
    ) -> ProcessIdentity? {
        let deadline = MonotonicDeadline(seconds: timeout)
        repeat {
            if let identity = try? HostControlClient.readiness(
                at: location,
                expectedExecutablePath: executable,
                expectedRelease: release
            ) {
                return identity
            }
            if timeout <= 0 { return nil }
            Thread.sleep(forTimeInterval: 0.05)
        } while !deadline.hasExpired
        return nil
    }
}

public struct InstallationDoctorReport: Equatable, Sendable {
    public let release: ReleaseIdentity
    public let bundleSHA256: String
    public let launcherLoaded: Bool
    public let launcherRunning: Bool
}

public enum InstallationIntent: Sendable {
    case reconcile
    case repair
}

private final class PinnedParent {
    let path: String
    let descriptor: Int32
    let identity: FileIdentity

    init(path: String) throws {
        self.path = path
        descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw InstallationLifecycleError.system("open install parent", errno)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              (info.st_mode & 0o022) == 0 else {
            close(descriptor)
            throw InstallationLifecycleError.unsafeInstallPath(path)
        }
        identity = FileIdentity(info)
    }

    func validate() throws {
        var current = stat()
        guard lstat(path, &current) == 0,
              identity.matchesStableNode(FileIdentity(current)) else {
            throw InstallationLifecycleError.unsafeInstallPath(path)
        }
    }

    deinit { close(descriptor) }
}

public final class InstallationLifecycle: @unchecked Sendable {
    private let paths: InstallationPaths
    private let launchAgent: any LaunchAgentControlling
    private let host: any InstalledHostControlling
    private let fault: @Sendable (String) throws -> Void
    private let fileManager = FileManager.default
    private var pinnedAppParent: PinnedParent?
    private var pinnedPlistParent: PinnedParent?

    public init(
        paths: InstallationPaths,
        launchAgent: any LaunchAgentControlling,
        host: any InstalledHostControlling,
        fault: @escaping @Sendable (String) throws -> Void = { _ in }
    ) {
        self.paths = paths
        self.launchAgent = launchAgent
        self.host = host
        self.fault = fault
    }

    public func doctor() throws -> InstallationDoctorReport {
        let lifecycleAdmission = try LifecycleAdmissionAuthority.acquire(at: paths.state)
        defer { lifecycleAdmission.release() }
        try pinParents()
        defer { unpinParents() }
        try Self.validateParent(URL(fileURLWithPath: paths.app).deletingLastPathComponent().path)
        try Self.validateParent(
            URL(fileURLWithPath: paths.launchAgent).deletingLastPathComponent().path
        )
        let dualCanonicalApps =
            Self.pathExists(paths.app)
            && Self.pathExists(paths.predecessorApp)
        let prior = try inspectPrior(
            allowDualCurrentAuthoritative: true
        )
        if dualCanonicalApps {
            guard let artifact = prior.artifact,
                  prior.plistValid,
                  prior.loadedProgram == executablePath,
                  prior.running else {
                throw InstallationLifecycleError
                    .unverifiedInstalledState
            }
            return InstallationDoctorReport(
                release: artifact.release,
                bundleSHA256: artifact.canonicalSHA256,
                launcherLoaded: true,
                launcherRunning: true
            )
        }
        if prior.isPredecessorPath {
            guard let artifact = prior.artifact,
                  prior.plistValid,
                  prior.loadedProgram == prior.executable,
                  let readyIdentity = host.readyIdentity(
                    location: paths.state,
                    executable: prior.executable,
                    release: artifact.release,
                    timeout: 0
                  ) else {
                throw InstallationLifecycleError.unverifiedInstalledState
            }
            _ = try InstalledStateAdmission.requireLoadedProcess(
                launchAgent: launchAgent,
                executable: prior.executable,
                expectedProcessID: readyIdentity.processID
            )
            return InstallationDoctorReport(
                release: artifact.release,
                bundleSHA256: artifact.canonicalSHA256,
                launcherLoaded: true,
                launcherRunning: true
            )
        }
        let artifact = try InstalledStateAdmission.verifyStatic(
            paths: paths,
            launchAgent: launchAgent,
            allowedProcessID: nil
        )
        let readyIdentity = host.readyIdentity(
            location: paths.state,
            executable: executablePath,
            release: artifact.release,
            timeout: 0
        )
        guard let readyIdentity else {
            throw InstallationLifecycleError.hostNotReady
        }
        _ = try InstalledStateAdmission.requireLoadedProcess(
            launchAgent: launchAgent,
            executable: executablePath,
            expectedProcessID: readyIdentity.processID
        )
        return InstallationDoctorReport(
            release: artifact.release,
            bundleSHA256: artifact.canonicalSHA256,
            launcherLoaded: true,
            launcherRunning: true
        )
    }

    public func install(
        sourceBundle: String,
        intent: InstallationIntent = .reconcile
    ) throws -> InstallationDoctorReport {
        let source = try Self.verifyBundle(sourceBundle, requireProduction: true)
        guard source.release.version == ReleaseIdentity.version,
              source.release.buildNumber
                == ReleaseIdentity.buildNumber else {
            throw InstallationLifecycleError.unverifiedInstalledState
        }
        let authority = try RunAuthority.acquireLifecycleMutation(at: paths.state)
        defer { authority.release() }
        try prepareParents()
        try pinParents()
        defer { unpinParents() }

        let dualCanonicalApps =
            Self.pathExists(paths.app)
            && Self.pathExists(paths.predecessorApp)
        var prior = try inspectPrior(
            allowCorruptOwnedApp: intent == .repair,
            allowDualCurrentAuthoritative:
                intent == .repair && dualCanonicalApps
        )
        if dualCanonicalApps {
            try removeValidatedBundle(paths.predecessorApp)
            try fault("repair-dual-predecessor-cleanup")
            prior = try inspectPrior(
                allowCorruptOwnedApp: intent == .repair
            )
        }
        let predecessorMigration = prior.artifact.map {
            Self.isKnownPredecessorRelease($0.release)
        } == true && prior.predecessorPlistValid
        if !hasResidue,
           intent == .reconcile,
           prior.appExists || prior.plistExists || prior.loadedProgram != nil {
            let deadCoordinationRecovery: Bool
            if prior.loadedProgram == nil {
                deadCoordinationRecovery = try previewDeadHostCoordination(
                    expectedReleases: try coordinationReleases(
                        prior: prior
                    ),
                    expectedExecutable: prior.executable
                ) != nil
            } else {
                deadCoordinationRecovery = false
            }
            guard deadCoordinationRecovery || (
                prior.artifact != nil
                    && (prior.plistValid || predecessorMigration)
                    && prior.loadedProgram == prior.executable
                    && prior.running
            ) else {
                throw InstallationLifecycleError.unverifiedInstalledState
            }
        }
        if !hasResidue,
           intent == .repair,
           let artifact = prior.artifact,
           Self.isKnownPredecessorRelease(artifact.release),
           !prior.plistValid {
            // Inert rollback deliberately removes launchd registration. Exact
            // predecessor preimages may be retried through explicit repair.
            guard prior.predecessorPlistValid,
                  prior.loadedProgram == nil || prior.loadedProgram == prior.executable else {
                throw InstallationLifecycleError.unverifiedInstalledState
            }
        }
        if !hasResidue,
           intent == .repair,
           let artifact = prior.artifact,
           artifact.release.sameInstallContract(as: source.release),
           prior.plistValid,
           prior.loadedProgram == prior.executable,
           !prior.isPredecessorPath,
           !prior.running {
            let verified = try InstalledStateAdmission.verifyStatic(
                paths: paths,
                launchAgent: launchAgent,
                allowedProcessID: nil,
                allowStoppedLaunchAgent: true,
                allowUnpublishedRegisteredHost: true
            )
            guard verified == artifact else {
                throw InstallationLifecycleError.unverifiedInstalledState
            }
            var observation = try InstalledStateAdmission.observeManualLaunchAgent(
                paths: paths,
                launchAgent: launchAgent,
                host: host,
                release: artifact.release,
                executable: executablePath,
                callerProcessID: nil,
                timeout: 1
            )
            if observation == .stopped {
                let stoppedLauncher = try LauncherAuthority.acquireWithinLifecycle(
                    at: paths.state
                )
                do {
                    observation = try InstalledStateAdmission.observeManualLaunchAgent(
                        paths: paths,
                        launchAgent: launchAgent,
                        host: host,
                        release: artifact.release,
                        executable: executablePath,
                        callerProcessID: nil,
                        timeout: 0
                    )
                    stoppedLauncher.release()
                } catch {
                    stoppedLauncher.release()
                    throw error
                }
                if observation == .stopped {
                    try InstalledStateAdmission.requireNoCurrentRegisteredHost(
                        paths: paths
                    )
                    try authority.permitStagedHostAdmission()
                    try launchAgent.kickstart(
                        label: InstallationPaths.label,
                        expectedProgram: executablePath
                    )
                }
            }
            if observation == .ready {
                return InstallationDoctorReport(
                    release: artifact.release,
                    bundleSHA256: artifact.canonicalSHA256,
                    launcherLoaded: true,
                    launcherRunning: true
                )
            }
            guard let readyIdentity = host.readyIdentity(
                location: paths.state,
                executable: executablePath,
                release: artifact.release,
                timeout: 5
            ) else {
                throw InstallationLifecycleError.hostNotReady
            }
            _ = try InstalledStateAdmission.requireReadyProcessConvergence(
                launchAgent: launchAgent,
                executable: executablePath,
                readyIdentity: readyIdentity,
                timeout: 1
            )
            return InstallationDoctorReport(
                release: artifact.release,
                bundleSHA256: artifact.canonicalSHA256,
                launcherLoaded: true,
                launcherRunning: true
            )
        }
        if !hasResidue,
           let artifact = prior.artifact,
           artifact.release.sameInstallContract(as: source.release),
           prior.plistValid,
           prior.loadedProgram == prior.executable,
           !prior.isPredecessorPath,
           prior.running {
            return InstallationDoctorReport(
                release: artifact.release,
                bundleSHA256: artifact.canonicalSHA256,
                launcherLoaded: true,
                launcherRunning: prior.running
            )
        }
        var launcher: LauncherAuthority?
        var mutationStarted = false
        var committed = false
        var coordinationBackup: CoordinationBackup?
        let priorWasRunning = prior.running
        do {
            try fault("after-gates")
            launcher = try acquireLauncher(
                expectedRelease: prior.artifact?.release,
                executable: prior.executable,
                allowPersistedHostRelease: intent == .repair
            )
            try fault("after-drain")
            let expectedBackupReleases = try coordinationReleases(
                prior: prior,
                allowCorruptOwnedApp: intent == .repair
            )
            try recoverStagedCoordination(
                replacementRelease: source.release,
                expectedBackupReleases: expectedBackupReleases,
                expectedBackupExecutable: prior.executable
            )
            if prior.loadedProgram == nil,
               try activeCoordinationExists() {
                coordinationBackup = try stageDeadHostCoordination(
                    expectedReleases: try coordinationReleases(
                        prior: prior,
                        allowCorruptOwnedApp: intent == .repair
                    ),
                    expectedExecutable: prior.executable
                )
            }
            mutationStarted = true
            try recoverResidue(
                source: source,
                prior: &prior,
                allowCorruptOwnedApp: intent == .repair
            )
            prior = try inspectPrior(allowCorruptOwnedApp: intent == .repair)
            try stage(sourceBundle: sourceBundle, source: source)
            if prior.loadedProgram != nil {
                try launchAgent.bootout(
                    label: InstallationPaths.label,
                    expectedProgram: prior.executable
                )
                try removeStoppedHostCoordination(
                    expectedReleases:
                        [prior.artifact?.release].compactMap { $0 },
                    expectedExecutable: prior.executable
                )
            }
            try fault("before-promotion")
            if prior.appExists {
                try renameOwned(prior.appPath, prior.backupPath)
                try fault("after-app-backup")
            }
            if prior.plistExists {
                try renameOwned(paths.launchAgent, plistBackup)
                try fault("after-plist-backup")
            }
            try renameOwned(appIncoming, paths.app)
            try fault("after-app-promotion")
            try renameOwned(plistIncoming, paths.launchAgent)
            try fault("after-plist-promotion")
            let promoted = try Self.verifyBundle(paths.app, requireProduction: true)
            guard promoted.canonicalSHA256 == source.canonicalSHA256,
                  promoted.release == source.release else {
                throw InstallationLifecycleError.bundleDigestMismatch
            }
            try Self.validateLaunchAgent(paths.launchAgent, executable: executablePath)

            try authority.permitStagedHostAdmission()
            launcher?.release()
            launcher = nil
            try launchAgent.bootstrap(
                label: InstallationPaths.label,
                plist: paths.launchAgent,
                expectedProgram: executablePath
            )
            try fault("after-bootstrap")
            try launchAgent.kickstart(
                label: InstallationPaths.label,
                expectedProgram: executablePath
            )
            try fault("after-kickstart")
            guard let readyIdentity = host.readyIdentity(
                location: paths.state,
                executable: executablePath,
                release: promoted.release,
                timeout: 5
            ) else {
                throw InstallationLifecycleError.hostNotReady
            }
            _ = try InstalledStateAdmission.requireLoadedProcess(
                launchAgent: launchAgent,
                executable: executablePath,
                expectedProcessID: readyIdentity.processID
            )
            try fault("after-readiness")
            committed = true
            try fault("after-commit")
            if let coordinationBackup {
                try removeStagedCoordination(coordinationBackup)
            }
            try removeBackups(cleanupPrefix: "install-cleanup")
            try fault("after-cleanup")
            return InstallationDoctorReport(
                release: promoted.release,
                bundleSHA256: promoted.canonicalSHA256,
                launcherLoaded: true,
                launcherRunning: true
            )
        } catch {
            launcher?.release()
            launcher = nil
            if committed {
                throw error
            } else if mutationStarted {
                do {
                    try rollback(
                        prior: prior,
                        restartPriorHost: priorWasRunning,
                        replacementRelease: source.release,
                        coordinationBackup: coordinationBackup
                    )
                } catch {
                    throw InstallationLifecycleError.rollbackFailed(
                        String(describing: error)
                    )
                }
            } else if prior.requiresInertRecovery {
                // A failed transition never grants permission to reactivate a
                // predecessor, including one stored at the current app path.
                do {
                    let stopped = try acquireLauncher(
                        expectedRelease: prior.artifact?.release,
                        executable: prior.executable
                    )
                    defer { stopped.release() }
                    if let loaded = try loadedProgram() {
                        guard loaded == prior.executable else {
                            throw InstallationLifecycleError.launchAgentMismatch
                        }
                        try launchAgent.bootout(
                            label: InstallationPaths.label,
                            expectedProgram: prior.executable
                        )
                    }
                    guard try loadedProgram() == nil else {
                        throw InstallationLifecycleError.launchAgentMismatch
                    }
                } catch {
                    throw InstallationLifecycleError.rollbackFailed(
                        String(describing: error)
                    )
                }
            } else if prior.running,
                      !host.isReady(
                        location: paths.state,
                        executable: prior.executable,
                        release: prior.artifact!.release,
                        timeout: 0
                      ) {
                try? launchAgent.bootout(
                    label: InstallationPaths.label,
                    expectedProgram: prior.executable
                )
                try? launchAgent.bootstrap(
                    label: InstallationPaths.label,
                    plist: paths.launchAgent,
                    expectedProgram: prior.executable
                )
                try? launchAgent.kickstart(
                    label: InstallationPaths.label,
                    expectedProgram: prior.executable
                )
            }
            throw error
        }
    }

    public func uninstall() throws {
        let authority = try RunAuthority.acquireLifecycleMutation(at: paths.state)
        defer { authority.release() }
        try pinParents()
        defer { unpinParents() }
        let dualCanonicalApps =
            Self.pathExists(paths.app)
            && Self.pathExists(paths.predecessorApp)
        var prior = try inspectPrior(
            allowDualCurrentAuthoritative: dualCanonicalApps
        )
        var recoveryLauncher: LauncherAuthority?
        if hasResidue {
            let stagedCoordination = try stagedCoordinationExists()
            let recoverySource: BundleArtifactIdentity?
            if let artifact = prior.artifact {
                recoverySource = artifact
            } else if Self.pathExists(appBackup) {
                recoverySource = try Self.verifyBundle(
                    appBackup,
                    requireProduction: true
                )
            } else if let predecessorBackup = existingPredecessorBackups.first {
                recoverySource = try Self.verifyBundle(
                    predecessorBackup,
                    requireProduction: true
                )
            } else {
                recoverySource = nil
            }
            if stagedCoordination {
                guard let recoverySource else {
                    throw InstallationLifecycleError.unexpectedResidue
                }
                let expectedCoordinationReleases =
                    try coordinationReleases(prior: prior)
                guard let stagedPreview =
                    try previewStagedCoordination(
                        expectedBackupReleases:
                            expectedCoordinationReleases,
                        expectedExecutable: prior.executable
                    ) else {
                    throw InstallationLifecycleError.unexpectedResidue
                }
                let launcher = try acquireLauncher(
                    expectedRelease: prior.artifact?.release,
                    executable: prior.executable
                )
                do {
                    try fault("uninstall-after-staged-coordination-preview")
                    if prior.loadedProgram != nil {
                        try launchAgent.bootout(
                            label: InstallationPaths.label,
                            expectedProgram: prior.executable
                        )
                    }
                    try recoverStagedCoordination(
                        replacementRelease: recoverySource.release,
                        expectedBackupReleases:
                            expectedCoordinationReleases,
                        expectedBackupExecutable: prior.executable,
                        expectedBackup: stagedPreview.backup
                    )
                    try removeStoppedHostCoordination(
                        expectedReleases: expectedCoordinationReleases,
                        expectedExecutable: prior.executable
                    )
                    try fault(
                        "uninstall-after-staged-coordination-recovery"
                    )
                    prior = try inspectPrior()
                    recoveryLauncher = launcher
                } catch {
                    launcher.release()
                    throw error
                }
            }
            if try isCommittedUninstallResidue(prior: prior) {
                let launcher = try recoveryLauncher
                    ?? acquireLauncher(expectedRelease: nil)
                do {
                    try finishCommittedUninstallResidue()
                    try removeCoordinationState()
                    try retireCoordinationLocks(authority: authority)
                    launcher.release()
                    return
                } catch {
                    launcher.release()
                    throw error
                }
            }
            guard let recoverySource else {
                throw InstallationLifecycleError.unexpectedResidue
            }
            let launcher = try recoveryLauncher
                ?? acquireLauncher(
                    expectedRelease: prior.artifact?.release,
                    executable: prior.executable
                )
            do {
                try recoverResidue(
                    source: recoverySource,
                    prior: &prior,
                    allowCorruptOwnedApp: false
                )
                prior = try inspectPrior()
                recoveryLauncher = launcher
            } catch {
                launcher.release()
                throw error
            }
        }
        if !prior.appExists, !prior.plistExists, prior.loadedProgram == nil {
            guard !hasResidue else {
                throw InstallationLifecycleError.unexpectedResidue
            }
            try removeCoordinationState()
            try retireCoordinationLocks(authority: authority)
            return
        }
        guard prior.artifact != nil,
              prior.plistValid,
              prior.loadedProgram == nil || prior.loadedProgram == prior.executable else {
            throw InstallationLifecycleError.unverifiedInstalledState
        }

        let launcher = try recoveryLauncher
            ?? acquireLauncher(
                expectedRelease: prior.artifact?.release,
                executable: prior.executable
            )
        var committed = false
        do {
            try fault("uninstall-after-gates")
            if prior.loadedProgram != nil {
                try launchAgent.bootout(
                    label: InstallationPaths.label,
                    expectedProgram: prior.executable
                )
            }
            try fault("uninstall-after-drain")
            if dualCanonicalApps {
                try renameOwned(
                    paths.predecessorApp,
                    predecessorAppBackup
                )
                try fault("uninstall-after-predecessor-backup")
            }
            try backupPrior(prior)
            try fault("uninstall-after-backup")
            try removeCoordinationState()
            committed = true
            try fault("uninstall-after-commit")
            try removeBackups(cleanupPrefix: "uninstall-cleanup")
            try fault("uninstall-after-cleanup")
            try retireCoordinationLocks(authority: authority)
            launcher.release()
        } catch {
            launcher.release()
            if committed {
                throw error
            }
            do {
                try rollback(
                    prior: prior,
                    restartPriorHost: prior.running,
                    replacementRelease: prior.artifact?.release
                )
                if dualCanonicalApps,
                   Self.pathExists(predecessorAppBackup),
                   !Self.pathExists(paths.predecessorApp) {
                    try renameOwned(
                        predecessorAppBackup,
                        paths.predecessorApp
                    )
                }
            } catch {
                throw InstallationLifecycleError.rollbackFailed(
                    String(describing: error)
                )
            }
            throw error
        }
    }

    private var executablePath: String {
        paths.executable
    }

    private var appParent: String {
        URL(fileURLWithPath: paths.app).deletingLastPathComponent().path
    }

    private var plistParent: String {
        URL(fileURLWithPath: paths.launchAgent).deletingLastPathComponent().path
    }

    private var appIncoming: String { appParent + "/.ShadowSync.app.incoming" }
    private var appBackup: String { appParent + "/.ShadowSync.app.previous" }
    private var predecessorAppBackup: String {
        appParent + "/.ShadowSync.app.predecessor.previous"
    }
    // Historical input only. New transactions always use predecessorAppBackup.
    private var legacyPredecessorAppBackup: String {
        appParent + "/.Dev Main Sync.app.previous"
    }
    private var predecessorBackupPaths: [String] {
        [predecessorAppBackup, legacyPredecessorAppBackup]
    }
    private var existingPredecessorBackups: [String] {
        predecessorBackupPaths.filter { Self.pathExists($0) }
    }
    private var appBackupPaths: [String] {
        [appBackup] + predecessorBackupPaths
    }
    private var plistIncoming: String {
        plistParent + "/.com.kleinperkins.shadow-sync.plist.incoming"
    }
    private var plistBackup: String {
        plistParent + "/.com.kleinperkins.shadow-sync.plist.previous"
    }
    fileprivate static let ownerBackupName = ".host-owner.json.previous"
    fileprivate static let socketBackupName = ".host.sock.previous"

    private struct CoordinationBackup {
        let owner: FileIdentity
        let socket: FileIdentity
    }

    private struct DeadCoordinationPreview {
        let state: SecureStateDirectory
        let owner: FileIdentity
        let socket: FileIdentity
    }

    private struct StagedCoordinationPreview {
        let backup: CoordinationBackup
    }

    private var hasResidue: Bool {
        Self.pathExists(appIncoming)
            || Self.pathExists(plistIncoming)
            || Self.pathExists(appBackup)
            || Self.pathExists(predecessorAppBackup)
            || Self.pathExists(legacyPredecessorAppBackup)
            || Self.pathExists(plistBackup)
            || Self.pathExists(
                paths.state.path + "/" + Self.ownerBackupName
            )
            || Self.pathExists(
                paths.state.path + "/" + Self.socketBackupName
            )
            || ((try? lifecycleSlotNames().isEmpty) == false)
    }

    private func prepareParents() throws {
        try Self.ensureDirectory(paths.home, mode: 0o700, mayExist: true)
        try Self.ensureDirectory(appParent, mode: 0o700, mayExist: true)
        try Self.ensureDirectory(
            URL(fileURLWithPath: plistParent).deletingLastPathComponent().path,
            mode: 0o700,
            mayExist: true
        )
        try Self.ensureDirectory(plistParent, mode: 0o700, mayExist: true)
    }

    private func pinParents() throws {
        let app = try PinnedParent(path: appParent)
        let plist = try PinnedParent(path: plistParent)
        pinnedAppParent = app
        pinnedPlistParent = plist
    }

    private func unpinParents() {
        pinnedAppParent = nil
        pinnedPlistParent = nil
    }

    private func acquireLauncher(
        expectedRelease: ReleaseIdentity?,
        executable: String? = nil,
        allowPersistedHostRelease: Bool = false
    ) throws -> LauncherAuthority {
        let expectedExecutable = executable ?? executablePath
        do {
            let authority = try LauncherAuthority.acquireWithinLifecycle(at: paths.state)
            return authority
        } catch let SecureStateError.contention(name) where name == "launcher.lock" {
            // A verified cooperative exit is the only contention recovery.
        } catch {
            throw error
        }
        let drainRelease: ReleaseIdentity?
        if let expectedRelease {
            drainRelease = expectedRelease
        } else if allowPersistedHostRelease {
            drainRelease = try validatedPersistedHostRelease(
                executable: expectedExecutable
            )
        } else {
            drainRelease = nil
        }
        guard let drainRelease else {
            throw InstallationLifecycleError.unverifiedInstalledState
        }
        try host.requestExit(
            location: paths.state,
            executable: expectedExecutable,
            release: drainRelease
        )
        let deadline = MonotonicDeadline(seconds: 5)
        repeat {
            do {
                let authority = try LauncherAuthority.acquireWithinLifecycle(at: paths.state)
                return authority
            } catch let SecureStateError.contention(name) where name == "launcher.lock" {
                Thread.sleep(forTimeInterval: 0.05)
            } catch {
                throw error
            }
        } while !deadline.hasExpired
        throw InstallationLifecycleError.launcherDidNotExit
    }

    private func validatedPersistedHostRelease(
        executable: String
    ) throws -> ReleaseIdentity {
        try Self.validateLaunchAgent(paths.launchAgent, executable: executable)
        let state = try SecureStateDirectory.openExisting(paths.state)
        let registration = try HostRegistrationStore.read(state: state)
        guard let release = registration.release,
              registration.identity.executablePath == executable,
              registration.identity.processID > 1 else {
            throw InstallationLifecycleError.unverifiedInstalledState
        }
        _ = try InstalledStateAdmission.requireLoadedProcess(
            launchAgent: launchAgent,
            executable: executable,
            expectedProcessID: registration.identity.processID
        )
        let socket = try state.ownedEntryIdentity(
            named: "host.sock",
            allowSocket: true
        )
        guard mode_t(socket.mode) & S_IFMT == S_IFSOCK,
              mode_t(socket.mode) & 0o777 == 0o600 else {
            throw InstallationLifecycleError.unverifiedInstalledState
        }
        return release
    }

    private struct Prior {
        var artifact: BundleArtifactIdentity?
        var appPath: String
        var executable: String
        var backupPath: String
        var isPredecessorPath: Bool
        var appExists: Bool
        var plistExists: Bool
        var plistValid: Bool
        var predecessorPlistValid: Bool
        var loadedProgram: String?
        var running: Bool

        var requiresInertRecovery: Bool {
            isPredecessorPath || artifact.map {
                InstallationLifecycle.isKnownPredecessorRelease($0.release)
            } == true
        }
    }

    private func inspectPrior(
        allowCorruptOwnedApp: Bool = false,
        allowDualCurrentAuthoritative: Bool = false
    ) throws -> Prior {
        guard existingPredecessorBackups.count <= 1 else {
            throw InstallationLifecycleError.unexpectedResidue
        }
        let currentExists = Self.pathExists(paths.app)
        let predecessorExists = Self.pathExists(paths.predecessorApp)
        if currentExists && predecessorExists {
            guard allowDualCurrentAuthoritative else {
                throw InstallationLifecycleError
                    .unverifiedInstalledState
            }
            return try inspectAuthoritativeCurrentWithPredecessor()
        }
        let isPredecessorPath = predecessorExists
        let appPath = isPredecessorPath ? paths.predecessorApp : paths.app
        let observedExecutable =
            isPredecessorPath ? paths.predecessorExecutable : executablePath
        let observedBackup =
            isPredecessorPath ? predecessorAppBackup : appBackup
        let appExists = currentExists || predecessorExists
        let plistExists = Self.pathExists(paths.launchAgent)
        let artifact: BundleArtifactIdentity?
        if appExists {
            do {
                artifact = try Self.verifyBundle(appPath, requireProduction: true)
            } catch {
                guard allowCorruptOwnedApp, Self.isOwnedDirectory(appPath) else {
                    throw error
                }
                artifact = nil
            }
        } else {
            artifact = nil
        }
        let plistValid: Bool
        if plistExists, artifact != nil {
            plistValid = (try? Self.validateLaunchAgent(
                paths.launchAgent,
                executable: observedExecutable
            )) != nil
        } else {
            plistValid = false
        }
        let predecessorPlistValid: Bool
        if plistExists,
           let artifact,
           Self.isKnownPredecessorRelease(artifact.release) {
            predecessorPlistValid = (try? Self.validatePredecessorLaunchAgent(
                paths.launchAgent,
                executable: observedExecutable
            )) != nil
        } else {
            predecessorPlistValid = false
        }
        let loaded = try loadedProgram()
        if let loaded, loaded != observedExecutable {
            throw InstallationLifecycleError.unverifiedInstalledState
        }
        let readyIdentity = artifact.flatMap {
            host.readyIdentity(
                location: paths.state,
                executable: observedExecutable,
                release: $0.release,
                timeout: 0
            )
        }
        let running: Bool
        if let readyIdentity {
            running = (try? InstalledStateAdmission.requireLoadedProcess(
                launchAgent: launchAgent,
                executable: observedExecutable,
                expectedProcessID: readyIdentity.processID
            )) != nil
        } else {
            running = false
        }
        return Prior(
            artifact: artifact,
            appPath: appPath,
            executable: observedExecutable,
            backupPath: observedBackup,
            isPredecessorPath: isPredecessorPath,
            appExists: appExists,
            plistExists: plistExists,
            plistValid: plistValid,
            predecessorPlistValid: predecessorPlistValid,
            loadedProgram: loaded,
            running: running
        )
    }

    private func inspectAuthoritativeCurrentWithPredecessor()
        throws -> Prior {
        let current = try Self.verifyBundle(
            paths.app,
            requireProduction: true
        )
        let predecessor = try Self.verifyBundle(
            paths.predecessorApp,
            requireProduction: true
        )
        guard !Self.isKnownPredecessorRelease(current.release) else {
            throw InstallationLifecycleError.unsafeInstallPath(
                "dual canonical current path contains predecessor release"
            )
        }
        guard Self.isKnownPredecessorRelease(predecessor.release) else {
            throw InstallationLifecycleError.unsafeInstallPath(
                "dual canonical predecessor release is unknown"
            )
        }
        do {
            try Self.validateLaunchAgent(
                paths.launchAgent,
                executable: executablePath
            )
        } catch {
            throw InstallationLifecycleError.unsafeInstallPath(
                "dual canonical LaunchAgent does not select ShadowSync"
            )
        }
        guard try loadedProgram() == executablePath else {
            throw InstallationLifecycleError.unsafeInstallPath(
                "dual canonical loaded program is not ShadowSync"
            )
        }
        guard let readyIdentity = host.readyIdentity(
            location: paths.state,
            executable: executablePath,
            release: current.release,
            timeout: 0
        ) else {
            throw InstallationLifecycleError.unsafeInstallPath(
                "dual canonical ShadowSync host is not ready"
            )
        }
        do {
            _ = try InstalledStateAdmission.requireLoadedProcess(
                launchAgent: launchAgent,
                executable: executablePath,
                expectedProcessID: readyIdentity.processID
            )
        } catch {
            throw InstallationLifecycleError.unsafeInstallPath(
                "dual canonical ShadowSync process is not verified"
            )
        }
        return Prior(
            artifact: current,
            appPath: paths.app,
            executable: executablePath,
            backupPath: appBackup,
            isPredecessorPath: false,
            appExists: true,
            plistExists: true,
            plistValid: true,
            predecessorPlistValid: false,
            loadedProgram: executablePath,
            running: true
        )
    }

    private func recoverResidue(
        source: BundleArtifactIdentity,
        prior: inout Prior,
        allowCorruptOwnedApp: Bool
    ) throws {
        try removeValidatedIncoming()
        let appBackups = appBackupPaths.filter {
            Self.pathExists($0)
        }
        guard appBackups.count <= 1 else {
            throw InstallationLifecycleError.unexpectedResidue
        }
        let observedAppBackup = appBackups.first
        let hasAppBackup = observedAppBackup != nil
        let backupIsPredecessor = observedAppBackup.map {
            predecessorBackupPaths.contains($0)
        } == true
        let backupTarget = backupIsPredecessor ? paths.predecessorApp : paths.app
        let backupExecutable =
            backupIsPredecessor ? paths.predecessorExecutable : executablePath
        let hasPlistBackup = Self.pathExists(plistBackup)
        if (hasAppBackup || hasPlistBackup),
           prior.artifact?.release.sameInstallContract(as: source.release) == true,
           prior.plistValid {
            if let observedAppBackup { try removeOwnedTree(observedAppBackup) }
            if hasPlistBackup { try removeValidatedRegular(plistBackup) }
            return
        }
        var backupArtifact: BundleArtifactIdentity?
        if hasAppBackup {
            do {
                backupArtifact = try Self.verifyBundle(
                    observedAppBackup!,
                    requireProduction: true
                )
            } catch {
                guard allowCorruptOwnedApp,
                      Self.isOwnedDirectory(observedAppBackup!) else {
                    throw error
                }
            }
        }
        if hasPlistBackup {
            do {
                try Self.validateLaunchAgent(
                    plistBackup,
                    executable: backupExecutable
                )
            } catch {
                let pairedArtifact: BundleArtifactIdentity
                if hasAppBackup {
                    guard let backupArtifact else {
                        throw InstallationLifecycleError.unverifiedInstalledState
                    }
                    pairedArtifact = backupArtifact
                } else {
                    pairedArtifact = try Self.verifyBundle(
                        prior.appPath,
                        requireProduction: true
                    )
                }
                guard Self.isKnownPredecessorRelease(pairedArtifact.release) else {
                    throw error
                }
                try Self.validatePredecessorLaunchAgent(
                    plistBackup,
                    executable: backupExecutable
                )
            }
        }
        if hasAppBackup {
            if Self.pathExists(backupTarget) {
                try removeValidatedBundle(backupTarget)
            }
            try renameOwned(observedAppBackup!, backupTarget)
        }
        if hasPlistBackup {
            if Self.pathExists(paths.launchAgent) {
                try removeValidatedRegular(paths.launchAgent)
            }
            try renameOwned(plistBackup, paths.launchAgent)
        }
        if hasAppBackup || hasPlistBackup {
            prior = try inspectPrior(allowCorruptOwnedApp: allowCorruptOwnedApp)
            return
        }

        if prior.artifact != nil, !prior.plistExists {
            guard prior.artifact?.release.sameInstallContract(as: source.release) == true else {
                throw InstallationLifecycleError.unverifiedInstalledState
            }
            try removeValidatedBundle(prior.appPath)
            prior = try inspectPrior()
        } else if !prior.appExists, prior.plistExists {
            try Self.validateLaunchAgent(paths.launchAgent, executable: executablePath)
            try removeValidatedRegular(paths.launchAgent)
            prior = try inspectPrior()
        }
    }

    private func stage(
        sourceBundle: String,
        source: BundleArtifactIdentity
    ) throws {
        guard !Self.pathExists(appIncoming),
              !Self.pathExists(plistIncoming),
              !Self.pathExists(appBackup),
              !Self.pathExists(predecessorAppBackup),
              !Self.pathExists(legacyPredecessorAppBackup),
              !Self.pathExists(plistBackup) else {
            throw InstallationLifecycleError.unexpectedResidue
        }
        let nonce = RunIdentity.make()
        let appIncomplete = appParent + "/.ShadowSync.app.incomplete.\(nonce)"
        let plistIncomplete = plistParent
            + "/.com.kleinperkins.shadow-sync.plist.incomplete.\(nonce)"
        try fileManager.copyItem(atPath: sourceBundle, toPath: appIncomplete)
        try Self.normalizeAndSyncBundle(appIncomplete)
        let copied = try Self.verifyBundle(appIncomplete, requireProduction: true)
        guard copied.canonicalSHA256 == source.canonicalSHA256,
              copied.release == source.release else {
            let sourceOnly = Set(source.inventory).subtracting(copied.inventory).first
            let copiedOnly = Set(copied.inventory).subtracting(source.inventory).first
            let detail = "source=\(sourceOnly ?? "none") copied=\(copiedOnly ?? "none")"
                .replacingOccurrences(of: "\0", with: "|")
            throw InstallationLifecycleError.unsafeInstallPath(
                "staged bundle differs: \(detail)"
            )
        }
        try renameOwned(appIncomplete, appIncoming)
        let object = Self.launchAgentDictionary(executable: executablePath)
        let rendered = try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .xml,
            options: 0
        )
        // Creation must not truncate a colliding name or follow a symlink.
        // Use the exact descriptor through writing and sync; Foundation's
        // convenience creator may require access outside the admitted fixture.
        let plistDescriptor = Darwin.open(
            plistIncomplete,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard plistDescriptor >= 0 else {
            throw InstallationLifecycleError.system("create staged LaunchAgent", errno)
        }
        defer { close(plistDescriptor) }
        try rendered.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else {
                throw InstallationLifecycleError.invalidLaunchAgent
            }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(plistDescriptor, start.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw InstallationLifecycleError.system("write staged LaunchAgent", count < 0 ? errno : EIO)
                }
                offset += count
            }
        }
        guard fsync(plistDescriptor) == 0 else {
            throw InstallationLifecycleError.system("fsync staged LaunchAgent", errno)
        }
        try renameOwned(plistIncomplete, plistIncoming)
        try Self.validateLaunchAgent(plistIncoming, executable: executablePath)
    }

    private func backupPrior(_ prior: Prior) throws {
        if prior.appExists {
            try renameOwned(prior.appPath, prior.backupPath)
        }
        if prior.plistExists {
            try renameOwned(paths.launchAgent, plistBackup)
        }
    }

    private func rollback(
        prior: Prior,
        restartPriorHost: Bool,
        replacementRelease: ReleaseIdentity? = nil,
        coordinationBackup: CoordinationBackup? = nil
    ) throws {
        if let loaded = try loadedProgram() {
            let loadedBundle = loaded == prior.executable
                ? prior.appPath
                : paths.app
            if let release = try? ReleaseIdentity.load(bundlePath: loadedBundle) {
                try? host.requestExit(
                    location: paths.state,
                    executable: loaded,
                    release: release
                )
            }
            try? launchAgent.bootout(
                label: InstallationPaths.label,
                expectedProgram: loaded
            )
        }
        let rollbackLauncher = try acquireLauncherAfterDrain()
        do {
            if let replacementRelease {
                try removeStoppedHostCoordination(
                    expectedReleases: [replacementRelease],
                    expectedExecutable: executablePath,
                    allowStagedBackup: coordinationBackup != nil
                )
            }
            if Self.pathExists(prior.backupPath) {
                if Self.pathExists(paths.app) {
                    try removeValidatedBundle(paths.app)
                }
                if Self.pathExists(prior.appPath) {
                    try removeValidatedBundle(prior.appPath)
                }
                try renameOwned(prior.backupPath, prior.appPath)
            } else if !prior.appExists, Self.pathExists(paths.app) {
                try removeValidatedBundle(paths.app)
            }
            if Self.pathExists(plistBackup) {
                if Self.pathExists(paths.launchAgent) {
                    try removeValidatedRegular(paths.launchAgent)
                }
                try renameOwned(plistBackup, paths.launchAgent)
            } else if !prior.plistExists, Self.pathExists(paths.launchAgent) {
                try removeValidatedRegular(paths.launchAgent)
            }
            try removeValidatedIncoming()
            if let coordinationBackup {
                try restoreStagedCoordination(coordinationBackup)
            }
        } catch {
            rollbackLauncher.release()
            throw error
        }
        rollbackLauncher.release()
        if prior.requiresInertRecovery {
            // Restore verified preimages only. Registration and restart are not
            // rollback rights for the legacy generation.
            guard try loadedProgram() == nil else {
                throw InstallationLifecycleError.launchAgentMismatch
            }
            return
        }
        if prior.loadedProgram != nil, Self.pathExists(paths.launchAgent) {
            try launchAgent.bootstrap(
                label: InstallationPaths.label,
                plist: paths.launchAgent,
                expectedProgram: prior.executable
            )
            guard try loadedProgram() == prior.executable else {
                throw InstallationLifecycleError.launchAgentMismatch
            }
            if restartPriorHost, let priorRelease = prior.artifact?.release {
                try launchAgent.kickstart(
                    label: InstallationPaths.label,
                    expectedProgram: prior.executable
                )
                guard let readyIdentity = host.readyIdentity(
                    location: paths.state,
                    executable: prior.executable,
                    release: priorRelease,
                    timeout: 5
                ) else {
                    throw InstallationLifecycleError.hostNotReady
                }
                _ = try InstalledStateAdmission.requireLoadedProcess(
                    launchAgent: launchAgent,
                    executable: prior.executable,
                    expectedProcessID: readyIdentity.processID
                )
            } else if let priorRelease = prior.artifact?.release,
                      host.isReady(
                location: paths.state,
                        executable: prior.executable,
                release: priorRelease,
                timeout: 0.25
            ) {
                try host.requestExit(
                    location: paths.state,
                    executable: prior.executable,
                    release: priorRelease
                )
            }
        }
    }

    private func acquireLauncherAfterDrain() throws -> LauncherAuthority {
        let deadline = MonotonicDeadline(seconds: 5)
        repeat {
            do {
                return try LauncherAuthority.acquireWithinLifecycle(at: paths.state)
            } catch let SecureStateError.contention(name) where name == "launcher.lock" {
                Thread.sleep(forTimeInterval: 0.05)
            } catch {
                throw error
            }
        } while !deadline.hasExpired
        throw InstallationLifecycleError.launcherDidNotExit
    }

    private func loadedProgram() throws -> String? {
        switch launchAgent.state(label: InstallationPaths.label) {
        case .absent:
            return nil
        case let .loaded(program, _):
            return program
        case .queryFailure:
            throw InstallationLifecycleError.launchctl("print", -1)
        }
    }

    private func removeBackups(cleanupPrefix: String) throws {
        for backup in appBackupPaths where Self.pathExists(backup) {
            try removeOwnedTree(
                backup,
                quarantineFault: "\(cleanupPrefix)-app-quarantined"
            )
            try fault("\(cleanupPrefix)-app-removed")
        }
        if Self.pathExists(plistBackup) {
            try removeValidatedRegular(
                plistBackup,
                quarantineFault: "\(cleanupPrefix)-plist-quarantined"
            )
            try fault("\(cleanupPrefix)-plist-removed")
        }
        try removeValidatedIncoming()
        try fault("\(cleanupPrefix)-incoming-removed")
    }

    private func isCommittedUninstallResidue(prior: Prior) throws -> Bool {
        guard !prior.appExists,
              !prior.plistExists,
              prior.loadedProgram == nil,
              !Self.pathExists(appIncoming),
              !Self.pathExists(plistIncoming) else {
            return false
        }
        let names = try lifecycleSlotNames()
        guard !names.contains(where: { $0.contains(".incomplete.") }) else {
            return false
        }
        let appQuarantines = names.filter {
            $0.hasPrefix(".ShadowSync.app.quarantine.")
                || $0.hasPrefix(".Dev Main Sync.app.quarantine.")
        }
        let plistQuarantines = names.filter {
            $0.hasPrefix(".com.kleinperkins.shadow-sync.plist.quarantine.")
        }
        guard appQuarantines.count <= 1,
              plistQuarantines.count <= 1,
              Self.pathExists(appBackup)
                || !existingPredecessorBackups.isEmpty
                || Self.pathExists(plistBackup)
                || !appQuarantines.isEmpty
                || !plistQuarantines.isEmpty else {
            return false
        }
        var origins: [(artifact: BundleArtifactIdentity, programs: [String])] = []
        for backup in appBackupPaths where Self.pathExists(backup) {
            let artifact = try Self.verifyBundle(backup, requireProduction: true)
            origins.append((artifact, predecessorBackupPaths.contains(backup)
                ? [paths.predecessorExecutable] : [executablePath]))
        }
        for name in appQuarantines {
            let artifact = try Self.verifyBundle(appParent + "/" + name, requireProduction: true)
            origins.append((artifact, Self.isKnownPredecessorRelease(artifact.release)
                ? [executablePath, paths.predecessorExecutable] : [executablePath]))
        }
        func validatePreservedPlist(_ path: String) throws {
            guard !origins.isEmpty else {
                // Preserve the existing current-contract-only rule when the
                // application cleanup has already removed its provenance.
                try Self.validateLaunchAgent(path, executable: executablePath)
                return
            }
            let matches = Set(origins.flatMap { origin in
                origin.programs.filter { program in
                    if (try? Self.validateLaunchAgent(path, executable: program)) != nil {
                        return true
                    }
                    return Self.isKnownPredecessorRelease(origin.artifact.release)
                        && (try? Self.validatePredecessorLaunchAgent(path, executable: program)) != nil
                }
            })
            guard matches.count == 1 else {
                throw InstallationLifecycleError.invalidLaunchAgent
            }
        }
        if Self.pathExists(plistBackup) {
            try validatePreservedPlist(plistBackup)
        }
        for name in plistQuarantines {
            try validatePreservedPlist(plistParent + "/" + name)
        }
        return true
    }

    private func finishCommittedUninstallResidue() throws {
        if Self.pathExists(appBackup) {
            try removeOwnedTree(
                appBackup,
                quarantineFault: "uninstall-recovery-cleanup-app-quarantined"
            )
        }
        for backup in existingPredecessorBackups {
            try removeOwnedTree(
                backup,
                quarantineFault: "uninstall-recovery-cleanup-app-quarantined"
            )
        }
        if Self.pathExists(plistBackup) {
            try removeValidatedRegular(
                plistBackup,
                quarantineFault: "uninstall-recovery-cleanup-plist-quarantined"
            )
        }
        let names = try lifecycleSlotNames()
        for name in names {
            if name.hasPrefix(".ShadowSync.app.quarantine.")
                || name.hasPrefix(".Dev Main Sync.app.quarantine.") {
                try removeValidatedBundle(appParent + "/" + name)
            } else if name.hasPrefix(
                ".com.kleinperkins.shadow-sync.plist.quarantine."
            ) {
                try removeValidatedRegular(plistParent + "/" + name)
            } else {
                throw InstallationLifecycleError.unexpectedResidue
            }
        }
    }

    private func retireCoordinationLocks(authority: RunAuthority) throws {
        try authority.acquireRetirementNamespace()
        try authority.stateDirectory.removeStableLockFiles { name in
            try fault("uninstall-retired-\(name)")
        }
    }

    private func removeValidatedIncoming() throws {
        try removeOwnedIncompleteAndQuarantine()
        if Self.pathExists(appIncoming) {
            try removeValidatedBundle(appIncoming)
        }
        if Self.pathExists(plistIncoming) {
            try removeValidatedRegular(plistIncoming)
        }
    }

    private func lifecycleSlotNames() throws -> [String] {
        let appNames = try fileManager.contentsOfDirectory(atPath: appParent).filter {
            $0.hasPrefix(".ShadowSync.app.incomplete.")
                || $0.hasPrefix(".ShadowSync.app.quarantine.")
                || $0.hasPrefix(".Dev Main Sync.app.incomplete.")
                || $0.hasPrefix(".Dev Main Sync.app.quarantine.")
        }
        let plistNames = try fileManager.contentsOfDirectory(atPath: plistParent).filter {
            $0.hasPrefix(".com.kleinperkins.shadow-sync.plist.incomplete.")
                || $0.hasPrefix(".com.kleinperkins.shadow-sync.plist.quarantine.")
        }
        return appNames + plistNames
    }

    private func removeOwnedIncompleteAndQuarantine() throws {
        for parent in [appParent, plistParent] {
            let names = try fileManager.contentsOfDirectory(atPath: parent).filter {
                $0.contains(".incomplete.") || $0.contains(".quarantine.")
            }
            for name in names {
                guard name.hasPrefix(".ShadowSync.app.incomplete.")
                        || name.hasPrefix(".ShadowSync.app.quarantine.")
                        || name.hasPrefix(".Dev Main Sync.app.incomplete.")
                        || name.hasPrefix(".Dev Main Sync.app.quarantine.")
                        || name.hasPrefix(".com.kleinperkins.shadow-sync.plist.incomplete.")
                        || name.hasPrefix(".com.kleinperkins.shadow-sync.plist.quarantine.") else {
                    continue
                }
                let source = parent + "/" + name
                var info = stat()
                guard lstat(source, &info) == 0,
                      info.st_uid == geteuid(),
                      (info.st_mode & S_IFMT) == S_IFDIR
                        || ((info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1) else {
                    throw InstallationLifecycleError.unsafeInstallPath(source)
                }
                let quarantine: String
                if name.contains(".quarantine.") {
                    quarantine = source
                } else {
                    if parent == appParent {
                        quarantine = appQuarantinePath(for: source)
                    } else {
                        quarantine = parent + "/" + name.replacingOccurrences(
                            of: ".incomplete.",
                            with: ".quarantine."
                        )
                    }
                    try renameOwned(source, quarantine)
                }
                try fileManager.removeItem(atPath: quarantine)
            }
        }
    }

    private func coordinationReleases(
        prior: Prior,
        allowCorruptOwnedApp: Bool = false
    ) throws -> [ReleaseIdentity] {
        var releases: [ReleaseIdentity] = []
        if let artifact = prior.artifact,
           prior.plistValid || prior.predecessorPlistValid {
            releases.append(artifact.release)
        }
        let quarantinedBackups = try lifecycleSlotNames()
            .filter {
                $0.hasPrefix(".ShadowSync.app.quarantine.")
                    || $0.hasPrefix(".Dev Main Sync.app.quarantine.")
            }
            .map { appParent + "/" + $0 }
        let appBackups =
            appBackupPaths.filter {
                Self.pathExists($0)
            } + quarantinedBackups
        guard appBackups.count <= 1 else {
            throw InstallationLifecycleError.unexpectedResidue
        }
        let observedAppBackup = appBackups.first
        let hasAppBackup = observedAppBackup != nil
        let backupExecutable = observedAppBackup.map {
            predecessorBackupPaths.contains($0)
                || $0.hasPrefix(appParent + "/.Dev Main Sync.app.quarantine.")
        } == true
            ? paths.predecessorExecutable
            : executablePath
        let hasPlistBackup = Self.pathExists(plistBackup)
        if hasAppBackup || hasPlistBackup {
            let artifact: BundleArtifactIdentity
            if hasAppBackup {
                do {
                    artifact = try Self.verifyBundle(
                        observedAppBackup!,
                        requireProduction: true
                    )
                } catch {
                    guard allowCorruptOwnedApp,
                          Self.isOwnedDirectory(observedAppBackup!) else {
                        throw error
                    }
                    if hasPlistBackup {
                        try Self.validateLaunchAgent(
                            plistBackup,
                            executable: backupExecutable
                        )
                    } else {
                        guard prior.artifact == nil,
                              Self.pathExists(paths.launchAgent) else {
                            throw error
                        }
                    }
                    return releases
                }
            } else {
                guard let installed = prior.artifact else {
                    throw InstallationLifecycleError.unexpectedResidue
                }
                artifact = installed
            }
            let pairedPlist = hasPlistBackup
                ? plistBackup
                : paths.launchAgent
            guard Self.pathExists(pairedPlist) else {
                throw InstallationLifecycleError.unexpectedResidue
            }
            let knownPredecessor = Self.isKnownPredecessorRelease(artifact.release)
            let isQuarantinedBackup = observedAppBackup.map {
                quarantinedBackups.contains($0)
            } == true
            // Quarantine has the permanent name regardless of its origin. For
            // a verified predecessor only, derive that origin from the complete
            // preserved plist contract, not the newly written quarantine name.
            let candidates = isQuarantinedBackup && knownPredecessor
                ? [executablePath, paths.predecessorExecutable]
                : [hasAppBackup ? backupExecutable : prior.executable]
            let matchingPrograms = candidates.filter { program in
                if (try? Self.validateLaunchAgent(pairedPlist, executable: program)) != nil {
                    return true
                }
                return knownPredecessor && (try? Self.validatePredecessorLaunchAgent(
                    pairedPlist, executable: program
                )) != nil
            }
            guard matchingPrograms.count == 1 else {
                throw InstallationLifecycleError.invalidLaunchAgent
            }
            if !releases.contains(artifact.release) {
                releases.append(artifact.release)
            }
        }
        return releases
    }

    private func stageDeadHostCoordination(
        expectedReleases: [ReleaseIdentity],
        expectedExecutable: String
    ) throws -> CoordinationBackup? {
        guard let preview = try previewDeadHostCoordination(
            expectedReleases: expectedReleases,
            expectedExecutable: expectedExecutable
        ) else { return nil }
        try fault("after-dead-coordination-preview")
        try preview.state.renameOwnedEntry(
            named: "host-owner.json",
            to: Self.ownerBackupName,
            expected: preview.owner
        )
        do {
            try preview.state.renameOwnedEntry(
                named: "host.sock",
                to: Self.socketBackupName,
                expected: preview.socket
            )
        } catch {
            try? preview.state.renameOwnedEntry(
                named: Self.ownerBackupName,
                to: "host-owner.json",
                expected: preview.owner
            )
            throw error
        }
        return CoordinationBackup(
            owner: preview.owner,
            socket: preview.socket
        )
    }

    private func previewDeadHostCoordination(
        expectedReleases: [ReleaseIdentity],
        expectedExecutable: String
    ) throws -> DeadCoordinationPreview? {
        let (state, entries) = try validatedCoordinationState(
            allowStagedBackup: false
        )
        let hasOwner = entries.contains("host-owner.json")
        let hasSocket = entries.contains("host.sock")
        guard hasOwner == hasSocket else {
            throw InstallationLifecycleError.unexpectedStateEntry
        }
        guard hasOwner else { return nil }
        let registration = try HostRegistrationStore.readPersisted(
            state: state
        )
        guard let release = registration.release,
              expectedReleases.contains(release),
              registration.identity.executablePath == expectedExecutable,
              registration.identity.processID > 1,
              !registration.identity.isCurrent(
                requireGroupLeader: false
              ) else {
            throw InstallationLifecycleError.unverifiedInstalledState
        }
        let owner = try state.ownedEntryIdentity(
            named: "host-owner.json",
            allowSocket: false
        )
        let socket = try state.ownedEntryIdentity(
            named: "host.sock",
            allowSocket: true
        )
        guard owner.isRegular,
              mode_t(owner.mode) & 0o777 == 0o600,
              mode_t(socket.mode) & S_IFMT == S_IFSOCK,
              mode_t(socket.mode) & 0o777 == 0o600 else {
            throw InstallationLifecycleError.unverifiedInstalledState
        }
        return DeadCoordinationPreview(
            state: state,
            owner: owner,
            socket: socket
        )
    }

    private func recoverStagedCoordination(
        replacementRelease: ReleaseIdentity,
        expectedBackupReleases: [ReleaseIdentity],
        expectedBackupExecutable: String,
        expectedBackup: CoordinationBackup? = nil
    ) throws {
        guard let preview = try previewStagedCoordination(
            expectedBackupReleases: expectedBackupReleases,
            expectedExecutable: expectedBackupExecutable
        ) else { return }
        if let expectedBackup {
            guard preview.backup.owner.matchesStableNode(
                expectedBackup.owner
            ),
            preview.backup.socket.matchesStableNode(
                expectedBackup.socket
            ) else {
                throw InstallationLifecycleError.unexpectedStateEntry
            }
        }
        let (_, entries) = try validatedCoordinationState(
            allowStagedBackup: true
        )
        if entries.contains("host-owner.json") {
            try removeStoppedHostCoordination(
                expectedReleases: [replacementRelease],
                expectedExecutable: executablePath,
                allowStagedBackup: true
            )
        }
        try restoreStagedCoordination(preview.backup)
    }

    private func stagedCoordinationExists() throws -> Bool {
        let (_, entries) = try validatedCoordinationState(
            allowStagedBackup: true
        )
        return entries.contains(Self.ownerBackupName)
    }

    private func activeCoordinationExists() throws -> Bool {
        let (_, entries) = try validatedCoordinationState(
            allowStagedBackup: false
        )
        let hasOwner = entries.contains("host-owner.json")
        let hasSocket = entries.contains("host.sock")
        guard hasOwner == hasSocket else {
            throw InstallationLifecycleError.unexpectedStateEntry
        }
        return hasOwner
    }

    private func previewStagedCoordination(
        expectedBackupReleases: [ReleaseIdentity],
        expectedExecutable: String
    ) throws -> StagedCoordinationPreview? {
        let (state, entries) = try validatedCoordinationState(
            allowStagedBackup: true
        )
        let hasOwnerBackup = entries.contains(Self.ownerBackupName)
        let hasSocketBackup = entries.contains(Self.socketBackupName)
        guard hasOwnerBackup == hasSocketBackup else {
            throw InstallationLifecycleError.unexpectedStateEntry
        }
        guard hasOwnerBackup else { return nil }
        let registration = try HostRegistrationStore.readPersisted(
            state: state,
            named: Self.ownerBackupName
        )
        guard let backupRelease = registration.release,
              expectedBackupReleases.contains(backupRelease),
              registration.identity.executablePath == expectedExecutable,
              registration.identity.processID > 1,
              !registration.identity.isCurrent(requireGroupLeader: false) else {
            throw InstallationLifecycleError.unverifiedInstalledState
        }
        return StagedCoordinationPreview(
            backup: CoordinationBackup(
                owner: try state.ownedEntryIdentity(
                    named: Self.ownerBackupName,
                    allowSocket: false
                ),
                socket: try state.ownedEntryIdentity(
                    named: Self.socketBackupName,
                    allowSocket: true
                )
            )
        )
    }

    private func restoreStagedCoordination(
        _ backup: CoordinationBackup
    ) throws {
        let (state, entries) = try validatedCoordinationState(
            allowStagedBackup: true
        )
        guard !entries.contains("host-owner.json"),
              !entries.contains("host.sock") else {
            throw InstallationLifecycleError.unexpectedStateEntry
        }
        try state.renameOwnedEntry(
            named: Self.socketBackupName,
            to: "host.sock",
            expected: backup.socket
        )
        do {
            try state.renameOwnedEntry(
                named: Self.ownerBackupName,
                to: "host-owner.json",
                expected: backup.owner
            )
        } catch {
            try? state.renameOwnedEntry(
                named: "host.sock",
                to: Self.socketBackupName,
                expected: backup.socket
            )
            throw error
        }
    }

    private func removeStagedCoordination(
        _ backup: CoordinationBackup
    ) throws {
        let (state, entries) = try validatedCoordinationState(
            allowStagedBackup: true
        )
        guard entries.contains(Self.ownerBackupName),
              entries.contains(Self.socketBackupName) else {
            throw InstallationLifecycleError.unexpectedStateEntry
        }
        try state.removeOwnedEntry(
            named: Self.ownerBackupName,
            expected: backup.owner
        )
        try state.removeOwnedEntry(
            named: Self.socketBackupName,
            expected: backup.socket
        )
    }

    private func removeStoppedHostCoordination(
        expectedReleases: [ReleaseIdentity],
        expectedExecutable: String,
        allowStagedBackup: Bool = false
    ) throws {
        let state = try SecureStateDirectory.openExisting(
            paths.state
        )
        let observedEntries = Set(
            try fileManager.contentsOfDirectory(atPath: state.path)
        )
        let hasOwner = observedEntries.contains("host-owner.json")
        let hasSocket = observedEntries.contains("host.sock")
        guard hasOwner == hasSocket else {
            throw InstallationLifecycleError.unexpectedStateEntry
        }
        guard hasOwner else { return }
        let (_, entries) = try validatedCoordinationState(
            allowStagedBackup: allowStagedBackup
        )
        guard entries.contains("host-owner.json"),
              entries.contains("host.sock") else {
            throw InstallationLifecycleError.unexpectedStateEntry
        }
        let registration = try HostRegistrationStore.readPersisted(state: state)
        guard let release = registration.release,
              expectedReleases.contains(release),
              registration.identity.executablePath == expectedExecutable,
              registration.identity.processID > 1,
              !registration.identity.isCurrent(requireGroupLeader: false) else {
            throw InstallationLifecycleError.unverifiedInstalledState
        }
        let socket = try state.ownedEntryIdentity(
            named: "host.sock",
            allowSocket: true
        )
        guard mode_t(socket.mode) & S_IFMT == S_IFSOCK,
              mode_t(socket.mode) & 0o777 == 0o600 else {
            throw InstallationLifecycleError.unverifiedInstalledState
        }
        try removeCoordinationState(
            allowStagedBackup: allowStagedBackup
        )
    }

    private func removeCoordinationState(
        allowStagedBackup: Bool = false
    ) throws {
        try Self.removeCoordinationState(
            at: paths.state,
            fileManager: fileManager,
            allowStagedBackup: allowStagedBackup
        )
    }

    private static func removeCoordinationState(
        at location: StateLocation,
        fileManager: FileManager,
        allowStagedBackup: Bool = false
    ) throws {
        let (state, entries) = try validatedCoordinationState(
            at: location,
            fileManager: fileManager,
            allowStagedBackup: allowStagedBackup
        )
        let removalOrder = ["host-owner.json", "host.sock"]
        var identities: [String: FileIdentity] = [:]
        for name in removalOrder where entries.contains(name) {
            identities[name] = try state.ownedEntryIdentity(
                named: name,
                allowSocket: name == "host.sock"
            )
        }
        for name in removalOrder {
            if let expected = identities[name] {
                try state.removeOwnedEntry(named: name, expected: expected)
            }
        }
    }

    private func validatedCoordinationState(
        allowStagedBackup: Bool
    ) throws -> (SecureStateDirectory, Set<String>) {
        try Self.validatedCoordinationState(
            at: paths.state,
            fileManager: fileManager,
            allowStagedBackup: allowStagedBackup
        )
    }

    private static func validatedCoordinationState(
        at location: StateLocation,
        fileManager: FileManager,
        allowStagedBackup: Bool
    ) throws -> (SecureStateDirectory, Set<String>) {
        let state = try SecureStateDirectory.openExisting(location)
        let allowed = Set([
            "latest.log", "host-owner.json", "host.sock", "launcher.lock",
            "lifecycle.lock", "operation.lock", "run.lock",
            RepositoryAuthorityStore.filename,
            RepositorySelectionPreferenceStore.filename,
            RepositorySelectionPreferenceStore.recoveryFilename,
            "retention",
        ] + (allowStagedBackup ? [
            Self.ownerBackupName, Self.socketBackupName,
        ] : []))
        let entries = Set(
            try fileManager.contentsOfDirectory(atPath: state.path)
        )
        guard entries.isSubset(of: allowed) else {
            throw InstallationLifecycleError.unexpectedStateEntry
        }
        if entries.contains("latest.log") {
            let log = try state.ownedEntryIdentity(
                named: "latest.log",
                allowSocket: false
            )
            guard log.isRegular,
                  mode_t(log.mode) & 0o777 == 0o600 else {
                throw InstallationLifecycleError.unexpectedStateEntry
            }
            do {
                try DurableRunLogEvidence.validate(state: state)
            } catch {
                throw InstallationLifecycleError.unexpectedStateEntry
            }
        }
        if entries.contains(RepositoryAuthorityStore.filename) {
            let authority = try state.ownedEntryIdentity(
                named: RepositoryAuthorityStore.filename,
                allowSocket: false
            )
            guard authority.isRegular,
                  mode_t(authority.mode) & 0o777 == 0o600,
                  RepositoryAuthorityStore(state: state).snapshot().status
                    == .available else {
                throw InstallationLifecycleError.unexpectedStateEntry
            }
        }
        if entries.contains(
            RepositorySelectionPreferenceStore.filename
        ) {
            let preferences =
                RepositorySelectionPreferenceStore(
                    state: state
                ).snapshot()
            guard preferences.status == .available else {
                throw InstallationLifecycleError
                    .unexpectedStateEntry
            }
        }
        if entries.contains(
            RepositorySelectionPreferenceStore.recoveryFilename
        ) {
            let recovery = try state.ownedEntryIdentity(
                named:
                    RepositorySelectionPreferenceStore
                        .recoveryFilename,
                allowSocket: false
            )
            guard recovery.isRegular,
                  mode_t(recovery.mode) & 0o777 == 0o600 else {
                throw InstallationLifecycleError
                    .unexpectedStateEntry
            }
        }
        if entries.contains("retention") {
            let account = try EffectiveAccount.current()
            _ = try RetentionArtifactStore(
                state: state,
                account: account
            ).list()
        }
        let hasOwnerBackup = entries.contains(Self.ownerBackupName)
        let hasSocketBackup = entries.contains(Self.socketBackupName)
        guard hasOwnerBackup == hasSocketBackup else {
            throw InstallationLifecycleError.unexpectedStateEntry
        }
        if hasOwnerBackup {
            let owner = try state.ownedEntryIdentity(
                named: Self.ownerBackupName,
                allowSocket: false
            )
            let socket = try state.ownedEntryIdentity(
                named: Self.socketBackupName,
                allowSocket: true
            )
            guard owner.isRegular,
                  mode_t(owner.mode) & 0o777 == 0o600,
                  mode_t(socket.mode) & S_IFMT == S_IFSOCK,
                  mode_t(socket.mode) & 0o777 == 0o600 else {
                throw InstallationLifecycleError.unexpectedStateEntry
            }
        }
        return (state, entries)
    }

    #if SHADOW_SYNC_TESTING
    public static func testingPreserveAuthorityDuringRemoval(
        at location: StateLocation
    ) throws {
        try removeCoordinationState(
            at: location,
            fileManager: .default
        )
    }
    #endif

    fileprivate static func verifyBundle(
        _ path: String,
        requireProduction: Bool
    ) throws -> BundleArtifactIdentity {
        guard LifecycleCommandRunner.verifySignature(at: path) else {
            throw InstallationLifecycleError.invalidSignature
        }
        return try BundleArtifactIdentity.inspect(
            bundlePath: path,
            requireProduction: requireProduction
        )
    }

    fileprivate static func validateLaunchAgent(
        _ path: String,
        executable: String
    ) throws {
        try validateLaunchAgent(
            path,
            executable: executable,
            programArguments: [
                executable, InstallationPaths.managedHostArgument,
            ]
        )
    }

    private static func validatePredecessorLaunchAgent(
        _ path: String,
        executable: String
    ) throws {
        try validateLaunchAgent(
            path,
            executable: executable,
            programArguments: [executable]
        )
    }

    private static func validateLaunchAgent(
        _ path: String,
        executable: String,
        programArguments: [String]
    ) throws {
        _ = try captureLaunchAgent(path, programArguments: programArguments)
    }

    /// A retained integrity snapshot for the fixed launch configuration. It is
    /// not launch authority; callers still need their actual lifecycle leases.
    private static func captureLaunchAgent(
        _ path: String,
        programArguments: [String],
        afterRead: () throws -> Void = {}
    ) throws -> PolicyAuthorityFile {
        let file: PolicyAuthorityFile
        do { file = try PolicyAuthorityFile.read(path: path, owner: geteuid(), maximumBytes: 65_536) }
        catch { throw InstallationLifecycleError.invalidLaunchAgent }
        try afterRead()
        guard file.hasOwnerPrivateMode,
              let dictionary = try? PropertyListSerialization.propertyList(from: file.bytes, format: nil) as? [String: Any],
              Set(dictionary.keys) == Set([
                "Label", "ProgramArguments", "RunAtLoad", "KeepAlive",
                "ProcessType", "LimitLoadToSessionType",
              ]),
              dictionary["Label"] as? String == InstallationPaths.label,
              dictionary["ProgramArguments"] as? [String] == programArguments,
              dictionary["RunAtLoad"] as? Bool == false,
              dictionary["KeepAlive"] as? Bool == false,
              dictionary["ProcessType"] as? String == "Interactive",
              dictionary["LimitLoadToSessionType"] as? String == "Aqua" else {
            throw InstallationLifecycleError.invalidLaunchAgent
        }
        do { try file.revalidate() }
        catch { throw InstallationLifecycleError.invalidLaunchAgent }
        return file
    }

    static func captureCurrentLaunchAgent(_ path: String, executable: String) throws -> PolicyAuthorityFile {
        try captureLaunchAgent(path, programArguments: [executable, InstallationPaths.managedHostArgument])
    }

    #if SHADOW_SYNC_TESTING
    static func testingCaptureLaunchAgent(_ path: String, executable: String,
                                         afterRead: () throws -> Void = {}) throws -> PolicyAuthorityFile {
        try captureLaunchAgent(path, programArguments: [executable, InstallationPaths.managedHostArgument],
                               afterRead: afterRead)
    }
    #endif

    private static func isKnownPredecessorRelease(
        _ release: ReleaseIdentity
    ) -> Bool {
        release.sourceRevision
            == "783fa0587cccdb2c88a6a8b246c1ed0ed536e60b"
            && release.sourceInputSHA256
                == "0aaaad83bb080e6ed0db71de2df9b9010d63a79ceb78dfee73785cfe218ffa7c"
            && release.releaseContractSHA256
                == "08d13f1f8425e952a2aa6d8662eebc846066d135fec806f82b14ba44b9175b5f"
            && release.buildMode == "production"
    }

    private static func launchAgentDictionary(executable: String) -> [String: Any] {
        [
            "Label": InstallationPaths.label,
            "ProgramArguments": [
                executable, InstallationPaths.managedHostArgument,
            ],
            "RunAtLoad": false,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
    }

    #if SHADOW_SYNC_TESTING
    static func testingSyncPublisherBundle(_ root: String, layout: PolicyRuntimeLayout) throws {
        try normalizeAndSyncBundle(root, layoutOverride: PublisherBundleLayout.testing(bundlePath: root, layout: layout))
    }
    #endif

    private static func normalizeAndSyncBundle(_ root: String, layoutOverride: PublisherBundleLayout? = nil) throws {
        let publisherLayout = try layoutOverride ?? PublisherBundleLayout.captureIfPresent(root)
        #if !SHADOW_SYNC_TESTING
        guard publisherLayout != nil else { throw InstallationLifecycleError.unsafeInstallPath(root) }
        #endif
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: nil
        ) else {
            throw InstallationLifecycleError.unsafeInstallPath(root)
        }
        var paths = [root]
        for case let url as URL in enumerator {
            paths.append(url.path)
        }
        for path in paths {
            if let publisherLayout {
                // Signed distribution modes and reviewed framework links are
                // already canonical. Never rewrite them to development modes.
                let relative = path == root ? "" : String(path.dropFirst(root.count + 1))
                _ = try publisherLayout.validateNode(relative)
                continue
            }
            var info = stat()
            guard lstat(path, &info) == 0,
                  info.st_uid == geteuid(),
                  info.st_flags == 0,
                  BundleArtifactIdentity.hasOnlyPermittedXattrs(path) else {
                throw InstallationLifecycleError.unsafeInstallPath(path)
            }
            let type = info.st_mode & S_IFMT
            let mode: mode_t
            if type == S_IFDIR {
                mode = 0o700
            } else if type == S_IFREG, info.st_nlink == 1 {
                mode = path.hasSuffix("/Contents/MacOS/ShadowSync") ? 0o700 : 0o600
            } else {
                throw InstallationLifecycleError.unsafeInstallPath(path)
            }
            guard chmod(path, mode) == 0 else {
                throw InstallationLifecycleError.system("chmod staged bundle", errno)
            }
        }
        try publisherLayout?.requireComplete(Set(paths.map { $0 == root ? "" : String($0.dropFirst(root.count + 1)) }))
        try publisherLayout?.revalidate()
        for path in paths.reversed() {
            if let publisherLayout {
                let relative = path == root ? "" : String(path.dropFirst(root.count + 1))
                if try publisherLayout.validateNode(relative) != nil { continue }
            }
            let descriptor = Darwin.open(
                path,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw InstallationLifecycleError.system("open staged inventory", errno)
            }
            let result = fsync(descriptor)
            close(descriptor)
            guard result == 0 else {
                throw InstallationLifecycleError.system("fsync staged inventory", errno)
            }
        }
        try publisherLayout?.revalidate()
    }

    private static func ensureDirectory(
        _ path: String,
        mode: mode_t,
        mayExist: Bool
    ) throws {
        if !pathExists(path) {
            guard mkdir(path, mode) == 0 else {
                throw InstallationLifecycleError.system("mkdir", errno)
            }
        } else if !mayExist {
            throw InstallationLifecycleError.unsafeInstallPath(path)
        }
        try validateParent(path)
    }

    private func renameOwned(_ source: String, _ destination: String) throws {
        let sourceURL = URL(fileURLWithPath: source)
        let destinationURL = URL(fileURLWithPath: destination)
        let parent = sourceURL.deletingLastPathComponent().path
        guard destinationURL.deletingLastPathComponent().path == parent else {
            throw InstallationLifecycleError.unsafeInstallPath(destination)
        }
        let pin: PinnedParent?
        if parent == appParent {
            pin = pinnedAppParent
        } else if parent == plistParent {
            pin = pinnedPlistParent
        } else {
            pin = nil
        }
        guard let pin else {
            throw InstallationLifecycleError.unsafeInstallPath(parent)
        }
        try pin.validate()
        let descriptor = pin.descriptor
        var sourceInfo = stat()
        guard fstatat(
                descriptor,
                sourceURL.lastPathComponent,
                &sourceInfo,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              sourceInfo.st_uid == geteuid(),
              ((sourceInfo.st_mode & S_IFMT) == S_IFDIR
                || ((sourceInfo.st_mode & S_IFMT) == S_IFREG && sourceInfo.st_nlink == 1)) else {
            throw InstallationLifecycleError.unsafeInstallPath(source)
        }
        var destinationInfo = stat()
        guard fstatat(
            descriptor,
            destinationURL.lastPathComponent,
            &destinationInfo,
            AT_SYMLINK_NOFOLLOW
        ) != 0, errno == ENOENT else {
            throw InstallationLifecycleError.unsafeInstallPath(destination)
        }
        guard renameatx_np(
            descriptor,
            sourceURL.lastPathComponent,
            descriptor,
            destinationURL.lastPathComponent,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw InstallationLifecycleError.system("renameatx_np install target", errno)
        }
        guard fsync(descriptor) == 0 else {
            throw InstallationLifecycleError.system("fsync install parent", errno)
        }
    }

    private static func validateParent(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              (info.st_mode & 0o022) == 0 else {
            throw InstallationLifecycleError.unsafeInstallPath(path)
        }
    }

    private func removeValidatedBundle(_ path: String) throws {
        let before = try BundleArtifactIdentity.inspect(bundlePath: path)
        let quarantine = appQuarantinePath(for: path)
        try renameOwned(path, quarantine)
        let after = try BundleArtifactIdentity.inspect(bundlePath: quarantine)
        guard before == after else {
            throw InstallationLifecycleError.unsafeInstallPath(quarantine)
        }
        try FileManager.default.removeItem(atPath: quarantine)
    }

    private static func isOwnedDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == geteuid()
    }

    private func removeOwnedTree(
        _ path: String,
        quarantineFault: String? = nil
    ) throws {
        guard Self.isOwnedDirectory(path) else {
            throw InstallationLifecycleError.unsafeInstallPath(path)
        }
        let quarantine = appQuarantinePath(for: path)
        try renameOwned(path, quarantine)
        guard Self.isOwnedDirectory(quarantine) else {
            throw InstallationLifecycleError.unsafeInstallPath(quarantine)
        }
        if let quarantineFault {
            try fault(quarantineFault)
        }
        try FileManager.default.removeItem(atPath: quarantine)
    }

    private func appQuarantinePath(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent().path
            + "/.ShadowSync.app.quarantine." + RunIdentity.make()
    }

    private func removeValidatedRegular(
        _ path: String,
        quarantineFault: String? = nil
    ) throws {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1 else {
            throw InstallationLifecycleError.unsafeInstallPath(path)
        }
        let before = FileIdentity(info)
        let quarantine = URL(fileURLWithPath: path).deletingLastPathComponent().path
            + "/.com.kleinperkins.shadow-sync.plist.quarantine.\(RunIdentity.make())"
        try renameOwned(path, quarantine)
        var after = stat()
        guard lstat(quarantine, &after) == 0,
              before.matchesStableNode(FileIdentity(after)) else {
            throw InstallationLifecycleError.unsafeInstallPath(quarantine)
        }
        if let quarantineFault {
            try fault(quarantineFault)
        }
        let parent = URL(fileURLWithPath: quarantine).deletingLastPathComponent().path
        let pin = parent == appParent ? pinnedAppParent : pinnedPlistParent
        guard let pin,
              unlinkat(pin.descriptor, URL(fileURLWithPath: quarantine).lastPathComponent, 0) == 0,
              fsync(pin.descriptor) == 0 else {
            throw InstallationLifecycleError.system("unlinkat quarantine", errno)
        }
    }

    private static func pathExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}

public enum InstalledStateAdmission {
    public static func invocationRole(
        arguments: [String]
    ) throws -> InstalledApplicationRole {
        guard !arguments.isEmpty else {
            throw InstallationLifecycleError.unverifiedInstalledState
        }
        let carriesManagedMarker = arguments.dropFirst().contains(
            InstallationPaths.managedHostArgument
        )
        guard carriesManagedMarker else { return .manual }
        guard arguments.count == 2,
              arguments[1] == InstallationPaths.managedHostArgument else {
            throw InstallationLifecycleError.unverifiedInstalledState
        }
        return .managedHost
    }

    public static func enterInstalledApplication(
        arguments: [String],
        paths: InstallationPaths,
        launchAgent: any LaunchAgentControlling,
        host: any InstalledHostControlling,
        processID: pid_t,
        managedAdmissionTimeout: TimeInterval = 1
    ) throws -> LauncherAuthority? {
        guard processID > 1,
              processID == getpid(),
              managedAdmissionTimeout.isFinite,
              managedAdmissionTimeout >= 0,
              managedAdmissionTimeout <= 1 else {
            throw InstallationLifecycleError.unverifiedInstalledState
        }
        switch try invocationRole(arguments: arguments) {
        case .managedHost:
            return try admitManagedHost(
                paths: paths,
                launchAgent: launchAgent,
                processID: processID,
                timeout: managedAdmissionTimeout
            )
        case .manual:
            try routeManualLaunchToRegisteredHost(
                paths: paths,
                launchAgent: launchAgent,
                host: host,
                callerProcessID: processID,
                startupObservationTimeout: managedAdmissionTimeout
            )
            return nil
        }
    }

    private static func admitManagedHost(
        paths: InstallationPaths,
        launchAgent: any LaunchAgentControlling,
        processID: pid_t,
        timeout: TimeInterval
    ) throws -> LauncherAuthority {
        let executable = paths.app + "/Contents/MacOS/ShadowSync"
        let deadline = MonotonicDeadline(seconds: timeout)
        while true {
            if try managedProcessIsPublished(
                launchAgent: launchAgent,
                executable: executable,
                processID: processID
            ) {
                do {
                    return try admitHost(
                        paths: paths,
                        launchAgent: launchAgent,
                        processID: processID
                    )
                } catch let error as SecureStateError {
                    guard case .contention("launcher.lock") = error else {
                        throw error
                    }
                    if timeout == 0 || deadline.hasExpired {
                        throw error
                    }
                }
            } else if timeout == 0 || deadline.hasExpired {
                throw InstallationLifecycleError.launchAgentMismatch
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }

    private static func managedProcessIsPublished(
        launchAgent: any LaunchAgentControlling,
        executable: String,
        processID: pid_t
    ) throws -> Bool {
        switch launchAgent.state(label: InstallationPaths.label) {
        case .absent:
            throw InstallationLifecycleError.launchAgentMismatch
        case .queryFailure:
            throw InstallationLifecycleError.launchctl("print", -1)
        case let .loaded(program, publishedProcessID):
            guard program == executable else {
                throw InstallationLifecycleError.launchAgentMismatch
            }
            guard let publishedProcessID else { return false }
            guard publishedProcessID > 1,
                  publishedProcessID == processID,
                  launchAgent.processDisposition(
                    processID: publishedProcessID,
                    expectedProgram: executable
                  ) == .matching else {
                throw InstallationLifecycleError.unverifiedInstalledState
            }
            return true
        }
    }

    public static func admitHost(
        paths: InstallationPaths,
        launchAgent: any LaunchAgentControlling,
        processID: pid_t
    ) throws -> LauncherAuthority {
        let lifecycle = try LifecycleAdmissionAuthority.acquire(at: paths.state)
        defer { lifecycle.release() }
        _ = try verifyStatic(
            paths: paths,
            launchAgent: launchAgent,
            allowedProcessID: processID,
            allowStagedLifecycleResidue: true
        )
        do {
            let authority = try LauncherAuthority.acquire(at: paths.state)
            _ = try requireLoadedProcess(
                launchAgent: launchAgent,
                executable: paths.app + "/Contents/MacOS/ShadowSync",
                expectedProcessID: processID
            )
            return authority
        } catch let error as SecureStateError {
            guard case .contention("launcher.lock") = error else { throw error }
            throw error
        }
    }

    public static func verifyRun(
        paths: InstallationPaths,
        launchAgent: any LaunchAgentControlling,
        host: any InstalledHostControlling
    ) throws -> ReleaseIdentity {
        let artifact = try verifyStatic(
            paths: paths,
            launchAgent: launchAgent,
            allowedProcessID: nil
        )
        guard let identity = host.readyIdentity(
            location: paths.state,
            executable: paths.app + "/Contents/MacOS/ShadowSync",
            release: artifact.release,
            timeout: 1
        ) else {
            throw InstallationLifecycleError.hostNotReady
        }
        _ = try requireLoadedProcess(
            launchAgent: launchAgent,
            executable: paths.app + "/Contents/MacOS/ShadowSync",
            expectedProcessID: identity.processID
        )
        return artifact.release
    }

    public static func routeManualLaunchToRegisteredHost(
        paths: InstallationPaths,
        launchAgent: any LaunchAgentControlling,
        host: any InstalledHostControlling,
        callerProcessID: pid_t,
        startupObservationTimeout: TimeInterval = 1
    ) throws {
        guard callerProcessID > 1,
              callerProcessID == getpid(),
              startupObservationTimeout.isFinite,
              startupObservationTimeout >= 0,
              startupObservationTimeout <= 1 else {
            throw InstallationLifecycleError.unverifiedInstalledState
        }
        let lifecycleAdmission = try LifecycleAdmissionAuthority.acquire(
            at: paths.state
        )
        defer { lifecycleAdmission.release() }
        let artifact = try verifyStatic(
            paths: paths,
            launchAgent: launchAgent,
            allowedProcessID: nil,
            allowStoppedLaunchAgent: true,
            allowUnpublishedRegisteredHost: true
        )
        let executable = paths.app + "/Contents/MacOS/ShadowSync"
        var observed = try observeManualLaunchAgent(
            paths: paths,
            launchAgent: launchAgent,
            host: host,
            release: artifact.release,
            executable: executable,
            callerProcessID: callerProcessID,
            timeout: startupObservationTimeout
        )
        if observed == .stopped {
            let launcher: LauncherAuthority?
            do {
                launcher = try LauncherAuthority.acquireWithinLifecycle(
                    at: paths.state
                )
            } catch let error as SecureStateError {
                guard case .contention("launcher.lock") = error else {
                    throw error
                }
                launcher = nil
            }
            if let launcher {
                do {
                    observed = try observeManualLaunchAgent(
                        paths: paths,
                        launchAgent: launchAgent,
                        host: host,
                        release: artifact.release,
                        executable: executable,
                        callerProcessID: callerProcessID,
                        timeout: 0
                    )
                    launcher.release()
                    if observed == .stopped {
                        try requireNoCurrentRegisteredHost(paths: paths)
                        try launchAgent.kickstart(
                            label: InstallationPaths.label,
                            expectedProgram: executable
                        )
                    }
                } catch {
                    launcher.release()
                    throw error
                }
            }
        }
        if case .ready = observed {
            // The host controller verified registration, socket peer, executable,
            // and release while launchd publication was still pending.
        } else {
            guard let readyIdentity = host.readyIdentity(
                location: paths.state,
                executable: executable,
                release: artifact.release,
                timeout: 5
            ) else {
                throw InstallationLifecycleError.hostNotReady
            }
            _ = try requireReadyProcessConvergence(
                launchAgent: launchAgent,
                executable: executable,
                readyIdentity: readyIdentity,
                timeout: startupObservationTimeout
            )
        }
        try HostControlClient.activate(at: paths.state)
    }

    fileprivate enum ManualLaunchAgentObservation: Equatable {
        case ready
        case running
        case stopped
    }

    fileprivate static func observeManualLaunchAgent(
        paths: InstallationPaths,
        launchAgent: any LaunchAgentControlling,
        host: any InstalledHostControlling,
        release: ReleaseIdentity,
        executable: String,
        callerProcessID: pid_t?,
        timeout: TimeInterval
    ) throws -> ManualLaunchAgentObservation {
        let deadline = MonotonicDeadline(seconds: timeout)
        while true {
            var managedProcessID: pid_t?
            switch launchAgent.state(label: InstallationPaths.label) {
            case .absent:
                throw InstallationLifecycleError.launchAgentMismatch
            case .queryFailure:
                throw InstallationLifecycleError.launchctl("print", -1)
            case let .loaded(program, processID):
                guard program == executable else {
                    throw InstallationLifecycleError.launchAgentMismatch
                }
                if let processID {
                    guard processID > 1 else {
                        throw InstallationLifecycleError.unverifiedInstalledState
                    }
                    switch launchAgent.processDisposition(
                        processID: processID,
                        expectedProgram: executable
                    ) {
                    case .absent:
                        break
                    case .matching:
                        guard processID != callerProcessID else {
                            throw InstallationLifecycleError.unverifiedInstalledState
                        }
                        managedProcessID = processID
                    case .mismatch:
                        throw InstallationLifecycleError.unverifiedInstalledState
                    }
                }
            }
            if let readyIdentity = host.readyIdentity(
                location: paths.state,
                executable: executable,
                release: release,
                timeout: 0
            ) {
                if let managedProcessID,
                   readyIdentity.processID != managedProcessID {
                    throw InstallationLifecycleError.unverifiedInstalledState
                }
                return .ready
            }
            if managedProcessID != nil {
                return .running
            }
            if timeout == 0 || deadline.hasExpired {
                return .stopped
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }

    fileprivate static func requireNoCurrentRegisteredHost(
        paths: InstallationPaths
    ) throws {
        let state = try SecureStateDirectory.openExisting(paths.state)
        let entries = Set(
            try FileManager.default.contentsOfDirectory(atPath: state.path)
        )
        let hasOwner = entries.contains("host-owner.json")
        let hasSocket = entries.contains("host.sock")
        guard hasOwner == hasSocket else {
            throw InstallationLifecycleError.unexpectedStateEntry
        }
        if hasOwner {
            let registration = try HostRegistrationStore.readPersisted(
                state: state
            )
            guard !registration.identity.isCurrent(requireGroupLeader: false) else {
                throw InstallationLifecycleError.unverifiedInstalledState
            }
        }
    }

    fileprivate static func requireReadyProcessConvergence(
        launchAgent: any LaunchAgentControlling,
        executable: String,
        readyIdentity: ProcessIdentity,
        timeout: TimeInterval
    ) throws -> pid_t {
        guard readyIdentity.processID > 1,
              timeout.isFinite,
              timeout >= 0,
              timeout <= 1 else {
            throw InstallationLifecycleError.unverifiedInstalledState
        }
        let deadline = MonotonicDeadline(seconds: timeout)
        while true {
            switch launchAgent.state(label: InstallationPaths.label) {
            case .absent:
                throw InstallationLifecycleError.launchAgentMismatch
            case .queryFailure:
                throw InstallationLifecycleError.launchctl("print", -1)
            case let .loaded(program, processID):
                guard program == executable else {
                    throw InstallationLifecycleError.launchAgentMismatch
                }
                if let processID {
                    guard processID > 1 else {
                        throw InstallationLifecycleError.unverifiedInstalledState
                    }
                    switch launchAgent.processDisposition(
                        processID: processID,
                        expectedProgram: executable
                    ) {
                    case .absent:
                        break
                    case .matching:
                        guard processID == readyIdentity.processID else {
                            throw InstallationLifecycleError.unverifiedInstalledState
                        }
                        return processID
                    case .mismatch:
                        throw InstallationLifecycleError.unverifiedInstalledState
                    }
                }
            }
            if timeout == 0 || deadline.hasExpired {
                throw InstallationLifecycleError.unverifiedInstalledState
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }

    @discardableResult
    public static func verifyStatic(
        paths: InstallationPaths,
        launchAgent: any LaunchAgentControlling,
        allowedProcessID: pid_t?,
        allowStoppedLaunchAgent: Bool = false,
        allowStagedLifecycleResidue: Bool = false,
        allowUnpublishedRegisteredHost: Bool = false
    ) throws -> BundleArtifactIdentity {
        let executable = paths.app + "/Contents/MacOS/ShadowSync"
        let appParent = URL(fileURLWithPath: paths.app).deletingLastPathComponent().path
        let plistParent = URL(fileURLWithPath: paths.launchAgent)
            .deletingLastPathComponent().path
        let appTransient = try FileManager.default
            .contentsOfDirectory(atPath: appParent)
            .filter {
                $0.hasPrefix(".ShadowSync.app.")
                    || $0.hasPrefix(".Dev Main Sync.app.")
            }
        let plistTransient = try FileManager.default
            .contentsOfDirectory(atPath: plistParent)
            .filter {
                $0.hasPrefix(".com.kleinperkins.shadow-sync.plist.")
            }
        let state = try SecureStateDirectory.openExisting(paths.state)
        if !appTransient.isEmpty || !plistTransient.isEmpty {
            guard allowStagedLifecycleResidue,
                  Set(appTransient).isSubset(
                    of: [
                        ".ShadowSync.app.previous",
                        ".ShadowSync.app.predecessor.previous",
                        ".Dev Main Sync.app.previous",
                    ]
                  ),
                  Set(plistTransient).isSubset(
                    of: [".com.kleinperkins.shadow-sync.plist.previous"]
                  ),
                  try operationAuthorityIsHeld(state: state) else {
                throw InstallationLifecycleError.unexpectedResidue
            }
            if !appTransient.isEmpty {
                guard appTransient.count == 1 else {
                    throw InstallationLifecycleError.unexpectedResidue
                }
                var info = stat()
                guard lstat(
                    appParent + "/" + appTransient[0],
                    &info
                ) == 0,
                      (info.st_mode & S_IFMT) == S_IFDIR,
                      info.st_uid == geteuid() else {
                    throw InstallationLifecycleError.unexpectedResidue
                }
            }
            if !plistTransient.isEmpty {
                var info = stat()
                guard lstat(
                    plistParent
                        + "/.com.kleinperkins.shadow-sync.plist.previous",
                    &info
                ) == 0,
                      (info.st_mode & S_IFMT) == S_IFREG,
                      info.st_uid == geteuid(),
                      info.st_nlink == 1 else {
                    throw InstallationLifecycleError.unexpectedResidue
                }
            }
        }
        let artifact = try InstallationLifecycle.verifyBundle(
            paths.app,
            requireProduction: true
        )
        try InstallationLifecycle.validateLaunchAgent(
            paths.launchAgent,
            executable: executable
        )
        let loadedProcessID: pid_t?
        switch launchAgent.state(label: InstallationPaths.label) {
        case .absent:
            throw InstallationLifecycleError.launchAgentMismatch
        case .queryFailure:
            throw InstallationLifecycleError.launchctl("print", -1)
        case let .loaded(program, processID):
            guard program == executable else {
                throw InstallationLifecycleError.launchAgentMismatch
            }
            if let processID {
                guard processID > 1 else {
                    throw InstallationLifecycleError.launchAgentMismatch
                }
                switch launchAgent.processDisposition(
                    processID: processID,
                    expectedProgram: executable
                ) {
                case .absent:
                    guard allowStoppedLaunchAgent, allowedProcessID == nil else {
                        throw InstallationLifecycleError.launchAgentMismatch
                    }
                    loadedProcessID = nil
                case .matching:
                    guard allowedProcessID == nil
                            || processID == allowedProcessID else {
                        throw InstallationLifecycleError.launchAgentMismatch
                    }
                    loadedProcessID = processID
                case .mismatch:
                    throw InstallationLifecycleError.launchAgentMismatch
                }
            } else if !allowStoppedLaunchAgent || allowedProcessID != nil {
                throw InstallationLifecycleError.launchAgentMismatch
            } else {
                loadedProcessID = nil
            }
        }
        var allowedStateEntries = Set([
            "latest.log", "host-owner.json", "host.sock", "launcher.lock",
            "lifecycle.lock", "operation.lock", "run.lock",
            RepositoryAuthorityStore.filename,
            RepositorySelectionPreferenceStore.filename,
            RepositorySelectionPreferenceStore.recoveryFilename,
            "retention",
        ])
        let stateEntries = Set(
            try FileManager.default.contentsOfDirectory(atPath: state.path)
        )
        let stagedOwner = InstallationLifecycle.ownerBackupName
        let stagedSocket = InstallationLifecycle.socketBackupName
        let hasStagedOwner = stateEntries.contains(stagedOwner)
        let hasStagedSocket = stateEntries.contains(stagedSocket)
        if hasStagedOwner || hasStagedSocket {
            guard allowStagedLifecycleResidue,
                  hasStagedOwner == hasStagedSocket,
                  try operationAuthorityIsHeld(state: state) else {
                throw InstallationLifecycleError.unexpectedResidue
            }
            let registration = try HostRegistrationStore.readPersisted(
                state: state,
                named: stagedOwner
            )
            let socket = try state.ownedEntryIdentity(
                named: stagedSocket,
                allowSocket: true
            )
            guard registration.release != nil,
                  registration.identity.executablePath == executable,
                  registration.identity.processID > 1,
                  !registration.identity.isCurrent(
                    requireGroupLeader: false
                  ),
                  mode_t(socket.mode) & S_IFMT == S_IFSOCK,
                  mode_t(socket.mode) & 0o777 == 0o600 else {
                throw InstallationLifecycleError.unverifiedInstalledState
            }
            allowedStateEntries.formUnion([stagedOwner, stagedSocket])
        }
        guard stateEntries.isSubset(of: allowedStateEntries) else {
            throw InstallationLifecycleError.unexpectedStateEntry
        }
        for name in [
            "latest.log", "lifecycle.lock", "operation.lock", "run.lock",
            "launcher.lock",
        ] {
            let identity = try state.ownedEntryIdentity(
                named: name,
                allowSocket: false
            )
            guard identity.isRegular,
                  mode_t(identity.mode) & 0o777 == 0o600 else {
                throw InstallationLifecycleError.unexpectedStateEntry
            }
        }
        do {
            try DurableRunLogEvidence.validate(state: state)
        } catch {
            throw InstallationLifecycleError.unexpectedStateEntry
        }
        if stateEntries.contains(RepositoryAuthorityStore.filename) {
            let identity = try state.ownedEntryIdentity(
                named: RepositoryAuthorityStore.filename,
                allowSocket: false
            )
            guard identity.isRegular,
                  mode_t(identity.mode) & 0o777 == 0o600,
                  RepositoryAuthorityStore(state: state).snapshot().status
                    == .available else {
                throw InstallationLifecycleError.unexpectedStateEntry
            }
        }
        if stateEntries.contains(
            RepositorySelectionPreferenceStore.filename
        ) {
            guard RepositorySelectionPreferenceStore(
                state: state
            ).snapshot().status == .available else {
                throw InstallationLifecycleError
                    .unexpectedStateEntry
            }
        }
        if stateEntries.contains(
            RepositorySelectionPreferenceStore.recoveryFilename
        ) {
            let identity = try state.ownedEntryIdentity(
                named:
                    RepositorySelectionPreferenceStore
                        .recoveryFilename,
                allowSocket: false
            )
            guard identity.isRegular,
                  mode_t(identity.mode) & 0o777 == 0o600 else {
                throw InstallationLifecycleError
                    .unexpectedStateEntry
            }
        }
        if stateEntries.contains("retention") {
            let account = try EffectiveAccount.current()
            _ = try RetentionArtifactStore(
                state: state,
                account: account
            ).list()
        }
        let hasOwner = stateEntries.contains("host-owner.json")
        let hasSocket = stateEntries.contains("host.sock")
        guard hasOwner == hasSocket else {
            throw InstallationLifecycleError.unexpectedStateEntry
        }
        if hasOwner {
            let registration = try HostRegistrationStore.readPersisted(
                state: state
            )
            guard registration.release == artifact.release,
                  registration.identity.executablePath == executable,
                  registration.identity.processID > 1 else {
                throw InstallationLifecycleError.unverifiedInstalledState
            }
            if allowStoppedLaunchAgent, loadedProcessID == nil,
               registration.identity.isCurrent(requireGroupLeader: false) {
                guard allowUnpublishedRegisteredHost else {
                    throw InstallationLifecycleError.unverifiedInstalledState
                }
            }
            let socket = try state.ownedEntryIdentity(
                named: "host.sock",
                allowSocket: true
            )
            guard mode_t(socket.mode) & S_IFMT == S_IFSOCK,
                  mode_t(socket.mode) & 0o777 == 0o600 else {
                throw InstallationLifecycleError.unexpectedStateEntry
            }
        }
        return artifact
    }

    private static func operationAuthorityIsHeld(
        state: SecureStateDirectory
    ) throws -> Bool {
        let descriptor = try state.openRegularFile(
            named: "operation.lock",
            flags: O_RDONLY,
            create: false,
            repairPermissions: false
        )
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            return false
        }
        guard errno == EWOULDBLOCK else {
            throw SecureStateError.systemCall(
                "flock operation.lock",
                errno
            )
        }
        return true
    }

    static func requireLoadedProcess(
        launchAgent: any LaunchAgentControlling,
        executable: String,
        expectedProcessID: pid_t
    ) throws -> pid_t {
        guard expectedProcessID > 1 else {
            throw InstallationLifecycleError.unverifiedInstalledState
        }
        switch launchAgent.state(label: InstallationPaths.label) {
        case let .loaded(program, processID):
            guard program == executable,
                  let processID,
                  processID > 1,
                  processID == expectedProcessID else {
                throw InstallationLifecycleError.unverifiedInstalledState
            }
            return processID
        case .absent:
            throw InstallationLifecycleError.launchAgentMismatch
        case .queryFailure:
            throw InstallationLifecycleError.launchctl("print", -1)
        }
    }
}

public enum InstallationLifecycleError: Error, CustomStringConvertible {
    case unsafeInstallPath(String)
    case invalidSignature
    case invalidLaunchAgent
    case launchAgentMismatch
    case launchctl(String, Int32)
    case launcherDidNotExit
    case hostNotReady
    case bundleDigestMismatch
    case unexpectedResidue
    case unexpectedStateEntry
    case unverifiedInstalledState
    case rollbackFailed(String)
    case system(String, Int32)

    public var description: String {
        switch self {
        case let .unsafeInstallPath(path): return "unsafe installation path: \(path)"
        case .invalidSignature: return "the application signature is invalid"
        case .invalidLaunchAgent: return "the LaunchAgent is invalid"
        case .launchAgentMismatch: return "the loaded LaunchAgent does not match the installed app"
        case let .launchctl(action, status): return "launchctl \(action) failed (\(status))"
        case .launcherDidNotExit: return "the verified launcher did not exit"
        case .hostNotReady: return "the installed launcher did not become ready"
        case .bundleDigestMismatch: return "the installed application digest changed"
        case .unexpectedResidue: return "unexpected lifecycle staging residue exists"
        case .unexpectedStateEntry: return "unexpected coordination state exists"
        case .unverifiedInstalledState: return "the installed state could not be verified"
        case let .rollbackFailed(reason): return "rollback could not restore prior readiness: \(reason)"
        case let .system(name, code):
            return "\(name) failed: \(String(cString: strerror(code)))"
        }
    }
}
