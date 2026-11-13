import Darwin
import CryptoKit
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
    let ownedDescriptor: OwnedFileDescriptor
    var descriptor: Int32 { ownedDescriptor.value }
    let identity: FileIdentity

    init(path: String) throws {
        self.path = path
        let descriptor = Darwin.open(
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
        ownedDescriptor = OwnedFileDescriptor(descriptor)
        identity = FileIdentity(info)
    }

    // Readiness observers borrow the original admitted state description. This
    // narrow initializer acquires nothing that a throwing validation could lose.
    init(retaining state: SecureStateDirectory) throws {
        path = state.path; ownedDescriptor = state.descriptor
        var info = stat()
        guard fstat(state.descriptor.value, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(),
              (info.st_mode & 0o022) == 0 else { throw InstallationLifecycleError.unsafeInstallPath(state.path) }
        identity = FileIdentity(info)
    }

    func validate() throws {
        var current = stat()
        guard lstat(path, &current) == 0,
              identity.matchesStableNode(FileIdentity(current)) else {
            throw InstallationLifecycleError.unsafeInstallPath(path)
        }
    }

}

public final class InstallationLifecycle: @unchecked Sendable {
    fileprivate let paths: InstallationPaths
    fileprivate var validationProfile: InstallationValidationProfile = .production
    private let launchAgent: any LaunchAgentControlling
    private let host: any InstalledHostControlling
    private let fault: @Sendable (String) throws -> Void
    private let fileManager = FileManager.default
    private var pinnedAppParent: PinnedParent?
    private var pinnedPlistParent: PinnedParent?
    #if SHADOW_SYNC_TESTING
    var testingExclusiveRoot: String?
    var testingExclusiveRegistry: RetainedCleanupRegistry?
    var testingExclusiveDiagnostic = "installation-absent"
    var testingSlotCaptureStoreFault: CustodyCatalogStore.Fault?
    var testingSlotCaptureStage = "none"
    #endif

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
        var priorDrainStarted = false
        var mutationStarted = false
        var committed = false
        var coordinationBackup: CoordinationBackup?
        do {
            try fault("after-gates")
            priorDrainStarted = true
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
                        replacementRelease: source.release,
                        coordinationBackup: coordinationBackup
                    )
                } catch {
                    throw InstallationLifecycleError.rollbackFailed(
                        String(describing: error)
                    )
                }
            } else if prior.requiresInertRecovery || priorDrainStarted {
                // Once drainage begins, failure leaves the verified prior
                // generation stopped. Recovery never grants restart authority.
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
        try stageApplication(sourceBundle: sourceBundle, source: source, nonce: nonce, candidate: nil)
        try stagePlist(nonce: nonce)
    }

    @discardableResult
    private func stageApplication(sourceBundle: String, source: BundleArtifactIdentity, nonce: String,
                                  candidate: InstallationCandidate?) throws -> OwnedFileDescriptor {
        let appIncomplete = appParent + "/.ShadowSync.app.incomplete.\(nonce)"
        try fileManager.copyItem(atPath: sourceBundle, toPath: appIncomplete)
        let raw = open(appIncomplete, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw CustodyRecordError.unsafeMetadata }
        let retained = OwnedFileDescriptor(raw)
        _ = try InstallationCaptureParent.node(raw, directory: true, privateMode: false)
        try Self.normalizeAndSyncBundle(appIncomplete, validationProfile: validationProfile)
        let copied = try candidate.map { try inspectExclusiveBundle(appIncomplete, candidate: $0) }
            ?? Self.verifyBundle(appIncomplete, requireProduction: true)
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
        try renameOwned(appIncomplete, appIncoming, expectedSource: retained)
        return retained
    }

    @discardableResult
    private func stagePlist(nonce: String) throws -> OwnedFileDescriptor {
        let plistIncomplete = plistParent + "/.com.kleinperkins.shadow-sync.plist.incomplete.\(nonce)"
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
        let retained = OwnedFileDescriptor(plistDescriptor)
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
        try renameOwned(plistIncomplete, plistIncoming, expectedSource: retained)
        try Self.validateLaunchAgent(plistIncoming, executable: executablePath)
        return retained
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
        // ADR 0003 applies to every generation: restore verified preimages to
        // a stopped state. A later explicit repair owns any new activation.
        // The validated plist has RunAtLoad and KeepAlive disabled; preserving
        // its bytes does not authorize loading it or recreating a Login Item.
        guard try loadedProgram() == nil else {
            throw InstallationLifecycleError.launchAgentMismatch
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

    private static func normalizeAndSyncBundle(_ root: String, layoutOverride: PublisherBundleLayout? = nil,
                                               validationProfile: InstallationValidationProfile = .production) throws {
        let publisherLayout = try layoutOverride ?? PublisherBundleLayout.captureIfPresent(root, validationProfile: validationProfile)
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

    private func renameOwned(_ source: String, _ destination: String,
                             expectedSource: OwnedFileDescriptor? = nil) throws {
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
        if let expectedSource {
            var held = stat(), named = stat()
            guard fstat(expectedSource.value, &held) == 0,
                  fstatat(descriptor, sourceURL.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  FileIdentity(held) == FileIdentity(sourceInfo), FileIdentity(named) == FileIdentity(held) else {
                throw CustodyRecordError.conflict
            }
        }
        try pin.validate()
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

/// Only the fixed-layout factory below constructs this proof. Keeping it alive
/// retains the consumed original owner; a decoded snapshot cannot recreate it.
/// It grants neither journal transition nor filesystem action permission.
final class InstallationCapturedSlots {
    fileprivate let owner: InstallationTransactionOwner
    fileprivate let binding: InstallationLiveBinding
    fileprivate let lifecycle: InstallationLifecycle
    fileprivate let parents: [InstallationCaptureParent]
    let transactionID: String
    var stateBinding: InstallationStateBinding { binding.state }
    fileprivate let observed: InstallationSlotSnapshot
    fileprivate var expected: InstallationSlotSnapshot
    fileprivate var exclusiveNodes: [InstallationSlot: OwnedFileDescriptor] = [:]
    let preimages: [InstallationDocumentPreimage]
    let canonicalPreimages: [InstallationDocumentPreimage.CanonicalObservation]
    private var durable = false
    private(set) var retainedPreimages: [String: InstallationDocumentRetention] = [:]
    fileprivate init(owner: InstallationTransactionOwner, binding: InstallationLiveBinding,
                     lifecycle: InstallationLifecycle, parents: [InstallationCaptureParent],
                     transactionID: String, observed: InstallationSlotSnapshot,
                     preimages: [InstallationDocumentPreimage]) throws {
        self.owner = owner; self.binding = binding; self.lifecycle = lifecycle; self.parents = parents
        self.transactionID = transactionID; self.observed = observed; self.expected = observed; self.preimages = preimages
        canonicalPreimages = try preimages.map { try .init($0, uid: binding.state.directory.uid) }
    }
    fileprivate func markDurable(_ retained: [String: InstallationDocumentRetention]) {
        retainedPreimages = retained; durable = true
    }
    var snapshot: InstallationSlotSnapshot {
        get throws { guard durable else { throw CustodyRecordError.fenced }; return observed }
    }
    func revalidate(for owner: InstallationTransactionOwner) throws {
        guard self.owner === owner, durable else { throw CustodyRecordError.fenced }
        try validateSource()
        let store = try CustodyCatalogStore(leases: owner.retainExclusiveLeases(), validationProfile: owner.validationProfile)
        try store.validateInstallationPreimages(self)
    }
    // Storage uses this before/after its guard interval, never during it. The
    // fields are observations; only the private factory can produce this object.
    func validateSource() throws {
        try binding.revalidate(for: owner)
        try owner.validateInstallationPaths(lifecycle.paths)
        let current = try lifecycle.observeInstallationSlots(binding: binding, transactionID: transactionID, parents: parents)
        guard current.0 == expected, current.1 == preimages else { throw CustodyRecordError.conflict }
        for (slot, descriptor) in exclusiveNodes {
            guard try InstallationCaptureParent.node(descriptor.value, directory: slot.isBundle, privateMode: !slot.isBundle) == expected.images[slot]?.node else { throw CustodyRecordError.conflict }
        }
        try binding.revalidate(for: owner)
    }
}

/// Retain the existing pinned installer parent and its descriptor ACL. Named
/// children are always opened relative to this descriptor with O_NOFOLLOW.
fileprivate final class InstallationCaptureParent {
    let pinned: PinnedParent
    let identity: InstallationNodeIdentity
    init(_ path: String) throws {
        pinned = try PinnedParent(path: path)
        identity = try Self.node(pinned.descriptor, directory: true, privateMode: false)
        try validate()
    }
    init(readinessAdmission: LifecycleAdmissionAuthority) throws {
        guard readinessAdmission.commandAdmissionIsOpen else { throw CustodyRecordError.fenced }
        pinned = try PinnedParent(retaining: readinessAdmission.stateDirectory)
        identity = try Self.node(pinned.descriptor, directory: true, privateMode: false)
        try validate()
        guard readinessAdmission.commandAdmissionIsOpen else { throw CustodyRecordError.fenced }
    }
    var fd: Int32 { pinned.descriptor }
    // Extend the actual retained parent with / -> P, enrolling every acquired
    // description in the caller before the next fallible operation. No realpath
    // alias or reopened final parent is substituted for the original P.
    func retainSocketAncestors(_ address: InstallationNamedSocketObservation.Address,
                               into retained: inout [OwnedFileDescriptor], deadline: MonotonicDeadline) throws {
        guard retained.isEmpty, address.path == pinned.path + "/" + address.endpoint.rawValue,
              !deadline.hasExpired else { throw CustodyRecordError.fenced }
        let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw CustodyRecordError.persistence(errno) }
        retained.append(OwnedFileDescriptor(root))
        for component in address.parentComponents.dropLast() {
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            let raw = openat(retained.last!.value, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard raw >= 0 else { throw CustodyRecordError.persistence(errno) }
            retained.append(OwnedFileDescriptor(raw))
        }
        retained.append(pinned.ownedDescriptor)
        _ = try InstallationNamedSocketObservation.parents(address: address, retainedAncestors: retained,
            uid: geteuid(), deadline: deadline)
        try validate()
    }
    func validate() throws {
        try pinned.validate()
        let current = try Self.node(fd, directory: true, privateMode: false)
        // Child creation/removal changes a parent directory's link count on
        // supported filesystems. Pin its stable inode/protection identity; every
        // fixed child is separately observed and compared across the action.
        guard current.device == identity.device, current.inode == identity.inode,
              current.type == identity.type, current.uid == identity.uid,
              current.mode == identity.mode, current.aclDigest == identity.aclDigest,
              current.links > 0 else { throw CustodyRecordError.conflict }
        // Reject intermediate symlink resolution as well as final-component
        // links. The retained descriptor and named identity are checked again
        // after every capture pass.
#if SHADOW_SYNC_TESTING
        let observedReal = realpath(pinned.path, nil)
        guard InstallationInvocationTesting.check(observedReal != nil, .realpathCall, syscall: true),
              let real = observedReal else { throw CustodyRecordError.unsafeMetadata }
#else
        guard let real = realpath(pinned.path, nil) else { throw CustodyRecordError.unsafeMetadata }
#endif
        defer { free(real) }
#if SHADOW_SYNC_TESTING
        guard InstallationInvocationTesting.check(String(cString: real) == pinned.path, .canonicalPath) else { throw CustodyRecordError.unsafeMetadata }
#else
        guard String(cString: real) == pinned.path else { throw CustodyRecordError.unsafeMetadata }
#endif
    }
    static func node(_ fd: Int32, directory: Bool, privateMode: Bool) throws -> InstallationNodeIdentity {
        var s = stat()
#if SHADOW_SYNC_TESTING
        guard InstallationInvocationTesting.check(fstat(fd, &s) == 0, .statCall, syscall: true),
              InstallationInvocationTesting.check(s.st_uid == geteuid(), .owner),
              InstallationInvocationTesting.check(s.st_flags == 0, .flags),
              InstallationInvocationTesting.check(s.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), .type),
              InstallationInvocationTesting.check(directory || s.st_nlink == 1, .links),
              InstallationInvocationTesting.check(!privateMode || s.st_mode == (directory ? S_IFDIR | 0o700 : S_IFREG | 0o600), .mode) else {
            throw CustodyRecordError.unsafeMetadata
        }
#else
        guard fstat(fd, &s) == 0, s.st_uid == geteuid(), s.st_flags == 0,
              s.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              directory || s.st_nlink == 1,
              !privateMode || s.st_mode == (directory ? S_IFDIR | 0o700 : S_IFREG | 0o600) else {
            throw CustodyRecordError.unsafeMetadata
        }
#endif
        let acl = try privateMode ? PolicyAuthorityFile.privateStateACL(fd) : PolicyAuthorityFile.safeACL(fd)
        let node = InstallationNodeIdentity(device: UInt64(s.st_dev), inode: UInt64(s.st_ino),
            type: directory ? .directory : .regular, uid: s.st_uid, mode: UInt32(s.st_mode), links: UInt64(s.st_nlink),
            aclDigest: CustodyRecordBinding.digest(Data(acl.utf8)))
        try node.validate(); return node
    }
    func open(_ name: String, directory: Bool, privateMode: Bool,
              enroll: ((OwnedFileDescriptor) throws -> Void)? = nil) throws -> (OwnedFileDescriptor, InstallationNodeIdentity)? {
        try validate()
        var named = stat()
        if fstatat(fd, name, &named, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw CustodyRecordError.unsafeMetadata }
            try validate(); return nil
        }
        guard named.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { throw CustodyRecordError.unsafeMetadata }
        let raw = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
        guard raw >= 0 else { throw CustodyRecordError.unsafeMetadata }
        let owned = OwnedFileDescriptor(raw)
        // Enrollment precedes identity/ACL inspection: even that inspection can
        // throw, and only the acquiring owner may retain a failed checked close.
        try enroll?(owned)
        let node = try Self.node(raw, directory: directory, privateMode: privateMode)
        guard FileIdentity(named).device == node.device, FileIdentity(named).inode == node.inode,
              named.st_uid == node.uid, UInt32(named.st_mode) == node.mode, UInt64(named.st_nlink) == node.links else {
            throw CustodyRecordError.conflict
        }
        return (owned, node)
    }
    func absent(_ name: String) throws {
        var s = stat()
        guard fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else { throw CustodyRecordError.fenced }
        try validate()
    }
    func recheck(_ name: String, owned: OwnedFileDescriptor, node: InstallationNodeIdentity, privateMode: Bool) throws {
        var s = stat()
        guard try Self.node(owned.value, directory: node.type == .directory, privateMode: privateMode) == node,
              fstatat(fd, name, &s, AT_SYMLINK_NOFOLLOW) == 0,
              UInt64(s.st_dev) == node.device, UInt64(s.st_ino) == node.inode,
              UInt32(s.st_mode) == node.mode, s.st_uid == node.uid, UInt64(s.st_nlink) == node.links else {
            throw CustodyRecordError.conflict
        }
        try validate()
    }
    static func bytes(_ fd: Int32, maximum: Int) throws -> Data {
        var before = stat(); guard fstat(fd, &before) == 0, before.st_size >= 0, before.st_size <= maximum else {
            throw CustodyRecordError.unsafeMetadata
        }
        var data = Data(), block = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &block, min(block.count, maximum + 1 - data.count))
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw CustodyRecordError.persistence(errno) }
            if n == 0 { break }; data.append(contentsOf: block.prefix(n))
            guard data.count <= maximum else { throw CustodyRecordError.unsafeMetadata }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, FileIdentity(before) == FileIdentity(after), before.st_size == after.st_size,
              data.count == before.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw CustodyRecordError.conflict }
        return data
    }
}

extension InstallationLifecycle {
    /// This factory never prepares parents, starts commands, mutates source
    /// slots or grants readiness. Existing unsafe/unavailable layout refuses.
    func captureInstallationSlots(owner: InstallationTransactionOwner, binding: InstallationLiveBinding,
                                  transactionID: String) throws -> InstallationCapturedSlots {
        guard RunIdentity.isValid(transactionID) else { throw CustodyRecordError.fenced }
        #if SHADOW_SYNC_TESTING
        testingSlotCaptureStage = "bind"
        #endif
        try binding.revalidate(for: owner); try owner.validateInstallationPaths(paths)
        try owner.validationProfile.bindInstallationSlots(transactionID: transactionID)
        validationProfile = owner.validationProfile
        let parents = try [appParent, plistParent,
            URL(fileURLWithPath: paths.state.path).deletingLastPathComponent().path,
            paths.state.path].map(InstallationCaptureParent.init)
        #if SHADOW_SYNC_TESTING
        testingSlotCaptureStage = "observe"
        #endif
        let observed = try observeInstallationSlots(binding: binding, transactionID: transactionID, parents: parents)
        let capture = try InstallationCapturedSlots(owner: owner, binding: binding, lifecycle: self, parents: parents,
            transactionID: transactionID, observed: observed.0, preimages: observed.1)
        #if SHADOW_SYNC_TESTING
        testingSlotCaptureStage = "source"
        #endif
        try capture.validateSource()
        let store = try CustodyCatalogStore(leases: owner.retainExclusiveLeases(), validationProfile: owner.validationProfile)
        #if SHADOW_SYNC_TESTING
        store.testingFault(testingSlotCaptureStoreFault)
        #endif
        #if SHADOW_SYNC_TESTING
        testingSlotCaptureStage = "persist"
        #endif
        let retained = try store.persistInstallationPreimages(capture)
        #if SHADOW_SYNC_TESTING
        testingSlotCaptureStage = "postflight"
        #endif
        try capture.validateSource(); capture.markDurable(retained)
        return capture
    }
    fileprivate func observeInstallationSlots(binding: InstallationLiveBinding, transactionID: String,
                                              parents: [InstallationCaptureParent], endpoint: InstallationReadinessEndpoint? = nil,
                                              readinessDeadline: MonotonicDeadline? = nil,
                                              normalHost: InstallationNormalHostFiles? = nil,
                                              recordNormalHost: Bool = false,
                                              stoppedReadiness: (CustodyCatalogStore.InstallationStagedJournal.StopDelivery, InstallationPrecommitSession.Stopped)? = nil,
                                              candidateRetirement: InstallationCandidateRetirement? = nil,
                                              restoringPlist: InstallationPreparedSlotObservation? = nil) throws
        -> (InstallationSlotSnapshot, [InstallationDocumentPreimage]) {
        try observeInstallationSlots(stateBinding: binding.state, candidate: binding.candidate,
            transactionID: transactionID, parents: parents, endpoint: endpoint, readinessDeadline: readinessDeadline, normalHost: normalHost, recordNormalHost: recordNormalHost, stoppedReadiness: stoppedReadiness, candidateRetirement: candidateRetirement, restoringPlist: restoringPlist)
    }
    fileprivate func observeInstallationSlots(stateBinding: InstallationStateBinding, candidate: InstallationCandidate,
                                              transactionID: String, parents: [InstallationCaptureParent],
                                              endpoint: InstallationReadinessEndpoint? = nil,
                                              hostEndpoint: InstallationPrecommitHostEndpoint? = nil,
                                              readinessDeadline: MonotonicDeadline? = nil,
                                              normalHost: InstallationNormalHostFiles? = nil,
                                              recordNormalHost: Bool = false,
                                              stoppedReadiness: (CustodyCatalogStore.InstallationStagedJournal.StopDelivery, InstallationPrecommitSession.Stopped)? = nil,
                                              candidateRetirement: InstallationCandidateRetirement? = nil,
                                              restoringPlist: InstallationPreparedSlotObservation? = nil) throws
        -> (InstallationSlotSnapshot, [InstallationDocumentPreimage]) {
        if endpoint != nil {
            guard let readinessDeadline, !readinessDeadline.hasExpired else { throw CustodyRecordError.busy }
        }
        guard parents.count == 4 else { throw CustodyRecordError.fenced }
        let app = parents[0], plist = parents[1], namespaceParent = parents[2], state = parents[3]
        // The stable namespace excludes only its child-dependent directory
        // link count, matching InstallationStateBinding.validateLive. Durable
        // images/preimages retain that original binding; each fresh raw node
        // still carries and rechecks its current count within this pass.
        func isBoundState(_ node: InstallationNodeIdentity) -> Bool {
            let held = stateBinding.directory
            return node.device == held.device && node.inode == held.inode && node.type == held.type
                && node.uid == held.uid && node.mode == held.mode && node.aclDigest == held.aclDigest
                && node.links > 0 && held.links > 0
        }
        guard isBoundState(state.identity) else { throw CustodyRecordError.fenced }
        let appIncomplete = ".ShadowSync.app.incomplete." + transactionID
        let plistIncomplete = ".com.kleinperkins.shadow-sync.plist.incomplete." + transactionID
        // Legacy aliases remain exclusively owned by the existing compatibility
        // reader; this new path does not reinterpret ambiguous rollback names.
        try app.absent(URL(fileURLWithPath: legacyPredecessorAppBackup).lastPathComponent)
        let allowedResidue = Set([appIncomplete, plistIncomplete])
        for name in try lifecycleSlotNames() {
            guard allowedResidue.contains(name) else { throw CustodyRecordError.fenced }
        }
        let legacyName = String(LegacyInstallationRelease.bundleIdentifier.split(separator: ".").last!)
        // The present owner is bound to current state. A legacy source needs the
        // separate accepted migration owner; do not inspect its documents under
        // a different namespace's operation lease.
        try namespaceParent.absent(legacyName)
        let layout: [InstallationSlot: (InstallationCaptureParent, String)] = [
            .application: (app, URL(fileURLWithPath: paths.app).lastPathComponent),
            .predecessorApplication: (app, URL(fileURLWithPath: paths.predecessorApp).lastPathComponent),
            .applicationIncoming: (app, URL(fileURLWithPath: appIncoming).lastPathComponent),
            .applicationIncomplete: (app, appIncomplete), .applicationPrevious: (app, URL(fileURLWithPath: appBackup).lastPathComponent),
            .predecessorPrevious: (app, URL(fileURLWithPath: predecessorAppBackup).lastPathComponent),
            .launchPlist: (plist, URL(fileURLWithPath: paths.launchAgent).lastPathComponent),
            .plistIncoming: (plist, URL(fileURLWithPath: plistIncoming).lastPathComponent),
            .plistIncomplete: (plist, plistIncomplete), .plistPrevious: (plist, URL(fileURLWithPath: plistBackup).lastPathComponent),
            .stateSource: (namespaceParent, legacyName),
            .stateDestination: (namespaceParent, URL(fileURLWithPath: paths.state.path).lastPathComponent),
            .hostOwner: (state, "host-owner.json"), .hostSocket: (state, "host.sock"),
            .hostOwnerPrevious: (state, Self.ownerBackupName), .hostSocketPrevious: (state, Self.socketBackupName),
            .installationSocket: (state, "installation.sock"),
        ]
        var images: [InstallationSlot: InstallationSlotImage] = [:], documents: [InstallationDocumentPreimage] = []
        for slot in InstallationSlot.allCases {
            if let readinessDeadline, readinessDeadline.hasExpired { throw CustodyRecordError.busy }
            #if SHADOW_SYNC_TESTING
            testingSlotCaptureStage = "observe:" + slot.rawValue
            #endif
            let (parent, name) = layout[slot]!
            if slot == .launchPlist, let restoringPlist {
                images[slot] = try restoringPlist.retiringPlistImage(parent: parent)
                continue
            }
            if slot == .application, let candidateRetirement {
                images[slot] = try candidateRetirement.observedImage(parent: parent)
                continue
            }
            if let normalHost, slot == .hostOwner || slot == .hostSocket {
                let actual = try normalHost.image(slot, parent: parent)
                // The original preimage remains immutable. The causal cleanup
                // completion records these exact newly created host nodes in
                // its postimage; it never removes or rewrites either node.
                images[slot] = recordNormalHost ? actual : InstallationSlotImage(
                    parentDevice: parent.identity.device, parentInode: parent.identity.inode,
                    node: nil, size: nil, contentDigest: nil, documentReceipts: nil)
                continue
            }
            let absent = InstallationSlotImage(parentDevice: parent.identity.device, parentInode: parent.identity.inode,
                node: nil, size: nil, contentDigest: nil, documentReceipts: nil)
            if slot.isSocket {
                if slot == .installationSocket, let endpoint {
                    guard let readinessDeadline else { throw CustodyRecordError.fenced }
                    try endpoint.revalidate(deadline: readinessDeadline, stopped: stoppedReadiness)
                    guard endpoint.parentMatches(parent.identity) else { throw CustodyRecordError.conflict }
                    images[slot] = try endpoint.image
                } else if slot == .installationSocket, let hostEndpoint {
                    try hostEndpoint.revalidate()
                    guard hostEndpoint.parentMatches(parent.identity) else { throw CustodyRecordError.conflict }
                    images[slot] = hostEndpoint.image
                } else { try parent.absent(name); images[slot] = absent }
                continue
            }
            guard let (fd, node) = try parent.open(name, directory: slot.isBundle || slot.isNamespace,
                                                 privateMode: !slot.isBundle) else { images[slot] = absent; continue }
            var size: UInt64?, digest: String?, refs: [InstallationDocument: String?]?
            var imageNode = node
            if slot.isNamespace {
                guard isBoundState(node), parent === namespaceParent else { throw CustodyRecordError.fenced }
                // Socket creation changes child count, not the bound namespace
                // generation or retained preimage. Keep the fresh raw `node`
                // unchanged for the full held/named recheck below.
                imageNode = stateBinding.directory
                var values: [InstallationDocument: String?] = [:]
                for document in InstallationDocument.allCases {
                    if let (source, identity) = try state.open(document.rawValue, directory: false, privateMode: true) {
                        let bytes = try InstallationCaptureParent.bytes(source.value, maximum: InstallationDocumentPreimage.maximumContentBytes(for: document))
                        try state.recheck(document.rawValue, owned: source, node: identity, privateMode: true)
                        let receipt = InstallationDocumentPreimage(transactionID: transactionID, slot: slot, document: document,
                            namespace: imageNode, node: identity, bytes: bytes)
                        values.updateValue(try receipt.digest(uid: node.uid), forKey: document); documents.append(receipt)
                    } else { values.updateValue(nil, forKey: document) }
                }
                refs = values
            } else if slot.isBundle {
                let path = parent.pinned.path + "/" + name
                let artifact = try inspectExclusiveBundle(path,
                    candidate: [.applicationIncoming, .applicationIncomplete].contains(slot) ? candidate : nil)
                digest = artifact.canonicalSHA256
            } else {
                let bytes = try InstallationCaptureParent.bytes(fd.value, maximum: 65_536)
                size = UInt64(bytes.count); digest = CustodyRecordBinding.digest(bytes)
            }
            try parent.recheck(name, owned: fd, node: node, privateMode: !slot.isBundle)
            images[slot] = InstallationSlotImage(parentDevice: parent.identity.device, parentInode: parent.identity.inode,
                node: imageNode, size: size, contentDigest: digest, documentReceipts: refs)
        }
        for parent in parents { try parent.validate() }
        let result = InstallationSlotSnapshot(images: images); try result.validate(uid: paths.state.uid)
        return (result, documents)
    }
}

extension InstallationLifecycle {
    /// Closed first-install preparation. Existing applications, launch routes,
    /// migration and recovery residues require evidence not supplied by this slice.
    fileprivate func requireExclusiveEmptyInstall(_ capture: InstallationCapturedSlots) throws {
        try capture.validateSource()
        for slot in InstallationSlot.allCases where slot != .stateDestination {
            guard capture.expected.images[slot]?.node == nil else { throw CustodyRecordError.fenced }
        }
    }

    fileprivate func inspectExclusiveBundle(_ path: String, candidate: InstallationCandidate?) throws -> BundleArtifactIdentity {
        let artifact: BundleArtifactIdentity
        #if SHADOW_SYNC_TESTING
        if testingExclusiveRoot != nil { artifact = try BundleArtifactIdentity.inspect(bundlePath: path, requireProduction: false) }
        else { artifact = try validationProfile.inspectBundle(path) }
        #else
        artifact = try validationProfile.inspectBundle(path)
        #endif
        #if SHADOW_SYNC_TESTING
        if let root = testingExclusiveRoot {
            guard try TestIsolation.validateRoot(root) == root, path.hasPrefix(root + "/") else { throw CustodyRecordError.fenced }
            if let candidate {
                guard artifact.canonicalSHA256 == candidate.bundleDigest, artifact.release == candidate.release else { throw CustodyRecordError.conflict }
            }
            return artifact
        }
        #endif
        let (_, app) = try PublisherCodeVerifier.verifiedStatic(path: path,
            identifier: ReleaseIdentity.bundleIdentifier, team: ReleaseIdentity.publisherTeamIdentifier)
        let (_, helper) = try PublisherCodeVerifier.verifiedStatic(path: path + LifecyclePublisher.relativeExecutable,
            identifier: LifecyclePublisher.identifier, team: ReleaseIdentity.publisherTeamIdentifier)
        if let candidate {
            guard artifact.canonicalSHA256 == candidate.bundleDigest, artifact.release == candidate.release,
                  app.codeDirectory.map({ String(format: "%02x", $0) }).joined() == candidate.appCDHash,
                  helper.codeDirectory.map({ String(format: "%02x", $0) }).joined() == candidate.coordinatorCDHash else { throw CustodyRecordError.conflict }
        }
        return artifact
    }

    /// Existing fixed service diagnostic, owned by this live drain intent. Neither
    /// an injected controller result nor a caller-supplied status can prove absence.
    fileprivate func observeExclusiveServiceAbsence(owner: InstallationTransactionOwner,
        journal: CustodyCatalogStore.InstallationJournalSession, deadline: MonotonicDeadline,
        cancellation: InstallationCancellationGate) throws {
        var context: CommandCustodyContext?
        var registry = RetainedCleanupRegistry.shared
        #if SHADOW_SYNC_TESTING
        registry = testingExclusiveRegistry ?? registry
        if let root = testingExclusiveRoot {
            context = try .testingInstallation(owner, journal: journal, root: root)
            registry = testingExclusiveRegistry ?? registry
        } else {
            context = try .borrowing(owner, journal: journal, deadline: deadline)
        }
        #else
        context = try .borrowing(owner, journal: journal, deadline: deadline)
        #endif
        weak var releasedContext = context
        defer { context?.close() }
        let result: CustodyRegistryResult
        let budget = try CustodyBudget.make(kind: .launchctlRead, workSeconds: 10)
            .clipped(to: deadline, kind: .launchctlRead, permittedWorkSeconds: 10)
        do {
            let command: PreparedCustodyCommand
            #if SHADOW_SYNC_TESTING
            if testingExclusiveRoot != nil {
                command = try context!.testingInstallationDiagnostic(testingExclusiveDiagnostic, budget: budget)
            } else { command = try context!.prepare(.serviceStatus, budget: budget) }
            #else
            command = try context!.prepare(.serviceStatus, budget: budget)
            #endif
            #if SHADOW_SYNC_TESTING
            try fault("exclusive-diagnostic-prepared")
            #endif
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            try cancellation.check()
            result = try registry.start(command).wait()
        }
        context?.close(); context = nil
        // Removal follows terminal fsync, resource closure, reap and every EOF.
        // A terminal result alone is insufficient; queue-owned context aliases
        // must disappear as well as the registry's reservations.
        while releasedContext != nil || registry.hasRetainedWork {
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard !deadline.hasExpired, result.phase == .finished, result.reason == nil,
              let command = result.journal, command.phase == .terminal,
              command.kind == .launchctlRead, command.authority == .lifecycleMutation,
              command.outcome == .commandFailed, command.waitStatus == 113 << 8,
              result.stdout.isEmpty else { throw CustodyRecordError.fenced }
        let account: EffectiveAccount
        #if SHADOW_SYNC_TESTING
        account = try testingExclusiveRoot == nil ? validationProfile.destinationAccount : EffectiveAccount.isolated(homeDirectory: paths.home)
        #else
        account = try EffectiveAccount.current()
        #endif
        guard account.homeDirectory == paths.home,
              try LifecycleLaunchCommand(operation: .bootstrap, account: account)
            .state(waitStatus: 113 << 8, stdout: result.stdout, stderr: result.stderr) == .absent else { throw CustodyRecordError.fenced }
        try owner.revalidate()
    }

    fileprivate func executeExclusive(_ permit: CustodyCatalogStore.InstallationExclusiveActionPermit,
                                      capture: InstallationCapturedSlots) throws {
        try permit.revalidate(for: capture)
        let action = permit.action
        try capture.validateSource()
        let before = capture.expected
        try pinParents(); defer { unpinParents() }
        // Existing parent descriptors must still name the retained capture roots.
        try capture.parents.forEach { try $0.validate() }
        let candidate = capture.binding.candidate
        var created: OwnedFileDescriptor?
        switch action {
        case .stageApplication:
            let sourcePath = try capture.owner.installationSourceBundle()
            let source = try inspectExclusiveBundle(sourcePath, candidate: candidate)
            created = try stageApplication(sourceBundle: sourcePath, source: source, nonce: capture.transactionID, candidate: candidate)
        case .stagePlist:
            created = try stagePlist(nonce: capture.transactionID)
        case .promoteApplication:
            guard let source = capture.exclusiveNodes[.applicationIncoming],
                  try InstallationCaptureParent.node(source.value, directory: true, privateMode: false) == before.images[.applicationIncoming]?.node else { throw CustodyRecordError.fenced }
            try fault("exclusive-before-promote-application")
            try renameOwned(appIncoming, paths.app, expectedSource: source)
        case .promotePlist:
            guard let source = capture.exclusiveNodes[.plistIncoming],
                  try InstallationCaptureParent.node(source.value, directory: false, privateMode: true) == before.images[.plistIncoming]?.node else { throw CustodyRecordError.fenced }
            try fault("exclusive-before-promote-plist")
            try renameOwned(plistIncoming, paths.launchAgent, expectedSource: source)
            try Self.validateLaunchAgent(paths.launchAgent, executable: executablePath)
        case .retireApplication, .retirePlist, .retireCoordination, .translateState, .moveStateForward:
            // Fresh current namespace only: there is nothing to retire, translate
            // or move. Never infer that an existing legacy route is inactive.
            for slot in [InstallationSlot.application, .predecessorApplication, .applicationPrevious,
                         .predecessorPrevious, .launchPlist, .plistPrevious, .stateSource,
                         .hostOwner, .hostSocket, .hostOwnerPrevious, .hostSocketPrevious] {
                guard before.images[slot]?.node == nil else { throw CustodyRecordError.fenced }
            }
        default: throw CustodyRecordError.fenced
        }
        try fault("exclusive-after-action-" + action.rawValue)
        let after = try observeInstallationSlots(binding: capture.binding, transactionID: capture.transactionID, parents: capture.parents)
        guard after.1 == capture.preimages else { throw CustodyRecordError.conflict }
        var expected = before.images
        switch action {
        case .stageApplication:
            let image = after.0.images[.applicationIncoming]!
            guard let created, image.node == (try InstallationCaptureParent.node(created.value, directory: true, privateMode: false)),
                  image.contentDigest == candidate.bundleDigest else { throw CustodyRecordError.conflict }
            expected[.applicationIncoming] = image
        case .stagePlist:
            let image = after.0.images[.plistIncoming]!
            let bytes = try PropertyListSerialization.data(fromPropertyList: Self.launchAgentDictionary(executable: executablePath), format: .xml, options: 0)
            guard let created, image.node == (try InstallationCaptureParent.node(created.value, directory: false, privateMode: true)),
                  image.node?.mode == 0o100600, image.contentDigest == CustodyRecordBinding.digest(bytes), image.size == UInt64(bytes.count) else { throw CustodyRecordError.conflict }
            expected[.plistIncoming] = image
        case .promoteApplication, .promotePlist:
            let source: InstallationSlot = action == .promoteApplication ? .applicationIncoming : .plistIncoming
            let target: InstallationSlot = action == .promoteApplication ? .application : .launchPlist
            guard before.images[target]?.node == nil, before.images[source]?.node != nil else { throw CustodyRecordError.conflict }
            expected[target] = before.images[source]; expected[source] = before.images[target]
        default: break
        }
        guard after.0 == InstallationSlotSnapshot(images: expected) else { throw CustodyRecordError.conflict }
        // Stage helpers fsync every created file/tree and renameOwned fsyncs the
        // exact parent. A second pass detects changes before completion is built.
        if let created {
            capture.exclusiveNodes[action == .stageApplication ? .applicationIncoming : .plistIncoming] = created
        }
        if action == .promoteApplication || action == .promotePlist {
            let source: InstallationSlot = action == .promoteApplication ? .applicationIncoming : .plistIncoming
            let target: InstallationSlot = action == .promoteApplication ? .application : .launchPlist
            capture.exclusiveNodes[target] = capture.exclusiveNodes.removeValue(forKey: source)
        }
        capture.expected = after.0
        try capture.validateSource()
    }
}

extension InstallationCapturedSlots {
    func requireExclusiveEmptyInstall() throws { try lifecycle.requireExclusiveEmptyInstall(self) }
    func observeExclusiveServiceAbsence(journal: CustodyCatalogStore.InstallationJournalSession,
                                       deadline: MonotonicDeadline, cancellation: InstallationCancellationGate) throws {
        try lifecycle.observeExclusiveServiceAbsence(owner: owner, journal: journal, deadline: deadline, cancellation: cancellation)
    }
    func executeExclusive(_ permit: CustodyCatalogStore.InstallationExclusiveActionPermit) throws -> InstallationSlotSnapshot {
        try lifecycle.executeExclusive(permit, capture: self); return expected
    }
    var exclusiveSnapshot: InstallationSlotSnapshot { expected }
}

/// Detached read-only slot proof. It keeps parent/document descriptions, not the
/// journal, capture, command controllers or any borrowed admission lock family.
final class InstallationPreparedSlotObservation {
    private let owner: InstallationTransactionOwner
    private let binding: InstallationLiveBinding
    private var expected: InstallationSlotSnapshot
    private let originalPreimages: InstallationSlotSnapshot
    private var endpoint: InstallationReadinessEndpoint?
    private let documents: [InstallationDocumentPreimage]
    private let parents: [InstallationCaptureParent]
    private let transactionID: String
    private let observer: InstallationLifecycle
    private var exclusiveNodes: [InstallationSlot: OwnedFileDescriptor]
    fileprivate init(_ capture: InstallationCapturedSlots) throws {
        try capture.validateSource()
        owner = capture.owner; binding = capture.binding; expected = capture.expected
        originalPreimages = capture.observed
        documents = capture.preimages; parents = capture.parents; transactionID = capture.transactionID
        exclusiveNodes = capture.exclusiveNodes
        observer = InstallationLifecycle(paths: capture.lifecycle.paths,
            launchAgent: SystemLaunchAgentController(), host: SystemInstalledHostController())
        observer.validationProfile = capture.lifecycle.validationProfile
        #if SHADOW_SYNC_TESTING
        observer.testingExclusiveRoot = capture.lifecycle.testingExclusiveRoot
        #endif
    }
    // Caller must already have persisted open-staged-admission intent. This
    // factory additionally requires the actual consumed owner in staged phase.
    func createReadinessEndpoint(for owner: InstallationTransactionOwner, deadline: MonotonicDeadline) throws -> InstallationReadinessEndpoint {
        #if SHADOW_SYNC_TESTING
        var diagnosticStage: UInt8 = 1
        var diagnosticComplete = false
        defer {
            if !diagnosticComplete { InstallationReadinessEndpoint.testingRecordFailure(part: .slots, stage: diagnosticStage) }
        }
        #endif
        guard self.owner === owner, endpoint == nil else { throw CustodyRecordError.fenced }
        #if SHADOW_SYNC_TESTING
        diagnosticStage = 2
        #endif
        try owner.validateReadinessOwner()
        #if SHADOW_SYNC_TESTING
        diagnosticStage = 3
        #endif
        try revalidate(for: owner, deadline: deadline)
        guard expected.images[.installationSocket]?.node == nil else { throw CustodyRecordError.fenced }
        #if SHADOW_SYNC_TESTING
        diagnosticStage = 4
        #endif
        let created = InstallationReadinessEndpoint(parent: parents[3], owner: owner, deadline: deadline)
        // The actual partial creator is enrolled before socket/open/bind. The
        // journal's existing serialized turn excludes cancellation until unwind.
        endpoint = created
        #if SHADOW_SYNC_TESTING
        created.testingCut = testingEndpointCut
        let fixtureRoot: String?
        #if SHADOW_SYNC_SIGNED_FIXTURE
        if case let .signedFixture(profile) = observer.validationProfile { fixtureRoot = try profile.location.anchorPath }
        else { fixtureRoot = observer.testingExclusiveRoot }
        #else
        fixtureRoot = observer.testingExclusiveRoot
        #endif
        guard let root = fixtureRoot, try InstallationPaths.isolated(root: root) == observer.paths else { throw CustodyRecordError.fenced }
        try RuntimeFixtureSession.installationRoot(root).retainNamedSocket(created)
        #endif
        #if SHADOW_SYNC_TESTING
        diagnosticStage = 5
        #endif
        try created.publish()
        #if SHADOW_SYNC_TESTING
        diagnosticStage = 6
        #endif
        var images = expected.images; images[.installationSocket] = try created.image
        expected = InstallationSlotSnapshot(images: images)
        #if SHADOW_SYNC_TESTING
        diagnosticStage = 7
        #endif
        try revalidate(for: owner, deadline: deadline)
        #if SHADOW_SYNC_TESTING
        diagnosticComplete = true
        #endif
        return created
    }
    func readinessHost(peer: PublisherCodeVerifier.AuditPeerObservation, generation: String,
                       for owner: InstallationTransactionOwner, deadline: MonotonicDeadline) throws -> ProcessIdentity {
        try revalidate(for: owner, deadline: deadline)
        guard peer.uid == binding.state.directory.uid else { throw CustodyRecordError.fenced }
        let process = try ProcessIdentity.capture(processID: peer.pid, generation: generation,
            expectedExecutablePath: observer.paths.executable)
        guard process.userID == peer.uid else { throw CustodyRecordError.fenced }
        try revalidate(for: owner, deadline: deadline)
        return process
    }
    private var normalHostFiles: InstallationNormalHostFiles?
    func observeNormalHost(_ started: InstallationPrecommitSession.NormalStarted,
                           for owner: InstallationTransactionOwner, deadline: MonotonicDeadline) throws {
        guard self.owner === owner, normalHostFiles == nil, let endpoint,
              expected.images[.hostOwner]?.node == nil, expected.images[.hostSocket]?.node == nil else { throw CustodyRecordError.fenced }
        let observed = try InstallationNormalHostFiles.peer(started, endpoint: endpoint)
        normalHostFiles = observed
        try revalidate(for: owner, deadline: deadline)
    }
    func prepareReadinessRetirement(_ started: InstallationPrecommitSession.NormalStarted,
                                   for owner: InstallationTransactionOwner, deadline: MonotonicDeadline) throws {
        guard self.owner === owner, let normalHostFiles else { throw CustodyRecordError.fenced }
        try revalidate(for: owner, deadline: deadline)
        try normalHostFiles.detachForReadinessRetirement(started)
        try revalidate(for: owner, deadline: deadline)
    }
    private var stoppedHostDelivery: CustodyCatalogStore.InstallationStagedJournal.StopDelivery?
    private var stoppedHostAcknowledgment: InstallationPrecommitSession.Stopped?
    func retainStoppedHost(_ acknowledgment: InstallationPrecommitSession.Stopped,
        delivery: CustodyCatalogStore.InstallationStagedJournal.StopDelivery,
        for owner: InstallationTransactionOwner) throws {
        guard self.owner === owner, stoppedHostDelivery == nil, !recordNormalHost,
              let normalHostFiles, endpoint != nil, retiredReadinessEndpoint == nil else { throw CustodyRecordError.fenced }
        try delivery.validateStoppedOwner(owner, acknowledgment: acknowledgment)
        // Preserve both exact previously observed named host generations. The
        // stopped frame grants neither unlink authority nor absent-node success.
        try normalHostFiles.detachForStoppedRecovery(acknowledgment, delivery: delivery)
        stoppedHostDelivery = delivery; stoppedHostAcknowledgment = acknowledgment
        try revalidate(for: owner, deadline: acknowledgment.deadline)
    }
    func retainReadinessStoppedHost(_ acknowledgment: InstallationPrecommitSession.Stopped,
        delivery: CustodyCatalogStore.InstallationStagedJournal.StopDelivery,
        for owner: InstallationTransactionOwner) throws {
        guard self.owner === owner, delivery.isReadinessOnly, stoppedHostDelivery == nil,
              normalHostFiles == nil, !recordNormalHost, endpoint != nil,
              retiredReadinessEndpoint == nil else { throw CustodyRecordError.fenced }
        try delivery.validateStoppedOwner(owner, acknowledgment: acknowledgment)
        stoppedHostDelivery = delivery; stoppedHostAcknowledgment = acknowledgment
        try revalidateStopped(for: owner, acknowledgment: acknowledgment, delivery: delivery)
    }
    func revalidateStopped(for owner: InstallationTransactionOwner,
        acknowledgment: InstallationPrecommitSession.Stopped,
        delivery: CustodyCatalogStore.InstallationStagedJournal.StopDelivery) throws {
        guard self.owner === owner, stoppedHostDelivery === delivery,
              stoppedHostAcknowledgment === acknowledgment else { throw CustodyRecordError.fenced }
        try delivery.validateStoppedOwner(owner, acknowledgment: acknowledgment)
        try validateSlots(for: owner, deadline: acknowledgment.deadline, stopped: (delivery, acknowledgment))
        try delivery.validateStoppedOwner(owner, acknowledgment: acknowledgment)
    }
    private var retiredReadinessEndpoint: InstallationReadinessEndpoint?
    private var recordNormalHost = false
    func acceptReadinessRetirement(_ postimage: InstallationReadinessEndpoint.CleanupPostimage,
        permit: CustodyCatalogStore.InstallationStagedJournal.CleanupPermit,
        for owner: InstallationTransactionOwner, deadline: MonotonicDeadline) throws {
        guard self.owner === owner, let endpoint, normalHostFiles != nil,
              retiredReadinessEndpoint == nil else { throw CustodyRecordError.fenced }
        try postimage.validate(endpoint: endpoint, permit: permit)
        try permit.validate(endpoint: endpoint, owner: owner)
        var images = expected.images; images[.installationSocket] = postimage.image
        guard let normalHostFiles else { throw CustodyRecordError.fenced }
        images[.hostOwner] = try normalHostFiles.image(.hostOwner, parent: parents[3])
        images[.hostSocket] = try normalHostFiles.image(.hostSocket, parent: parents[3])
        expected = InstallationSlotSnapshot(images: images); recordNormalHost = true
        retiredReadinessEndpoint = endpoint; self.endpoint = nil
        try revalidate(for: owner, deadline: deadline)
    }
    private var stoppedCoordinationPermit: CustodyCatalogStore.InstallationStagedJournal.StoppedCleanupPermit?
    private var stoppedCoordinationAccepted = false
    func revalidateStoppedRepair(_ permit: CustodyCatalogStore.InstallationStagedJournal.StoppedCleanupPermit?,
        for owner: InstallationTransactionOwner, deadline: MonotonicDeadline) throws {
        guard let permit, permit.matches(slots: self), self.owner === owner,
              let delivery = stoppedHostDelivery, let acknowledgment = stoppedHostAcknowledgment else {
            throw CustodyRecordError.fenced
        }
        try binding.revalidate(for: owner)
        if stoppedCoordinationAccepted {
            guard endpoint == nil, normalHostFiles == nil else { throw CustodyRecordError.fenced }
            try validateSlots(for: owner, deadline: deadline, stopped: nil)
        } else {
            try validateSlots(for: owner, deadline: deadline, stopped: (delivery, acknowledgment))
        }
    }
    func cleanupStoppedCoordination(_ permit: CustodyCatalogStore.InstallationStagedJournal.StoppedCleanupPermit)
        throws -> InstallationSlotSnapshot {
        guard permit.matches(slots: self), let endpoint = retainedReadinessEndpoint,
              let delivery = stoppedHostDelivery, let acknowledgment = stoppedHostAcknowledgment,
              !delivery.isReadinessOnly else { throw CustodyRecordError.fenced }
        try permit.validate(owner: owner, endpoint: endpoint)
        try permit.validateOwner(); try permit.validateDrain()
        if stoppedCoordinationPermit == nil {
            try revalidateStoppedRepair(permit, for: owner, deadline: permit.deadline)
            guard let normalHostFiles else { throw CustodyRecordError.fenced }
            try endpoint.prepareStoppedCleanup(permit, files: normalHostFiles)
            stoppedCoordinationPermit = permit
        }
        guard stoppedCoordinationPermit === permit else { throw CustodyRecordError.fenced }
        let image = try endpoint.retireStoppedCleanup(permit)
        if !stoppedCoordinationAccepted {
            var images = expected.images
            images[.installationSocket] = image
            // The original transaction has absent host-node preimages. Only the
            // actual stopped-node retirement permits these same absent postimages.
            guard images[.hostOwner]?.node == nil, images[.hostSocket]?.node == nil else {
                throw CustodyRecordError.fenced
            }
            expected = InstallationSlotSnapshot(images: images)
            self.endpoint = nil; retiredReadinessEndpoint = endpoint; normalHostFiles = nil
            stoppedCoordinationAccepted = true
        }
        try revalidateStoppedRepair(permit, for: owner, deadline: acknowledgment.deadline)
        return expected
    }
    func finishStoppedCoordination(_ permit: CustodyCatalogStore.InstallationStagedJournal.StoppedCleanupPermit) throws {
        guard stoppedCoordinationPermit === permit, stoppedCoordinationAccepted,
              let retiredReadinessEndpoint else { throw CustodyRecordError.fenced }
        try retiredReadinessEndpoint.completeStoppedCleanup(permit)
    }
    func completeStoppedFreshCleanup(_ permit: CustodyCatalogStore.InstallationStagedJournal.StoppedCleanupPermit,
        action: InstallationAction) throws -> InstallationSlotSnapshot {
        guard permit.matches(slots: self), stoppedCoordinationAccepted,
              let retiredReadinessEndpoint else { throw CustodyRecordError.fenced }
        try permit.validate(owner: owner, action: action)
        try retiredReadinessEndpoint.requireCausalCleanupComplete()
        try revalidateStoppedRepair(permit, for: owner, deadline: permit.deadline)
        let absent: [InstallationSlot]
        switch action {
        case .cleanupBackups: absent = [.applicationPrevious, .predecessorPrevious, .plistPrevious, .hostOwnerPrevious, .hostSocketPrevious]
        case .cleanupIncoming: absent = [.applicationIncoming, .applicationIncomplete, .plistIncoming, .plistIncomplete]
        case .finish: absent = [.predecessorApplication, .stateSource, .applicationPrevious, .predecessorPrevious,
            .plistPrevious, .hostOwnerPrevious, .hostSocketPrevious, .applicationIncoming, .applicationIncomplete,
            .plistIncoming, .plistIncomplete, .installationSocket, .hostOwner, .hostSocket]
        default: throw CustodyRecordError.fenced
        }
        guard absent.allSatisfy({ expected.images[$0]?.node == nil }) else { throw CustodyRecordError.fenced }
        // Each exact no-op has its own durable intent and parent fsync. Never
        // delete unexpected backups/incoming bytes under fresh-install authority.
        for parent in parents {
            guard !permit.deadline.hasExpired else { throw CustodyRecordError.busy }
            try parent.validate()
            guard fsync(parent.fd) == 0 else { throw CustodyRecordError.persistence(errno) }
        }
        try revalidateStoppedRepair(permit, for: owner, deadline: permit.deadline)
        try permit.validate(owner: owner, action: action)
        return expected
    }
    func retireAfterStoppedFinish(_ permit: CustodyCatalogStore.InstallationStagedJournal.FinishPermit) throws {
        guard permit.isStoppedRepair, stoppedCoordinationAccepted, normalHostFiles == nil,
              endpoint == nil, let retiredReadinessEndpoint else { throw CustodyRecordError.fenced }
        try permit.validateSlots(self)
        try revalidateStoppedRepair(stoppedCoordinationPermit, for: owner, deadline: permit.deadline)
        try retiredReadinessEndpoint.requireCausalCleanupComplete()
        for slot in exclusiveNodes.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            try permit.retire(exclusiveNodes[slot]!, resource: .stagedSlots)
        }
        for parent in parents.reversed() { try permit.retire(parent.pinned.ownedDescriptor, resource: .stagedParents) }
    }
    #if SHADOW_SYNC_TESTING
    var testingRestorationCut: InstallationFreshRestorationCut?
    private var testingPlistReachedCut: InstallationFreshRestorationCut?
    var testingRestorationReachedCut: InstallationFreshRestorationCut? { candidateRetirement?.testingReachedCut ?? testingPlistReachedCut }
    var testingRestorationProbe: ((InstallationAction) throws -> Void)?
    var testingRestorationMutationBarrier: ((Int, String) throws -> Void)?
    var testingRestorationResourceFault: InstallationFreshRestorationResourceFault?
    var testingRestorationResourceObservation: InstallationFreshRestorationResourceObservation? { candidateRetirement?.testingResourceObservation }
    var testingRestorationUnlinks: Int { candidateRetirement?.testingUnlinks ?? 0 }
    #endif
    private var readinessRestorationPermit: CustodyCatalogStore.InstallationStagedJournal.ReadinessRestorationPermit?
    private var readinessCoordinationAccepted = false
    private var candidateRetirement: InstallationCandidateRetirement?
    private enum PlistRetirement { case untouched, unlinked, synced, retired }
    private var plistRetirement: PlistRetirement = .untouched
    private var plistRetirementPoisoned = false
    func requireFreshRestorationPreimages() throws {
        guard normalHostFiles == nil, !recordNormalHost,
              let delivery = stoppedHostDelivery, delivery.isReadinessOnly,
              stoppedHostAcknowledgment != nil, stoppedCoordinationPermit == nil else { throw CustodyRecordError.fenced }
        for slot in InstallationSlot.allCases where slot != .stateDestination {
            guard originalPreimages.images[slot]?.node == nil else { throw CustodyRecordError.fenced }
        }
        guard originalPreimages.images[.stateDestination] == expected.images[.stateDestination] else { throw CustodyRecordError.fenced }
    }
    func revalidateFreshRestoration(_ permit: CustodyCatalogStore.InstallationStagedJournal.ReadinessRestorationPermit?,
        for owner: InstallationTransactionOwner, deadline: MonotonicDeadline) throws {
        guard let permit, permit.matches(slots: self), self.owner === owner, !deadline.hasExpired,
              let delivery = stoppedHostDelivery, delivery.isReadinessOnly,
              let acknowledgment = stoppedHostAcknowledgment, normalHostFiles == nil, !recordNormalHost,
              !plistRetirementPoisoned else { throw CustodyRecordError.fenced }
        try binding.revalidate(for: owner) // independently verifies original source, never partial installed bytes
        if readinessCoordinationAccepted {
            guard endpoint == nil else { throw CustodyRecordError.fenced }
            try validateSlots(for: owner, deadline: deadline, stopped: nil)
        } else {
            try validateSlots(for: owner, deadline: deadline, stopped: (delivery, acknowledgment))
        }
    }
    func cleanupReadinessCoordination(_ permit: CustodyCatalogStore.InstallationStagedJournal.ReadinessRestorationPermit)
        throws -> InstallationSlotSnapshot {
        guard permit.matches(slots: self), let endpoint = retainedReadinessEndpoint,
              stoppedHostDelivery?.isReadinessOnly == true, normalHostFiles == nil else { throw CustodyRecordError.fenced }
        try permit.validate(owner: owner, endpoint: endpoint)
        try permit.validateOwner(); try permit.validateDrain()
        if readinessRestorationPermit == nil {
            try revalidateFreshRestoration(permit, for: owner, deadline: permit.deadline)
            try endpoint.prepareReadinessCleanup(permit)
            readinessRestorationPermit = permit
        }
        guard readinessRestorationPermit === permit else { throw CustodyRecordError.fenced }
        let image = try endpoint.retireReadinessCleanup(permit)
        if !readinessCoordinationAccepted {
            var images = expected.images
            guard images[.hostOwner]?.node == nil, images[.hostSocket]?.node == nil else { throw CustodyRecordError.fenced }
            images[.installationSocket] = image; expected = InstallationSlotSnapshot(images: images)
            self.endpoint = nil; retiredReadinessEndpoint = endpoint; readinessCoordinationAccepted = true
        }
        try revalidateFreshRestoration(permit, for: owner, deadline: permit.deadline)
        return expected
    }
    func finishReadinessCoordination(_ permit: CustodyCatalogStore.InstallationStagedJournal.ReadinessRestorationPermit) throws {
        guard readinessRestorationPermit === permit, readinessCoordinationAccepted,
              let retiredReadinessEndpoint else { throw CustodyRecordError.fenced }
        try retiredReadinessEndpoint.completeReadinessCleanup(permit)
    }
    fileprivate func retiringPlistImage(parent: InstallationCaptureParent) throws -> InstallationSlotImage {
        guard parent === parents[1], readinessRestorationPermit != nil, !plistRetirementPoisoned,
              plistRetirement == .unlinked || plistRetirement == .synced,
              let descriptor = exclusiveNodes[.launchPlist], descriptor.retirementObservation == .notAttempted,
              let image = expected.images[.launchPlist], let original = image.node else { throw CustodyRecordError.fenced }
        let name = URL(fileURLWithPath: observer.paths.launchAgent).lastPathComponent
        try parent.absent(name)
        var held = stat()
        guard fstat(descriptor.value,&held) == 0, UInt64(held.st_dev) == original.device,
              UInt64(held.st_ino) == original.inode, held.st_uid == original.uid,
              UInt32(held.st_mode) == original.mode, held.st_nlink == 0, held.st_flags == 0,
              CustodyRecordBinding.digest(Data(try PolicyAuthorityFile.privateStateACL(descriptor.value).utf8)) == original.aclDigest,
              lseek(descriptor.value,0,SEEK_SET) == 0 else { throw CustodyRecordError.conflict }
        let bytes = try InstallationCaptureParent.bytes(descriptor.value, maximum: 65_536)
        guard UInt64(bytes.count) == image.size, CustodyRecordBinding.digest(bytes) == image.contentDigest else { throw CustodyRecordError.conflict }
        return image // private intent comparison, never a published completion
    }
    private func restoreFreshPlist(_ permit: CustodyCatalogStore.InstallationStagedJournal.ReadinessRestorationPermit) throws {
        guard !plistRetirementPoisoned, let original = expected.images[.launchPlist] else { throw CustodyRecordError.fenced }
        if plistRetirement == .retired { guard original.node == nil else { throw CustodyRecordError.fenced }; return }
        let parent = parents[1], name = URL(fileURLWithPath: observer.paths.launchAgent).lastPathComponent
        guard let descriptor = exclusiveNodes[.launchPlist], let node = original.node else { throw CustodyRecordError.fenced }
        try permit.validate(owner: owner, action: .restorePlist)
        if plistRetirement == .untouched {
            try parent.recheck(name, owned: descriptor, node: node, privateMode: true)
            guard lseek(descriptor.value, 0, SEEK_SET) == 0 else { throw CustodyRecordError.fenced }
            let bytes = try InstallationCaptureParent.bytes(descriptor.value, maximum: 65_536)
            guard UInt64(bytes.count) == original.size, CustodyRecordBinding.digest(bytes) == original.contentDigest else { throw CustodyRecordError.conflict }
            try permit.validateMutation(owner: owner, action: .restorePlist)
            try parent.recheck(name, owned: descriptor, node: node, privateMode: true)
            guard !permit.deadline.hasExpired else { throw CustodyRecordError.busy }
            guard unlinkat(parent.fd, name, 0) == 0 else { plistRetirementPoisoned = true; throw CustodyRecordError.persistence(errno) }
            plistRetirement = .unlinked
            #if SHADOW_SYNC_TESTING
            if testingRestorationCut == .plistAfterUnlink { testingPlistReachedCut = testingRestorationCut; testingRestorationCut = nil; throw CustodyRecordError.persistence(EIO) }
            #endif
        }
        try parent.absent(name)
        if plistRetirement == .unlinked {
            #if SHADOW_SYNC_TESTING
            if testingRestorationCut == .plistSyncFailure { testingPlistReachedCut = testingRestorationCut; testingRestorationCut = nil; throw CustodyRecordError.persistence(EIO) }
            #endif
            guard !permit.deadline.hasExpired, fsync(parent.fd) == 0 else { throw CustodyRecordError.persistence(errno) }
            plistRetirement = .synced
            #if SHADOW_SYNC_TESTING
            if testingRestorationCut == .plistAfterSync { testingPlistReachedCut = testingRestorationCut; testingRestorationCut = nil; throw CustodyRecordError.persistence(EIO) }
            #endif
        }
        if plistRetirement == .synced {
            guard !permit.deadline.hasExpired else { throw CustodyRecordError.busy }
            #if SHADOW_SYNC_TESTING
            if testingRestorationCut == .plistCloseUnknown {
                testingPlistReachedCut = testingRestorationCut; testingRestorationCut = nil
                descriptor.testingClose = { raw in guard Darwin.close(raw) == 0 else { return errno }; return EIO }
            }
            #endif
            guard descriptor.retireChecked() == .succeeded else { plistRetirementPoisoned = true; throw CustodyRecordError.fenced }
            plistRetirement = .retired
            exclusiveNodes.removeValue(forKey: .launchPlist)
            var images = expected.images; images[.launchPlist] = originalPreimages.images[.launchPlist]
            expected = InstallationSlotSnapshot(images: images)
        }
    }
    func completeFreshRestoration(_ permit: CustodyCatalogStore.InstallationStagedJournal.ReadinessRestorationPermit,
        action: InstallationAction) throws -> InstallationSlotSnapshot {
        guard permit === readinessRestorationPermit, permit.matches(slots: self), readinessCoordinationAccepted,
              let retiredReadinessEndpoint else { throw CustodyRecordError.fenced }
        try permit.validate(owner: owner, action: action)
        try retiredReadinessEndpoint.requireCausalCleanupComplete()
        try revalidateFreshRestoration(permit, for: owner, deadline: permit.deadline)
        #if SHADOW_SYNC_TESTING
        if let probe = testingRestorationProbe { testingRestorationProbe = nil; try probe(action) }
        #endif
        switch action {
        case .restoreApplication:
            if candidateRetirement == nil {
                guard let root = exclusiveNodes[.application], let image = expected.images[.application], image.node != nil else {
                    throw CustodyRecordError.fenced
                }
                let retirement = InstallationCandidateRetirement(parent: parents[0], root: root,
                    name: URL(fileURLWithPath: observer.paths.app).lastPathComponent, original: image, permit: permit, owner: owner)
                candidateRetirement = retirement // enroll before inventory validation/opening can throw
                #if SHADOW_SYNC_TESTING
                let fixtureRoot: String?
                #if SHADOW_SYNC_SIGNED_FIXTURE
                if case let .signedFixture(profile) = observer.validationProfile { fixtureRoot = try profile.location.anchorPath }
                else { fixtureRoot = observer.testingExclusiveRoot }
                #else
                fixtureRoot = observer.testingExclusiveRoot
                #endif
                guard let fixtureRoot, try InstallationPaths.isolated(root: fixtureRoot) == observer.paths else {
                    throw CustodyRecordError.fenced
                }
                try RuntimeFixtureSession.installationRoot(fixtureRoot).retainNamedSocket(retirement)
                retirement.testingCut = testingRestorationCut
                retirement.testingMutationBarrier = testingRestorationMutationBarrier
                retirement.testingResourceFault = testingRestorationResourceFault
                testingRestorationMutationBarrier = nil; testingRestorationResourceFault = nil
                #endif
                let artifact = try observer.inspectExclusiveBundle(observer.paths.app, candidate: binding.candidate)
                try retirement.prepare(artifact)
            }
            guard let candidateRetirement else { throw CustodyRecordError.fenced }
            let image = try candidateRetirement.retire()
            exclusiveNodes.removeValue(forKey: .application) // exact descriptor already checked closed by owner
            var images = expected.images; images[.application] = image; expected = InstallationSlotSnapshot(images: images)
        case .restorePlist: try restoreFreshPlist(permit)
        case .moveStateBack, .restoreCoordination, .cleanupIncoming, .finish:
            let absent: [InstallationSlot] = action == .moveStateBack ? [.stateSource]
                : action == .restoreCoordination ? [.hostOwner, .hostSocket, .hostOwnerPrevious, .hostSocketPrevious]
                : action == .cleanupIncoming ? [.applicationIncoming, .applicationIncomplete, .plistIncoming, .plistIncomplete]
                : InstallationSlot.allCases.filter { $0 != .stateDestination }
            guard absent.allSatisfy({ expected.images[$0]?.node == nil }),
                  expected.images[.stateDestination] == originalPreimages.images[.stateDestination] else { throw CustodyRecordError.fenced }
            for parent in parents {
                guard !permit.deadline.hasExpired else { throw CustodyRecordError.busy }
                try parent.validate(); guard fsync(parent.fd) == 0 else { throw CustodyRecordError.persistence(errno) }
            }
        default: throw CustodyRecordError.fenced
        }
        try revalidateFreshRestoration(permit, for: owner, deadline: permit.deadline)
        try permit.validate(owner: owner, action: action)
        return expected
    }
    func retireAfterRestoredFinish(_ permit: CustodyCatalogStore.InstallationStagedJournal.FinishPermit) throws {
        guard permit.isRestoredStopped, !permit.isStoppedRepair, readinessCoordinationAccepted,
              normalHostFiles == nil, endpoint == nil, candidateRetirement?.complete == true,
              plistRetirement == .retired, exclusiveNodes.isEmpty, let retiredReadinessEndpoint else { throw CustodyRecordError.fenced }
        try permit.validateSlots(self)
        try revalidateFreshRestoration(readinessRestorationPermit, for: owner, deadline: permit.deadline)
        try retiredReadinessEndpoint.requireCausalCleanupComplete()
        for parent in parents.reversed() { try permit.retire(parent.pinned.ownedDescriptor, resource: .stagedParents) }
    }
    func validateCompletionParents(_ parents: InstallationParentPreparation) throws {
        try parents.requireHome(observer.paths.home)
        try owner.validateInstallationPaths(observer.paths)
    }
    /// Fresh installation has no prior backups, and promotion consumed its
    /// incoming nodes. Unexpected residue refuses; this is not a general remover.
    func completeFreshCleanup(_ permit: CustodyCatalogStore.InstallationStagedJournal.FreshCleanupPermit)
        throws -> InstallationSlotSnapshot {
        try permit.validate(slots: self, owner: owner)
        try revalidate(for: owner, deadline: permit.deadline)
        let absent: [InstallationSlot]
        switch permit.action {
        case .cleanupBackups:
            absent = [.applicationPrevious, .predecessorPrevious, .plistPrevious,
                      .hostOwnerPrevious, .hostSocketPrevious]
        case .cleanupIncoming:
            absent = [.applicationIncoming, .applicationIncomplete, .plistIncoming, .plistIncomplete]
        case .finish:
            absent = [.predecessorApplication, .stateSource, .applicationPrevious, .predecessorPrevious,
                      .plistPrevious, .hostOwnerPrevious, .hostSocketPrevious, .applicationIncoming,
                      .applicationIncomplete, .plistIncoming, .plistIncomplete, .installationSocket]
        default: throw CustodyRecordError.fenced
        }
        guard endpoint == nil, retiredReadinessEndpoint != nil, recordNormalHost,
              normalHostFiles != nil, absent.allSatisfy({ expected.images[$0]?.node == nil }) else {
            throw CustodyRecordError.fenced
        }
        // Exact absence is an evidenced no-op. Fsync retained fixed parents,
        // then re-observe all slots/documents, including the live host nodes.
        #if SHADOW_SYNC_TESTING
        try permit.testingFail(.beforeParentSync)
        #endif
        for (index, parent) in parents.enumerated() {
            guard !permit.deadline.hasExpired else { throw CustodyRecordError.busy }
            try parent.validate()
            #if SHADOW_SYNC_TESTING
            try permit.testingFail(.parentSyncFailure(index))
            #endif
            guard fsync(parent.fd) == 0 else { throw CustodyRecordError.persistence(errno) }
        }
        #if SHADOW_SYNC_TESTING
        try permit.testingFail(.afterParentSync)
        #endif
        try revalidate(for: owner, deadline: permit.deadline)
        try permit.validate(slots: self, owner: owner)
        return expected
    }
    func retireAfterFinish(_ permit: CustodyCatalogStore.InstallationStagedJournal.FinishPermit) throws {
        try permit.validateSlots(self)
        try revalidate(for: owner, deadline: permit.deadline)
        guard endpoint == nil, recordNormalHost, let retiredReadinessEndpoint else { throw CustodyRecordError.fenced }
        try retiredReadinessEndpoint.requireCausalCleanupComplete()
        for slot in exclusiveNodes.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            try permit.retire(exclusiveNodes[slot]!, resource: .stagedSlots)
        }
        for parent in parents.reversed() {
            try permit.retire(parent.pinned.ownedDescriptor, resource: .stagedParents)
        }
    }
    var readinessSnapshot: InstallationSlotSnapshot { expected }
    var retainedReadinessEndpoint: InstallationReadinessEndpoint? { endpoint ?? retiredReadinessEndpoint }
    #if SHADOW_SYNC_TESTING
    var testingEndpointCut: InstallationReadinessEndpoint.TestingCut?
    #endif
    func revalidate(for owner: InstallationTransactionOwner, deadline: MonotonicDeadline) throws {
        try validateSlots(for: owner, deadline: deadline, stopped: nil)
    }
    private func validateSlots(for owner: InstallationTransactionOwner, deadline: MonotonicDeadline,
        stopped: (CustodyCatalogStore.InstallationStagedJournal.StopDelivery, InstallationPrecommitSession.Stopped)?) throws {
        guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        guard self.owner === owner else { throw CustodyRecordError.fenced }
        try binding.revalidate(for: owner)
        let actual = try observer.observeInstallationSlots(binding: binding, transactionID: transactionID, parents: parents, endpoint: endpoint, readinessDeadline: deadline, normalHost: normalHostFiles, recordNormalHost: recordNormalHost, stoppedReadiness: stopped, candidateRetirement: candidateRetirement,
            restoringPlist: plistRetirement == .unlinked || plistRetirement == .synced ? self : nil)
        guard actual.0 == expected, actual.1 == documents else { throw CustodyRecordError.conflict }
        for (slot, descriptor) in exclusiveNodes {
            if slot == .application, candidateRetirement != nil { continue }
            if slot == .launchPlist, plistRetirement == .unlinked || plistRetirement == .synced { continue }
            guard try InstallationCaptureParent.node(descriptor.value, directory: slot.isBundle, privateMode: !slot.isBundle) == expected.images[slot]?.node else { throw CustodyRecordError.conflict }
        }
        try binding.revalidate(for: owner)
    }
}
extension InstallationCapturedSlots {
    func preparedSlotObservation() throws -> InstallationPreparedSlotObservation { try .init(self) }
}

/// Fixed promoted slots, independently pinned by caller and custodian. Neither
/// decoded paths nor an ordinary bootout's old-release exception enter here.
final class InstallationStagedCandidateSlots {
    private let applicationParent: InstallationCaptureParent
    private let plistParent: InstallationCaptureParent
    private let application: OwnedFileDescriptor
    private let plist: OwnedFileDescriptor
    private let expectedApplication: InstallationSlotImage
    private let expectedPlist: InstallationSlotImage
    init(binding: InstallationCommandBinding, account: EffectiveAccount) throws {
        try binding.validate()
        guard binding.stagedMode != nil, let slots = binding.control.transaction?.slots,
              let app = slots.images[.application], let plist = slots.images[.launchPlist],
              app.node != nil, plist.node != nil else { throw CustodyRecordError.fenced }
        if binding.isCommittedStop {
            guard let candidate = binding.control.transaction?.candidate,
                  let commit = binding.control.readinessCommit,
                  commit.candidateBundleDigest == candidate.bundleDigest,
                  commit.candidateReleaseDigest == candidate.release.releaseContractSHA256,
                  app.contentDigest == candidate.bundleDigest else { throw CustodyRecordError.fenced }
        }
        expectedApplication = app; expectedPlist = plist
        applicationParent = try InstallationCaptureParent(account.homeDirectory + "/Applications")
        plistParent = try InstallationCaptureParent(account.homeDirectory + "/Library/LaunchAgents")
        guard let application = try applicationParent.open("ShadowSync.app", directory: true, privateMode: false),
              let launch = try plistParent.open(InstallationPaths.label + ".plist", directory: false, privateMode: true),
              application.1 == app.node, launch.1 == plist.node else { throw CustodyRecordError.fenced }
        self.application = application.0; self.plist = launch.0
        try revalidate()
    }
    func revalidate() throws {
        guard applicationParent.identity.device == expectedApplication.parentDevice,
              applicationParent.identity.inode == expectedApplication.parentInode,
              plistParent.identity.device == expectedPlist.parentDevice,
              plistParent.identity.inode == expectedPlist.parentInode,
              let appNode = expectedApplication.node, let plistNode = expectedPlist.node else { throw CustodyRecordError.fenced }
        try applicationParent.recheck("ShadowSync.app", owned: application, node: appNode, privateMode: false)
        try plistParent.recheck(InstallationPaths.label + ".plist", owned: plist, node: plistNode, privateMode: true)
    }
}

/// Owns the fixed installation endpoint, not installation/operation authority.
/// Only the original journal's durable cleanup permit retires the fixed name.
/// Service closure alone always preserves its named-generation fence.
final class InstallationReadinessEndpoint: @unchecked Sendable {
    private let parent: InstallationCaptureParent
    private let owner: InstallationTransactionOwner
    private let deadline: MonotonicDeadline
    private var address: InstallationNamedSocketObservation.Address?
    private var ancestors: [OwnedFileDescriptor] = []
    private var parentObservation: [InstallationNamedSocketObservation.Parent]?
    private var listenerOwner: OwnedFileDescriptor?
    private var observed: InstallationNamedSocketObservation?
    private enum Phase { case reserved, preparing, boundUnpublished, listening, pending }
    private var phase: Phase = .reserved
    private var serviceClosed = false
    // Enroll before the first acquisition, not just bind: a failed bounded
    // cleanup and dropped journal must preserve every original description.
    // After bind, service close alone never clears the named-generation fence.
    private var retainedSelf: InstallationReadinessEndpoint?
    private var bindAttempted = false
    private static let name = "installation.sock"
    private let serviceLock = NSRecursiveLock()
    // Publication keeps its recursive creator lock. Published observations use
    // a separate, short state lock: it never spans owner validation, native IO,
    // a callback, a wait for readers, or acquisition of serviceLock. Readers
    // retain these exact original descriptions; no dup/reopen creates custody.
    private final class Observation {
        let address: InstallationNamedSocketObservation.Address
        let ancestors: [OwnedFileDescriptor]
        let parents: [InstallationNamedSocketObservation.Parent]
        let named: InstallationNamedSocketObservation
        init(address: InstallationNamedSocketObservation.Address, ancestors: [OwnedFileDescriptor],
             parents: [InstallationNamedSocketObservation.Parent], named: InstallationNamedSocketObservation) {
            self.address = address; self.ancestors = ancestors; self.parents = parents; self.named = named
        }
    }
    private let observationLock = NSLock()
    private var observation: Observation?
    private var observationReaders = 0
    private var observationClosing = false
    private var observationRetiring = false
    fileprivate init(parent: InstallationCaptureParent, owner: InstallationTransactionOwner, deadline: MonotonicDeadline) {
        self.parent = parent; self.owner = owner; self.deadline = deadline
    }
    var listener: OwnedFileDescriptor {
        get throws {
            guard serviceLock.try() else { throw CustodyRecordError.busy }; defer { serviceLock.unlock() }
            guard phase == .listening, !serviceClosed, let listenerOwner else { throw CustodyRecordError.fenced }
            #if SHADOW_SYNC_TESTING
            // Pause the actual service getter while it owns serviceLock. The
            // short observation lock is released before this bounded barrier.
            observationLock.lock()
            let barrier = testingListenerBarrier; testingListenerBarrier = nil
            observationLock.unlock()
            if let barrier, !barrier.pause() { throw CustodyRecordError.busy }
            #endif
            return listenerOwner
        }
    }
    var image: InstallationSlotImage {
        get throws {
            // This immutable metadata image borrows no descriptor. It remains
            // readable through service close, but never during node retirement
            // or after withdrawal. Live validation is the separate reader path.
            observationLock.lock(); defer { observationLock.unlock() }
            guard let snapshot = observation, !observationRetiring else { throw CustodyRecordError.fenced }
            return InstallationSlotImage(parentDevice: parent.identity.device, parentInode: parent.identity.inode,
                node: snapshot.named.nodeIdentity, size: nil, contentDigest: nil, documentReceipts: nil)
        }
    }
    private func validateParents(observationDeadline: MonotonicDeadline? = nil) throws {
        let budget = observationDeadline ?? deadline
        guard !budget.hasExpired else { throw CustodyRecordError.busy }
        try owner.validateReadinessOwner()
        guard let address, let parentObservation,
              try InstallationNamedSocketObservation.parents(address: address, retainedAncestors: ancestors,
                uid: geteuid(), deadline: budget) == parentObservation else { throw CustodyRecordError.conflict }
        try parent.validate()
    }
    // This checks the actual creator's retained descriptions under the same
    // local serialization as bind/mode/listen/close. It cannot be minted by data.
    func validateUnpublishedObservation(address: InstallationNamedSocketObservation.Address,
                                        ancestors: [OwnedFileDescriptor]) throws {
        guard serviceLock.try() else { throw CustodyRecordError.busy }; defer { serviceLock.unlock() }
        guard phase == .boundUnpublished, !serviceClosed, (listenerOwner?.value ?? -1) >= 0,
              self.address?.bytes == address.bytes, ancestors.count == self.ancestors.count,
              zip(ancestors, self.ancestors).allSatisfy({ pair in pair.0 === pair.1 }) else { throw CustodyRecordError.fenced }
        try validateParents()
    }
    fileprivate func publish() throws {
        #if SHADOW_SYNC_TESTING
        var diagnosticStage: UInt8 = 1
        var diagnosticComplete = false
        defer {
            if !diagnosticComplete { InstallationReadinessEndpoint.testingRecordFailure(part: .publisher, stage: diagnosticStage) }
        }
        #endif
        guard serviceLock.try() else { throw CustodyRecordError.busy }; defer { serviceLock.unlock() }
        guard phase == .reserved, !serviceClosed else { throw CustodyRecordError.fenced }
        phase = .preparing
        retainedSelf = self
        do {
            try owner.validateReadinessOwner()
            #if SHADOW_SYNC_TESTING
            diagnosticStage = 2
            #endif
            let address = try InstallationNamedSocketObservation.Address(canonicalParent: parent.pinned.path, endpoint: .installation)
            self.address = address
            #if SHADOW_SYNC_TESTING
            diagnosticStage = 3
            #endif
            try parent.retainSocketAncestors(address, into: &ancestors, deadline: deadline)
            #if SHADOW_SYNC_TESTING
            try testingFail(.afterAncestors)
            #endif
            #if SHADOW_SYNC_TESTING
            diagnosticStage = 4
            #endif
            parentObservation = try InstallationNamedSocketObservation.parents(address: address,
                retainedAncestors: ancestors, uid: geteuid(), deadline: deadline)
            #if SHADOW_SYNC_TESTING
            diagnosticStage = 5
            #endif
            try validateParents(); try parent.absent(Self.name)
            #if SHADOW_SYNC_TESTING
            diagnosticStage = 6
            #endif
            let raw = socket(AF_UNIX, SOCK_STREAM, 0)
            guard raw >= 0 else { throw CustodyRecordError.persistence(errno) }
            listenerOwner = OwnedFileDescriptor(raw)
            try InstallationPrecommitTransport.configure(raw)
            #if SHADOW_SYNC_TESTING
            try testingFail(.beforeBind)
            #endif
            try validateParents(); try parent.absent(Self.name)
            #if SHADOW_SYNC_TESTING
            diagnosticStage = 7
            #endif
            var native = address.socketAddress()
            bindAttempted = true
            let bound = withUnsafePointer(to: &native) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(raw, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0 else { throw CustodyRecordError.persistence(errno) }
            #if SHADOW_SYNC_TESTING
            diagnosticStage = 8
            #endif
            phase = .boundUnpublished
            try validateParents()
            #if SHADOW_SYNC_TESTING
            diagnosticStage = 9
            #endif
            let initial = try InstallationNamedSocketObservation.readUnpublishedCreator(self, address: address,
                retainedAncestors: ancestors, uid: geteuid(), deadline: deadline)
            // Mode is the sole permitted prepublication change. Full no-grant
            // ACL and private-parent safety were decoded before touching it.
            try validateParents()
            #if SHADOW_SYNC_TESTING
            diagnosticStage = 10
            #endif
            let beforeMode = try InstallationNamedSocketObservation.readUnpublishedCreator(self, address: address,
                retainedAncestors: ancestors, uid: geteuid(), deadline: deadline)
            guard beforeMode == initial else { throw CustodyRecordError.conflict }
            #if SHADOW_SYNC_TESTING
            diagnosticStage = 11
            #endif
            guard fchmodat(parent.fd, Self.name, 0o600, AT_SYMLINK_NOFOLLOW) == 0 else { throw CustodyRecordError.persistence(errno) }
            try validateParents()
            #if SHADOW_SYNC_TESTING
            diagnosticStage = 12
            #endif
            let final = try InstallationNamedSocketObservation.read(address: address, retainedAncestors: ancestors,
                uid: geteuid(), deadline: deadline)
            #if SHADOW_SYNC_TESTING
            diagnosticStage = 13
            #endif
            guard initial.sameUnpublishedGeneration(afterMode: final) else { throw CustodyRecordError.conflict }
            observed = final
            #if SHADOW_SYNC_TESTING
            try testingFail(.afterMode)
            #endif
            try validateParents()
            #if SHADOW_SYNC_TESTING
            diagnosticStage = 14
            #endif
            guard try InstallationNamedSocketObservation.read(address: address, retainedAncestors: ancestors,
                uid: geteuid(), deadline: deadline, expected: final) == final else { throw CustodyRecordError.conflict }
            #if SHADOW_SYNC_TESTING
            diagnosticStage = 15
            #endif
            guard listen(raw, 1) == 0, fsync(parent.fd) == 0 else { throw CustodyRecordError.persistence(errno) }
            #if SHADOW_SYNC_TESTING
            try testingFail(.afterListen)
            #endif
            phase = .listening
            guard let parentObservation else { throw CustodyRecordError.fenced }
            observationLock.lock()
            observation = Observation(address: address, ancestors: ancestors, parents: parentObservation, named: final)
            observationLock.unlock()
            #if SHADOW_SYNC_TESTING
            diagnosticStage = 16
            #endif
            try revalidate(deadline: deadline)
            #if SHADOW_SYNC_TESTING
            diagnosticComplete = true
            #endif
        } catch {
            phase = .pending
            observationLock.lock(); observation = nil; observationLock.unlock()
            // No name cleanup, ownership reconstruction or uncertain close retry.
            throw error
        }
    }
    fileprivate static func identity(_ fd: Int32) throws -> InstallationNodeIdentity {
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode == S_IFSOCK | 0o600,
              s.st_uid == geteuid(), s.st_nlink == 1, s.st_flags == 0 else { throw CustodyRecordError.unsafeMetadata }
        return InstallationNodeIdentity(device: UInt64(s.st_dev), inode: UInt64(s.st_ino), type: .socket,
            uid: s.st_uid, mode: UInt32(s.st_mode), links: UInt64(s.st_nlink),
            aclDigest: CustodyRecordBinding.digest(Data(try PolicyAuthorityFile.privateStateACL(fd).utf8)))
    }
    // The existing host-side descriptor helper remains until its separate integration.
    fileprivate func parentMatches(_ other: InstallationNodeIdentity) -> Bool {
        parent.identity.device == other.device && parent.identity.inode == other.inode
            && parent.identity.uid == other.uid && parent.identity.mode == other.mode
            && parent.identity.aclDigest == other.aclDigest && other.links > 0
    }
    func revalidate(deadline budget: MonotonicDeadline,
        stopped: (CustodyCatalogStore.InstallationStagedJournal.StopDelivery, InstallationPrecommitSession.Stopped)? = nil) throws {
        #if SHADOW_SYNC_TESTING
        var diagnosticStage: UInt8 = 1
        InstallationInvocationTesting.stage(1)
        var diagnosticPassed = false
        defer {
            if !diagnosticPassed {
                let savedErrno = errno
                // This defer runs after the reader reservation is released.
                // Reuse its existing lock; no owner validation or output inside.
                observationLock.lock()
                if testingRevalidationFailure == nil {
                    testingRevalidationFailure = TestingRevalidationFailure(
                        stage: TestingRevalidationStage(rawValue: diagnosticStage) ?? .other,
                        metadataCount: UInt16(testingMetadataDeadlines.count))
                }
                observationLock.unlock()
                Self.testingRecordFailure(part: .endpoint, stage: diagnosticStage)
                errno = savedErrno
            }
        }
        #endif
        guard !budget.hasExpired else { throw CustodyRecordError.busy }
        #if SHADOW_SYNC_TESTING
        diagnosticStage = 2
        InstallationInvocationTesting.stage(2)
        #endif
        observationLock.lock()
        guard let snapshot = observation, !observationClosing, !observationRetiring,
              observationReaders < Int.max else {
            observationLock.unlock(); throw CustodyRecordError.fenced
        }
        #if SHADOW_SYNC_TESTING
        diagnosticStage = 4
        InstallationInvocationTesting.stage(4)
        guard testingMetadataDeadlines.count < 512 else {
            observationLock.unlock(); throw CustodyRecordError.busy
        }
        testingMetadataDeadlines.append(budget.absoluteUptimeNanoseconds)
        let barrier = testingObservationBarrier; testingObservationBarrier = nil
        #endif
        observationReaders += 1
        observationLock.unlock()
        defer {
            observationLock.lock(); observationReaders -= 1; observationLock.unlock()
        }
        #if SHADOW_SYNC_TESTING
        if let barrier, barrier.0 == .beforeValidation, !barrier.1.pause() { throw CustodyRecordError.busy }
        diagnosticStage = 5
        InstallationInvocationTesting.stage(5)
        #endif
        try validateParents(snapshot, deadline: budget, stopped: stopped)
        #if SHADOW_SYNC_TESTING
        diagnosticStage = 6
        InstallationInvocationTesting.stage(6)
        InstallationInvocationTesting.locate(.socketRead, node: InstallationInvocationTesting.Node.none)
        #endif
        let current = try InstallationNamedSocketObservation.read(address: snapshot.address,
            retainedAncestors: snapshot.ancestors, uid: geteuid(), deadline: budget)
        #if SHADOW_SYNC_TESTING
        diagnosticStage = 7
        InstallationInvocationTesting.stage(7)
        #endif
        guard snapshot.named.matchesNamedGeneration(current) else { throw CustodyRecordError.conflict }
        #if SHADOW_SYNC_TESTING
        diagnosticStage = 8
        InstallationInvocationTesting.stage(8)
        #endif
        try validateParents(snapshot, deadline: budget, stopped: stopped)
        #if SHADOW_SYNC_TESTING
        if let barrier, barrier.0 == .afterValidation, !barrier.1.pause() { throw CustodyRecordError.busy }
        #endif
        #if SHADOW_SYNC_TESTING
        diagnosticStage = 9
        InstallationInvocationTesting.stage(9)
        #endif
        // Closure cannot retire a description until this reader releases its
        // reservation. A close/publication-failure overlap invalidates success;
        // a later observation of a closed service still validates its named fence.
        observationLock.lock()
        let unchanged = observation === snapshot && !observationClosing && !observationRetiring
        observationLock.unlock()
        guard unchanged else { throw CustodyRecordError.fenced }
        #if SHADOW_SYNC_TESTING
        diagnosticStage = 10
        InstallationInvocationTesting.stage(10)
        #endif
        guard !budget.hasExpired else { throw CustodyRecordError.busy }
        #if SHADOW_SYNC_TESTING
        diagnosticPassed = true
        #endif
    }
    private func validateParents(_ snapshot: Observation, deadline budget: MonotonicDeadline,
        stopped: (CustodyCatalogStore.InstallationStagedJournal.StopDelivery, InstallationPrecommitSession.Stopped)? = nil) throws {
        guard !budget.hasExpired else { throw CustodyRecordError.busy }
        #if SHADOW_SYNC_TESTING
        InstallationInvocationTesting.locate(.owner, node: InstallationInvocationTesting.Node.none)
        #endif
        if let stopped {
            guard budget.absoluteUptimeNanoseconds == stopped.1.deadline.absoluteUptimeNanoseconds else {
                throw CustodyRecordError.fenced
            }
            try stopped.0.validateStoppedOwner(owner, acknowledgment: stopped.1)
            try owner.revalidate()
        } else { try owner.validateReadinessOwner() }
        #if SHADOW_SYNC_TESTING
        InstallationInvocationTesting.locate(.namedAncestors, node: InstallationInvocationTesting.Node.none)
        #endif
        guard try InstallationNamedSocketObservation.parents(address: snapshot.address,
            retainedAncestors: snapshot.ancestors, uid: geteuid(), deadline: budget) == snapshot.parents else {
            throw CustodyRecordError.conflict
        }
        #if SHADOW_SYNC_TESTING
        InstallationInvocationTesting.locate(.retainedParent, node: InstallationInvocationTesting.Node.none)
        #endif
        try parent.validate()
    }
    // Service closure is not node retirement. The original owner, chain, pending
    // state and real close result stay retained by the pre-enrolled endpoint.
    func closeService() {
        // A concurrent observation cannot make close wait beyond its caller's
        // existing budget. The journal already fenced admission; its joined
        // close check reports pending until this original owner can close.
        guard serviceLock.try() else { return }; defer { serviceLock.unlock() }
        // Successful service close is idempotent. Later named-fence readers
        // neither reopen the listener nor need to be cancelled by another close.
        if serviceClosed, bindAttempted, listenerOwner?.retirementObservation == .succeeded { return }
        serviceClosed = true
        observationLock.lock()
        observationClosing = true
        let readers = observationReaders
        observationLock.unlock()
        // No join or native close while an actual observation owns the originals.
        // Closing stays latched; the existing joined caller retries on this owner.
        guard readers == 0 else { return }
        if let listenerOwner, listenerOwner.retireChecked() != .succeeded { return }
        observationLock.lock(); observationClosing = false; observationLock.unlock()
        // Without any bind attempt, no name was created. Retire only descriptions
        // acquired here; P belongs to the original slots and is never borrowed
        // as close authority. Checked-close is one-shot, including uncertainty.
        if !bindAttempted, retireAcquiredAncestors() { retainedSelf = nil }
    }
    private func retireAcquiredAncestors() -> Bool {
        var retired = true
        for descriptor in ancestors where descriptor !== parent.pinned.ownedDescriptor {
            if descriptor.retireChecked() != .succeeded { retired = false }
        }
        return retired
    }
    func requireServiceClosed() throws {
        guard serviceLock.try() else { throw CustodyRecordError.busy }; defer { serviceLock.unlock() }
        guard serviceClosed else { throw CustodyRecordError.fenced }
        observationLock.lock()
        let closePending = observationClosing
        observationLock.unlock()
        // A successful close may already have new metadata-only readers. Node
        // retirement, unlike service closure, separately requires zero readers.
        guard !closePending else { throw CustodyRecordError.fenced }
        if !bindAttempted, retainedSelf != nil { throw CustodyRecordError.fenced }
        if let listenerOwner {
            guard listenerOwner.retirementObservation == .succeeded else { throw CustodyRecordError.fenced }
        }
    }
    enum CleanupStage: String {
        case untouched, claimed, unlinked, parentSynced, absentVerified, ancestorsRetired, complete
    }
    private var cleanupStage: CleanupStage = .untouched
    private var cleanupPermit: CustodyCatalogStore.InstallationStagedJournal.CleanupPermit?
    private var cleanupPostimage: CleanupPostimage?
    /// Unforgeable result of this endpoint's one fixed unlink action. It remains
    /// retained through every publication/close cut, including after name loss.
    final class CleanupPostimage {
        fileprivate let endpoint: InstallationReadinessEndpoint
        fileprivate let permit: CustodyCatalogStore.InstallationStagedJournal.CleanupPermit
        fileprivate let image: InstallationSlotImage
        fileprivate init(endpoint: InstallationReadinessEndpoint,
            permit: CustodyCatalogStore.InstallationStagedJournal.CleanupPermit, image: InstallationSlotImage) {
            self.endpoint = endpoint; self.permit = permit; self.image = image
        }
        fileprivate func validate(endpoint: InstallationReadinessEndpoint,
            permit: CustodyCatalogStore.InstallationStagedJournal.CleanupPermit) throws {
            guard self.endpoint === endpoint, self.permit === permit,
                  endpoint.cleanupPostimage === self, endpoint.cleanupStage == .absentVerified else {
                throw CustodyRecordError.fenced
            }
        }
    }
    // Shares the causal retirement stages and retained ancestors with normal
    // cleanup, but requires a different stopped capability and exact host nodes.
    private var stoppedCleanupPermit: CustodyCatalogStore.InstallationStagedJournal.StoppedCleanupPermit?
    private var stoppedOwnerImage: InstallationSlotImage?
    private var stoppedSocketImage: InstallationSlotImage?
    private var stoppedOwnerDescriptor: OwnedFileDescriptor?
    private var stoppedSocketRemoved = false
    private var stoppedOwnerRemoved = false
    private var stoppedHostSynced = false
    fileprivate func prepareStoppedCleanup(_ permit: CustodyCatalogStore.InstallationStagedJournal.StoppedCleanupPermit,
                                           files: InstallationNormalHostFiles) throws {
        try permit.validate(owner: owner, endpoint: self)
        try permit.validateOwner(); try permit.validateDrain(); try requireServiceClosed()
        let ownerImage = try files.image(.hostOwner, parent: parent)
        let socketImage = try files.image(.hostSocket, parent: parent)
        guard serviceLock.try() else { throw CustodyRecordError.busy }; defer { serviceLock.unlock() }
        guard stoppedCleanupPermit == nil, cleanupPermit == nil, cleanupStage == .untouched,
              retainedSelf === self, phase == .listening else { throw CustodyRecordError.fenced }
        stoppedCleanupPermit = permit; stoppedOwnerImage = ownerImage; stoppedSocketImage = socketImage
        // Enroll the exact child before even identity validation can throw.
        guard let (descriptor, node) = try parent.open("host-owner.json", directory: false, privateMode: true,
            enroll: { self.stoppedOwnerDescriptor = $0 }), node == ownerImage.node else { throw CustodyRecordError.fenced }
        guard descriptor === stoppedOwnerDescriptor else { throw CustodyRecordError.fenced }
        try validateStoppedOwnerBytes()
    }
    private func validateStoppedParents(_ permit: CustodyCatalogStore.InstallationStagedJournal.StoppedCleanupPermit) throws {
        guard !permit.deadline.hasExpired, let address, let parentObservation,
              try InstallationNamedSocketObservation.parents(address: address, retainedAncestors: ancestors,
                uid: geteuid(), deadline: permit.deadline) == parentObservation else { throw CustodyRecordError.conflict }
        try parent.validate()
    }
    private func validateStoppedOwnerBytes() throws {
        guard let descriptor = stoppedOwnerDescriptor, let image = stoppedOwnerImage, let node = image.node,
              descriptor.retirementObservation == .notAttempted,
              lseek(descriptor.value, 0, SEEK_SET) == 0 else { throw CustodyRecordError.fenced }
        let bytes = try InstallationCaptureParent.bytes(descriptor.value, maximum: 16_384)
        guard UInt64(bytes.count) == image.size, CustodyRecordBinding.digest(bytes) == image.contentDigest else {
            throw CustodyRecordError.conflict
        }
        try parent.recheck("host-owner.json", owned: descriptor, node: node, privateMode: true)
    }
    fileprivate func retireStoppedCleanup(_ permit: CustodyCatalogStore.InstallationStagedJournal.StoppedCleanupPermit)
        throws -> InstallationSlotImage {
        try permit.validate(owner: owner, endpoint: self)
        try permit.validateOwner(); try permit.validateDrain(); try requireServiceClosed()
        guard serviceLock.try() else { throw CustodyRecordError.busy }; defer { serviceLock.unlock() }
        guard stoppedCleanupPermit === permit, cleanupPermit == nil,
              retainedSelf === self, phase == .listening else { throw CustodyRecordError.fenced }
        if cleanupStage == .untouched {
            observationLock.lock()
            guard observationReaders == 0, !observationClosing, !observationRetiring, observation != nil else {
                observationLock.unlock(); throw CustodyRecordError.busy
            }
            observationRetiring = true; observationLock.unlock(); cleanupStage = .claimed
        }
        try validateStoppedParents(permit)
        // Only fixed known causal stages reconcile. The flags are set directly
        // after successful unlink; absence without that retained result refuses.
        if !stoppedSocketRemoved {
            try validateStoppedOwnerBytes()
            let address = try InstallationNamedSocketObservation.Address(canonicalParent: parent.pinned.path, endpoint: .host)
            let actual = try InstallationNamedSocketObservation.read(address: address, retainedAncestors: ancestors,
                uid: geteuid(), deadline: permit.deadline)
            guard actual.nodeIdentity == stoppedSocketImage?.node else { throw CustodyRecordError.conflict }
            try permit.validate(owner: owner, endpoint: self); try validateStoppedParents(permit)
            guard unlinkat(parent.fd, "host.sock", 0) == 0 else { throw CustodyRecordError.persistence(errno) }
            stoppedSocketRemoved = true
        }
        try parent.absent("host.sock")
        if !stoppedOwnerRemoved {
            try validateStoppedOwnerBytes(); try validateStoppedParents(permit)
            guard unlinkat(parent.fd, "host-owner.json", 0) == 0 else { throw CustodyRecordError.persistence(errno) }
            stoppedOwnerRemoved = true
        }
        try parent.absent("host-owner.json")
        if !stoppedHostSynced {
            guard fsync(parent.fd) == 0 else { throw CustodyRecordError.persistence(errno) }
            stoppedHostSynced = true
        }
        if cleanupStage == .claimed {
            guard let address, let observed else { throw CustodyRecordError.fenced }
            try validateStoppedParents(permit)
            guard try InstallationNamedSocketObservation.read(address: address, retainedAncestors: ancestors,
                uid: geteuid(), deadline: permit.deadline, expected: observed) == observed else { throw CustodyRecordError.conflict }
            #if SHADOW_SYNC_TESTING
            try testingCleanupFail(.beforeUnlink)
            if testingCleanupCut == .unlinkFailure { testingCleanupCut = nil; throw CustodyRecordError.persistence(EIO) }
            #endif
            guard unlinkat(parent.fd, Self.name, 0) == 0 else { throw CustodyRecordError.persistence(errno) }
            cleanupStage = .unlinked
            #if SHADOW_SYNC_TESTING
            try testingCleanupFail(.afterUnlink)
            #endif
        }
        if cleanupStage == .unlinked {
            try parent.absent(Self.name); try validateStoppedParents(permit)
            #if SHADOW_SYNC_TESTING
            if testingCleanupCut == .parentSyncFailure { testingCleanupCut = nil; throw CustodyRecordError.persistence(EIO) }
            #endif
            guard fsync(parent.fd) == 0 else { throw CustodyRecordError.persistence(errno) }
            cleanupStage = .parentSynced
            #if SHADOW_SYNC_TESTING
            try testingCleanupFail(.afterParentSync)
            #endif
        }
        guard cleanupStage == .parentSynced || cleanupStage == .absentVerified else { throw CustodyRecordError.fenced }
        try parent.absent(Self.name); try parent.absent("host.sock"); try parent.absent("host-owner.json")
        try validateStoppedParents(permit)
        guard let descriptor = stoppedOwnerDescriptor, descriptor.retireChecked() == .succeeded else {
            throw CustodyRecordError.fenced
        }
        cleanupStage = .absentVerified
        return InstallationSlotImage(parentDevice: parent.identity.device, parentInode: parent.identity.inode,
            node: nil, size: nil, contentDigest: nil, documentReceipts: nil)
    }
    fileprivate func completeStoppedCleanup(_ permit: CustodyCatalogStore.InstallationStagedJournal.StoppedCleanupPermit) throws {
        try permit.validate(owner: owner, endpoint: self, completion: true)
        try permit.validateOwner(); try permit.validateDrain()
        guard serviceLock.try() else { throw CustodyRecordError.busy }; defer { serviceLock.unlock() }
        if cleanupStage == .complete { try requireCausalCleanupComplete(); return }
        guard stoppedCleanupPermit === permit, cleanupStage == .absentVerified,
              stoppedOwnerDescriptor?.retirementObservation == .succeeded,
              stoppedSocketRemoved, stoppedOwnerRemoved, stoppedHostSynced else { throw CustodyRecordError.fenced }
        try parent.absent(Self.name); try parent.absent("host.sock"); try parent.absent("host-owner.json")
        try validateStoppedParents(permit)
        #if SHADOW_SYNC_TESTING
        try testingCleanupFail(.beforeAncestorClose)
        #endif
        guard retireAcquiredAncestors() else { throw CustodyRecordError.fenced }
        cleanupStage = .ancestorsRetired
        try parent.validate(); try parent.absent(Self.name)
        observationLock.lock(); observation = nil; observationLock.unlock()
        cleanupStage = .complete; retainedSelf = nil; stoppedCleanupPermit = nil
    }
    // Readiness-only retirement has its own permit and positively absent host
    // preimages. It cannot enter the committed-host cleanup branch.
    private var readinessCleanupPoisoned = false
    private var readinessCleanupPermit: CustodyCatalogStore.InstallationStagedJournal.ReadinessRestorationPermit?
    fileprivate func prepareReadinessCleanup(_ permit: CustodyCatalogStore.InstallationStagedJournal.ReadinessRestorationPermit) throws {
        try permit.validate(owner: owner, endpoint: self)
        try permit.validateOwner(); try permit.validateDrain(); try requireServiceClosed()
        try parent.absent("host-owner.json"); try parent.absent("host.sock")
        guard serviceLock.try() else { throw CustodyRecordError.busy }; defer { serviceLock.unlock() }
        guard readinessCleanupPermit == nil, stoppedCleanupPermit == nil, cleanupPermit == nil,
              cleanupStage == .untouched, retainedSelf === self, phase == .listening else { throw CustodyRecordError.fenced }
        readinessCleanupPermit = permit
    }
    private func validateReadinessParents(_ permit: CustodyCatalogStore.InstallationStagedJournal.ReadinessRestorationPermit) throws {
        guard !permit.deadline.hasExpired, let address, let parentObservation,
              try InstallationNamedSocketObservation.parents(address: address, retainedAncestors: ancestors,
                uid: geteuid(), deadline: permit.deadline) == parentObservation else { throw CustodyRecordError.conflict }
        try parent.validate()
    }
    fileprivate func retireReadinessCleanup(_ permit: CustodyCatalogStore.InstallationStagedJournal.ReadinessRestorationPermit)
        throws -> InstallationSlotImage {
        try permit.validate(owner: owner, endpoint: self)
        try permit.validateOwner(); try permit.validateDrain(); try requireServiceClosed()
        guard serviceLock.try() else { throw CustodyRecordError.busy }; defer { serviceLock.unlock() }
        guard !readinessCleanupPoisoned, readinessCleanupPermit === permit, cleanupPermit == nil,
              retainedSelf === self, phase == .listening else { throw CustodyRecordError.fenced }
        if cleanupStage == .untouched {
            observationLock.lock()
            guard observationReaders == 0, !observationClosing, !observationRetiring, observation != nil else {
                observationLock.unlock(); throw CustodyRecordError.busy
            }
            observationRetiring = true; observationLock.unlock(); cleanupStage = .claimed
        }
        try validateReadinessParents(permit)
        try parent.absent("host.sock"); try parent.absent("host-owner.json")
        if cleanupStage == .claimed {
            guard let address, let observed else { throw CustodyRecordError.fenced }
            try validateReadinessParents(permit)
            guard try InstallationNamedSocketObservation.read(address: address, retainedAncestors: ancestors,
                uid: geteuid(), deadline: permit.deadline, expected: observed) == observed else { throw CustodyRecordError.conflict }
            #if SHADOW_SYNC_TESTING
            try testingCleanupFail(.beforeUnlink)
            if testingCleanupCut == .unlinkFailure { testingCleanupCut = nil; throw CustodyRecordError.persistence(EIO) }
            #endif
            guard unlinkat(parent.fd, Self.name, 0) == 0 else { readinessCleanupPoisoned = true; throw CustodyRecordError.persistence(errno) }
            cleanupStage = .unlinked
            #if SHADOW_SYNC_TESTING
            try testingCleanupFail(.afterUnlink)
            #endif
        }
        if cleanupStage == .unlinked {
            try parent.absent(Self.name); try validateReadinessParents(permit)
            #if SHADOW_SYNC_TESTING
            if testingCleanupCut == .parentSyncFailure { testingCleanupCut = nil; throw CustodyRecordError.persistence(EIO) }
            #endif
            guard fsync(parent.fd) == 0 else { throw CustodyRecordError.persistence(errno) }
            cleanupStage = .parentSynced
            #if SHADOW_SYNC_TESTING
            try testingCleanupFail(.afterParentSync)
            #endif
        }
        guard cleanupStage == .parentSynced || cleanupStage == .absentVerified else { throw CustodyRecordError.fenced }
        try parent.absent(Self.name); try parent.absent("host.sock"); try parent.absent("host-owner.json")
        try validateReadinessParents(permit)
        cleanupStage = .absentVerified
        return InstallationSlotImage(parentDevice: parent.identity.device, parentInode: parent.identity.inode,
            node: nil, size: nil, contentDigest: nil, documentReceipts: nil)
    }
    fileprivate func completeReadinessCleanup(_ permit: CustodyCatalogStore.InstallationStagedJournal.ReadinessRestorationPermit) throws {
        try permit.validate(owner: owner, endpoint: self, completion: true)
        try permit.validateOwner(); try permit.validateDrain()
        guard serviceLock.try() else { throw CustodyRecordError.busy }; defer { serviceLock.unlock() }
        if cleanupStage == .complete { try requireCausalCleanupComplete(); return }
        guard readinessCleanupPermit === permit, cleanupStage == .absentVerified else { throw CustodyRecordError.fenced }
        try parent.absent(Self.name); try parent.absent("host.sock"); try parent.absent("host-owner.json")
        try validateReadinessParents(permit)
        #if SHADOW_SYNC_TESTING
        try testingCleanupFail(.beforeAncestorClose)
        #endif
        guard retireAcquiredAncestors() else { throw CustodyRecordError.fenced }
        cleanupStage = .ancestorsRetired
        try parent.validate(); try parent.absent(Self.name)
        observationLock.lock(); observation = nil; observationLock.unlock()
        cleanupStage = .complete; retainedSelf = nil; readinessCleanupPermit = nil
    }
    func retireForCleanup(_ permit: CustodyCatalogStore.InstallationStagedJournal.CleanupPermit,
                          joined: InstallationPrecommitSession.CleanupJoined) throws -> CleanupPostimage {
        // Validate causal authority before taking endpoint serialization. This
        // action never waits for session/observation owners while holding it.
        try permit.validateNamedImage(try image, endpoint: self, owner: owner)
        try joined.validate(permit)
        guard serviceLock.try() else { throw CustodyRecordError.busy }; defer { serviceLock.unlock() }
        guard cleanupStage == .untouched, cleanupPermit == nil, phase == .listening,
              bindAttempted, retainedSelf === self else { throw CustodyRecordError.fenced }
        cleanupPermit = permit; cleanupStage = .claimed
        try requireServiceClosed()
        observationLock.lock()
        guard observationReaders == 0, !observationClosing, !observationRetiring, observation != nil else {
            observationLock.unlock(); throw CustodyRecordError.busy
        }
        // Permanent withdrawal: no new reader may race the causal mutation.
        observationRetiring = true
        observationLock.unlock()
        let budget = permit.deadline
        try validateParents(observationDeadline: budget)
        guard let address, let observed else { throw CustodyRecordError.fenced }
        let current = try InstallationNamedSocketObservation.read(address: address, retainedAncestors: ancestors,
            uid: geteuid(), deadline: budget)
        guard observed.matchesNamedGeneration(current) else { throw CustodyRecordError.conflict }
        try permit.validate(endpoint: self, owner: owner)
        try validateParents(observationDeadline: budget)
        guard try InstallationNamedSocketObservation.read(address: address, retainedAncestors: ancestors,
            uid: geteuid(), deadline: budget, expected: observed) == observed else { throw CustodyRecordError.conflict }
        #if SHADOW_SYNC_TESTING
        try testingCleanupFail(.beforeUnlink)
        if testingCleanupCut == .unlinkFailure { testingCleanupCut = nil; throw CustodyRecordError.persistence(EIO) }
        #endif
        guard unlinkat(parent.fd, Self.name, 0) == 0 else { throw CustodyRecordError.persistence(errno) }
        cleanupStage = .unlinked
        #if SHADOW_SYNC_TESTING
        try testingCleanupFail(.afterUnlink)
        if testingCleanupCut == .parentSyncFailure { testingCleanupCut = nil; throw CustodyRecordError.persistence(EIO) }
        #endif
        guard fsync(parent.fd) == 0 else { throw CustodyRecordError.persistence(errno) }
        cleanupStage = .parentSynced
        #if SHADOW_SYNC_TESTING
        try testingCleanupFail(.afterParentSync)
        #endif
        try parent.absent(Self.name)
        try validateParents(observationDeadline: budget)
        cleanupStage = .absentVerified
        let result = CleanupPostimage(endpoint: self, permit: permit,
            image: InstallationSlotImage(parentDevice: parent.identity.device, parentInode: parent.identity.inode,
                node: nil, size: nil, contentDigest: nil, documentReceipts: nil))
        cleanupPostimage = result
        return result
    }
    func completeCleanup(_ permit: CustodyCatalogStore.InstallationStagedJournal.CleanupPermit,
                         postimage: CleanupPostimage) throws {
        try permit.validate(endpoint: self, owner: owner, completion: true)
        guard serviceLock.try() else { throw CustodyRecordError.busy }; defer { serviceLock.unlock() }
        try postimage.validate(endpoint: self, permit: permit)
        try parent.absent(Self.name)
        try validateParents(observationDeadline: permit.deadline)
        #if SHADOW_SYNC_TESTING
        try testingCleanupFail(.beforeAncestorClose)
        #endif
        guard retireAcquiredAncestors() else { throw CustodyRecordError.fenced }
        cleanupStage = .ancestorsRetired
        // Original P is shared with slots and remains live. No now-closed
        // ancestor is consulted or reopened to manufacture a new generation.
        try parent.validate(); try parent.absent(Self.name)
        try permit.validate(endpoint: self, owner: owner, completion: true)
        observationLock.lock(); observation = nil; observationLock.unlock()
        cleanupStage = .complete; retainedSelf = nil; cleanupPermit = nil; cleanupPostimage = nil
    }
    fileprivate func requireCausalCleanupComplete() throws {
        guard serviceLock.try() else { throw CustodyRecordError.busy }; defer { serviceLock.unlock() }
        guard cleanupStage == .complete, retainedSelf == nil, cleanupPermit == nil, cleanupPostimage == nil,
              stoppedCleanupPermit == nil,
              stoppedOwnerDescriptor == nil || stoppedOwnerDescriptor?.retirementObservation == .succeeded,
              listenerOwner?.retirementObservation == .succeeded else { throw CustodyRecordError.fenced }
        guard observationLock.try() else { throw CustodyRecordError.busy }; defer { observationLock.unlock() }
        guard observationReaders == 0, !observationClosing, observationRetiring, observation == nil,
              ancestors.filter({ $0 !== parent.pinned.ownedDescriptor }).allSatisfy({ $0.retirementObservation == .succeeded }) else {
            throw CustodyRecordError.fenced
        }
    }
    #if SHADOW_SYNC_TESTING
    @inline(never)
    func testingCleanupDescriptor(ancestor: Bool) throws -> OwnedFileDescriptor {
        guard serviceLock.try() else { throw CustodyRecordError.busy }; defer { serviceLock.unlock() }
        let selected = ancestor ? ancestors.first(where: { $0 !== parent.pinned.ownedDescriptor }) : listenerOwner
        guard let selected, selected.retirementObservation == .notAttempted,
              retainedSelf === self else { throw CustodyRecordError.fenced }
        return selected
    }
    func testingCleanupRetains(_ descriptor: OwnedFileDescriptor, ancestor: Bool) -> Bool {
        guard serviceLock.try() else { return false }; defer { serviceLock.unlock() }
        if ancestor { return ancestors.contains(where: { $0 === descriptor && $0 !== parent.pinned.ownedDescriptor }) }
        return listenerOwner === descriptor
    }
    var testingCleanupSharedParentLive: Bool { parent.fd >= 0 }
    enum CleanupCut: CaseIterable { case beforeUnlink, unlinkFailure, afterUnlink, parentSyncFailure, afterParentSync, beforeAncestorClose }
    var testingCleanupCut: CleanupCut?
    var testingCleanupStage: CleanupStage { cleanupStage }
    private func testingCleanupFail(_ cut: CleanupCut) throws {
        if testingCleanupCut == cut { testingCleanupCut = nil; throw CustodyRecordError.injectedFailure }
    }
    #endif
    #if SHADOW_SYNC_TESTING
    enum TestingFailurePart: UInt8 { case slots = 1, publisher, journal, endpoint }
    private final class TestingFailureSink: @unchecked Sendable {
        private let lock = NSLock()
        private let enabled = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_M6_DIAGNOSTICS"] == "1"
        private var count = 0
        func record(part: TestingFailurePart, stage: UInt8) {
            lock.lock(); defer { lock.unlock() }
            guard enabled, count < 16 else { return }
            count += 1
            fputs("M6 READINESS FIRST FAILURE part=\(part.rawValue) stage=\(stage)\n", stderr)
            fflush(stderr)
        }
    }
    private static let testingFailureSink = TestingFailureSink()
    static func testingRecordFailure(part: TestingFailurePart, stage: UInt8) {
        testingFailureSink.record(part: part, stage: stage)
    }
    enum TestingCut { case afterAncestors, beforeBind, afterMode, afterListen }
    enum TestingRevalidationStage: UInt8 {
        case entry = 1, snapshot = 2, capacity = 4, firstParents = 5, namedRead = 6, namedMatch = 7, secondParents = 8
        case snapshotPostflight = 9, deadlinePostflight = 10
        case other = 0
    }
    struct TestingRevalidationFailure {
        let stage: TestingRevalidationStage
        let metadataCount: UInt16 // Existing storage is bounded by 512.
    }
    private var testingRevalidationFailure: TestingRevalidationFailure?
    var testingFirstRevalidationFailure: TestingRevalidationFailure? {
        observationLock.lock(); defer { observationLock.unlock() }; return testingRevalidationFailure
    }
    private var testingMetadataDeadlines: [UInt64] = []
    // Actual metadata primitive only; no retained parent or authority is returned.
    static func testingObserveParentNode(_ descriptor: Int32) throws {
        _ = try InstallationCaptureParent.node(descriptor, directory: true, privateMode: false)
    }
    enum TestingObservationPoint { case beforeValidation, afterValidation }
    private var testingObservationBarrier: (TestingObservationPoint, CustodyLeaseTestingBarrier)?
    private var testingListenerBarrier: CustodyLeaseTestingBarrier?
    func testingPauseNextListener(barrier: CustodyLeaseTestingBarrier) {
        observationLock.lock(); defer { observationLock.unlock() }
        testingListenerBarrier = barrier
    }
    func testingPauseNextObservation(at point: TestingObservationPoint, barrier: CustodyLeaseTestingBarrier) {
        observationLock.lock(); defer { observationLock.unlock() }
        testingObservationBarrier = (point, barrier)
    }
    var testingActiveObservations: Int {
        observationLock.lock(); defer { observationLock.unlock() }; return observationReaders
    }
    var testingObservedMetadataDeadlines: [UInt64] {
        observationLock.lock(); defer { observationLock.unlock() }; return testingMetadataDeadlines
    }
    // Legacy fixture calls retain their assertions; production must name its phase.
    func revalidate() throws { try revalidate(deadline: deadline) }
    var testingAcquisitionRetained: Bool {
        guard serviceLock.try() else { return false }; defer { serviceLock.unlock() }
        return retainedSelf === self
    }
    private var testingUnlinked = false
    private var testingRetired = false
    var testingCut: TestingCut?
    private func testingFail(_ cut: TestingCut) throws {
        if testingCut == cut { testingCut = nil; throw CustodyRecordError.fenced }
    }
    var testingPartialRetained: Bool {
        guard serviceLock.try() else { return false }; defer { serviceLock.unlock() }
        return phase == .pending && listenerOwner != nil && !ancestors.isEmpty && observed != nil
    }
    private func testingRemoveClaimedEndpoint(_ budget: MonotonicDeadline) throws {
        try validateParents(observationDeadline: budget)
        guard let address, let observed else { throw CustodyRecordError.fenced }
        let current = try InstallationNamedSocketObservation.read(address: address, retainedAncestors: ancestors,
            uid: geteuid(), deadline: budget)
        guard observed.matchesNamedGeneration(current) else { throw CustodyRecordError.conflict }
        guard unlinkat(parent.fd, Self.name, 0) == 0 else { throw CustodyRecordError.persistence(errno) }
        testingUnlinked = true
        guard fsync(parent.fd) == 0 else { throw CustodyRecordError.persistence(errno) }
        try parent.absent(Self.name); try validateParents(observationDeadline: budget)
        guard retireAcquiredAncestors() else { throw CustodyRecordError.fenced }
        testingRetired = true; retainedSelf = nil
    }
    func testingRemoveOwnedEndpoint(deadline cleanup: MonotonicDeadline? = nil) throws {
        guard serviceLock.try() else { throw CustodyRecordError.busy }; defer { serviceLock.unlock() }
        if testingRetired || cleanupStage == .complete { return }
        let budget = cleanup ?? deadline
        closeService(); try requireServiceClosed()
        // Fixture-root ownership is separate from production authority. After
        // the fixture has joined all work it may drain this exact failed action.
        if cleanupStage != .untouched {
            guard cleanupStage != .claimed else {
                observationLock.lock(); observationRetiring = false; observationLock.unlock()
                return try testingRemoveClaimedEndpoint(budget)
            }
            try parent.validate(); try parent.absent(Self.name)
            guard fsync(parent.fd) == 0, retireAcquiredAncestors() else { throw CustodyRecordError.fenced }
            testingRetired = true; retainedSelf = nil; return
        }
        observationLock.lock()
        guard observationReaders == 0, !observationRetiring else {
            observationLock.unlock(); throw CustodyRecordError.busy
        }
        observationRetiring = true
        observationLock.unlock()
        defer {
            observationLock.lock(); observationRetiring = false; observationLock.unlock()
        }
        // No bind attempt means no created name and no node-close receipt.
        guard bindAttempted else { testingRetired = true; return }
        if testingUnlinked {
            // Postflight already completed before any acquired descriptions
            // retired. Never observe through closed originals or claim a new
            // post-unlink identity; uncertainty remains latched and fenced.
            guard retireAcquiredAncestors() else { throw CustodyRecordError.fenced }
            testingRetired = true; retainedSelf = nil; return
        }
        try validateParents(observationDeadline: budget)
        guard let address, let observed else { throw CustodyRecordError.fenced }
        let current = try InstallationNamedSocketObservation.read(address: address, retainedAncestors: ancestors,
            uid: geteuid(), deadline: budget)
        guard observed.matchesNamedGeneration(current) else { throw CustodyRecordError.conflict }
        guard unlinkat(parent.fd, Self.name, 0) == 0, fsync(parent.fd) == 0 else { throw CustodyRecordError.persistence(errno) }
        try parent.absent(Self.name)
        try validateParents(observationDeadline: budget)
        testingUnlinked = true
        observationLock.lock(); observation = nil; observationLock.unlock()
        guard retireAcquiredAncestors() else { throw CustodyRecordError.fenced }
        testingRetired = true; retainedSelf = nil
    }
    #endif
}

#if SHADOW_SYNC_TESTING
// The original registered root invokes this only after it has joined every
// journal and fixture work item. This remains fixture-root cleanup authority.
extension InstallationReadinessEndpoint: InstallationNamedSocketFixtureCustodyOwner {
    func retireNamedSocketFixture(deadline: MonotonicDeadline) throws {
        try testingRemoveOwnedEndpoint(deadline: deadline)
    }
}
#endif

/// Two created normal-host nodes, admitted only by an actual retained server
/// or this stream's privately minted, native-authenticated normal-started event.
/// The immutable transaction's preimage is never rewritten. Every other slot
/// still compares exactly; these observations grant no write/cleanup authority.
final class InstallationNormalHostFiles {
    private let readCustody = ReadCustody()
    private var read: () throws -> [InstallationSlot: InstallationSlotImage]
    private var detach: ((InstallationPrecommitSession.NormalStarted) throws -> (() throws -> [InstallationSlot: InstallationSlotImage]))?
    private var detachStopped: ((InstallationPrecommitSession.Stopped, CustodyCatalogStore.InstallationStagedJournal.StopDelivery) throws -> (() throws -> [InstallationSlot: InstallationSlotImage]))?
    private let expected: [InstallationSlot: InstallationSlotImage]
    private init(read: @escaping () throws -> [InstallationSlot: InstallationSlotImage]) throws {
        self.read = read; expected = try read()
    }
    static func local(_ proof: HostControlServer.StartedObservation,
                      endpoint: InstallationPrecommitHostEndpoint) throws -> InstallationNormalHostFiles {
        try proof.revalidate()
        return try Self { try endpoint.normalHostFiles(proof.registration) }
    }
    static func peer(_ proof: InstallationPrecommitSession.NormalStarted,
                     endpoint: InstallationReadinessEndpoint) throws -> InstallationNormalHostFiles {
        try proof.revalidatePeer()
        guard let release = proof.control.transaction?.candidate?.release else { throw CustodyRecordError.fenced }
        let registration = HostRegistration(identity: proof.host, release: release)
        let observation = try Self {
            try proof.revalidatePeer()
            return try endpoint.normalHostFiles(registration, deadline: proof.deadline)
        }
        let readCustody = observation.readCustody
        observation.detach = { candidate in
            guard candidate === proof else { throw CustodyRecordError.fenced }
            try proof.revalidatePeer()
            let parent = endpoint.parentForNormalHostObservation
            let host = proof.host, deadline = proof.deadline
            return {
                guard try ProcessIdentity.capture(processID: host.processID, generation: host.generation,
                    expectedExecutablePath: host.executablePath) == host else { throw CustodyRecordError.fenced }
                return try readCustody.read(parent: parent, registration: registration, deadline: deadline)
            }
        }
        observation.detachStopped = { acknowledgment, delivery in
            guard acknowledgment.host == proof.host,
                  acknowledgment.control == (try InstallationStartupTranscript.recovery(after: proof.control)),
                  acknowledgment.deadline.absoluteUptimeNanoseconds == proof.deadline.absoluteUptimeNanoseconds else {
                throw CustodyRecordError.fenced
            }
            try delivery.validateCompleted(acknowledgment)
            let parent = endpoint.parentForNormalHostObservation
            return {
                try delivery.validateCompleted(acknowledgment)
                return try readCustody.read(parent: parent, registration: registration, deadline: acknowledgment.deadline)
            }
        }
        return observation
    }
    func detachForStoppedRecovery(_ acknowledgment: InstallationPrecommitSession.Stopped,
        delivery: CustodyCatalogStore.InstallationStagedJournal.StopDelivery) throws {
        guard let detachStopped else { throw CustodyRecordError.fenced }
        let retainedRead = try detachStopped(acknowledgment, delivery)
        guard try retainedRead() == expected else { throw CustodyRecordError.conflict }
        read = retainedRead; self.detachStopped = nil; detach = nil
    }
    func detachForReadinessRetirement(_ proof: InstallationPrecommitSession.NormalStarted) throws {
        guard let detach else { throw CustodyRecordError.fenced }
        try revalidate()
        let retainedRead = try detach(proof)
        guard try retainedRead() == expected else { throw CustodyRecordError.conflict }
        read = retainedRead; self.detach = nil
    }
    /// Enroll before acquisition. A failed read retains its exact turn in the
    /// original slot observation and cannot be retried as a fresh read budget.
    private final class ReadCustody {
        private let lock = NSLock()
        private var pending: ReadTurn?
        #if SHADOW_SYNC_TESTING
        var testingEnrolled: ((OwnedFileDescriptor) throws -> Void)?
        var testingRead: (() throws -> Void)?
        var testingPending: ReadTurn? { pending }
        #endif
        func read(parent: InstallationCaptureParent, registration: HostRegistration,
                  deadline: MonotonicDeadline) throws -> [InstallationSlot: InstallationSlotImage] {
            guard lock.try() else { throw CustodyRecordError.busy }
            guard pending == nil else { lock.unlock(); throw CustodyRecordError.fenced }
            let turn = ReadTurn(parent: parent); pending = turn
            #if SHADOW_SYNC_TESTING
            turn.testingEnrolled = testingEnrolled; turn.testingRead = testingRead
            #endif
            lock.unlock()
            let result = try turn.read(registration, deadline: deadline)
            lock.lock(); pending = nil; lock.unlock()
            return result
        }
    }
    /// A read turn acquires its own ancestor observations. It never borrows the
    /// retiring endpoint's descriptions or mints namespace mutation authority.
    /// Failed checked-close remains retained; every successful read closes all
    /// turn-acquired descriptions and leaves the original shared parent intact.
    private final class ReadTurn {
        private let parent: InstallationCaptureParent
        private var ancestors: [OwnedFileDescriptor] = []
        private var children: [OwnedFileDescriptor] = []
        private var readFailure: Error?
        private var retainedSelf: ReadTurn?
        #if SHADOW_SYNC_TESTING
        var testingEnrolled: ((OwnedFileDescriptor) throws -> Void)?
        var testingRead: (() throws -> Void)?
        var testingChildren: [OwnedFileDescriptor] { children }
        var testingRetained: Bool { retainedSelf === self }
        var testingFailed: Bool { readFailure != nil }
        func testingFixtureDrain(_ fault: InstallationCoordinationCleanupFixtures.CloseFault?) throws {
            for descriptor in children {
                if descriptor.retirementObservation != .succeeded {
                    guard let fault, fault.descriptor === descriptor else { throw CustodyRecordError.fenced }
                    try fault.verify()
                }
            }
            guard ancestors.filter({ $0 !== parent.pinned.ownedDescriptor }).allSatisfy({ $0.retirementObservation == .succeeded }) else {
                throw CustodyRecordError.fenced
            }
            // Fixture-only disposal of a read-only harness after independent
            // native-close evidence. No journal or endpoint can call this or
            // reinterpret the permanently uncertain descriptor result.
            testingEnrolled = nil; testingRead = nil
            retainedSelf = nil
        }
        #endif
        init(parent: InstallationCaptureParent) { self.parent = parent }
        private func retire() -> Bool {
            var success = true
            for child in children {
                if child.retireChecked() != .succeeded { success = false }
            }
            for descriptor in ancestors where descriptor !== parent.pinned.ownedDescriptor {
                if descriptor.retireChecked() != .succeeded { success = false }
            }
            if success { retainedSelf = nil }
            return success
        }
        func read(_ registration: HostRegistration, deadline: MonotonicDeadline) throws -> [InstallationSlot: InstallationSlotImage] {
            retainedSelf = self
            do {
                let address = try InstallationNamedSocketObservation.Address(canonicalParent: parent.pinned.path, endpoint: .host)
                try parent.retainSocketAncestors(address, into: &ancestors, deadline: deadline)
                let result = try InstallationNormalHostFiles.read(parent: parent, ancestors: ancestors,
                    registration: registration, deadline: deadline, enroll: { descriptor in
                        self.children.append(descriptor)
                        #if SHADOW_SYNC_TESTING
                        try self.testingEnrolled?(descriptor)
                        #endif
                    }, afterRead: {
                        #if SHADOW_SYNC_TESTING
                        try self.testingRead?()
                        #endif
                    })
                guard retire() else { throw CustodyRecordError.fenced }
                return result
            } catch {
                readFailure = error
                _ = retire()
                throw error
            }
        }
    }

    #if SHADOW_SYNC_TESTING
    private enum ReadCut: CaseIterable { case afterOpen, invalidContent, uncertainClose }
    private final class TestingReadDriver: InstallationNamedSocketFixtureCustodyOwner {
        let custody = ReadCustody()
        var parent: InstallationCaptureParent?
        var opened: OwnedFileDescriptor?
        var openedIdentity: FileIdentity?
        var reachedRead = false
        let fault = InstallationCoordinationCleanupFixtures.CloseFault()
        var closeAttempts = 0
        func run(path: String, registration: HostRegistration, cut: ReadCut, deadline: MonotonicDeadline) throws {
            parent = try InstallationCaptureParent(path)
            custody.testingEnrolled = { [self] descriptor in
                opened = descriptor
                var info = stat()
                guard fstat(descriptor.value, &info) == 0 else { throw CustodyRecordError.persistence(errno) }
                openedIdentity = FileIdentity(info)
                if cut == .uncertainClose { fault.enroll(descriptor) }
                else {
                    descriptor.testingClose = { [self] raw in
                        closeAttempts += 1
                        return Darwin.close(raw) == 0 ? 0 : errno
                    }
                }
                if cut == .afterOpen { throw CustodyRecordError.injectedFailure }
            }
            custody.testingRead = { [self] in
                reachedRead = true
                if cut == .uncertainClose { throw CustodyRecordError.injectedFailure }
            }
            _ = try custody.read(parent: parent!, registration: registration, deadline: deadline)
        }
        func verify(cut: ReadCut, identity: FileIdentity) throws {
            guard let opened, let turn = custody.testingPending else { throw CustodyRecordError.fenced }
            try InstallationStorageFixtures.check(turn.testingFailed && turn.testingChildren.count == 1
                && turn.testingChildren.first === opened && openedIdentity?.matchesStableNode(identity) == true
                && (cut == .afterOpen ? !reachedRead : reachedRead),
                "detached read failed to retain the exact child before fallible observation")
            if cut == .uncertainClose {
                try fault.verify()
                try InstallationStorageFixtures.check(turn.testingRetained, "uncertain child lost read-turn self custody")
            } else {
                try InstallationStorageFixtures.check(closeAttempts == 1 && opened.retirementObservation == .succeeded,
                    "failed read did not checked-close its actual host-owner descriptor exactly once")
            }
            // A failed turn cannot be replaced with a fresh read/budget.
            guard let parent else { throw CustodyRecordError.fenced }
            let registration = HostRegistration(identity: try ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make()))
            try InstallationStorageFixtures.refuses {
                _ = try custody.read(parent: parent, registration: registration, deadline: .init(seconds: 3))
            }
            if cut == .uncertainClose { try fault.verify() }
            else { try InstallationStorageFixtures.check(closeAttempts == 1, "read retry closed a reused numeric descriptor") }
        }
        func retireNamedSocketFixture(deadline: MonotonicDeadline) throws {
            guard !deadline.hasExpired else { throw CustodyRecordError.busy }
            if let turn = custody.testingPending {
                try turn.testingFixtureDrain(fault.descriptor == nil ? nil : fault)
            }
            if let opened { opened.testingClose = nil }
            custody.testingEnrolled = nil; custody.testingRead = nil
            if let parent, parent.pinned.ownedDescriptor.retireChecked() != .succeeded { throw CustodyRecordError.fenced }
        }
    }
    @inline(never)
    static func testingDetachedReadCustody() throws {
        for cut in ReadCut.allCases {
            try InstallationStorageFixtures.fixture { root, location in
                let registration = HostRegistration(identity: try ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make()))
                let bytes: Data
                if cut == .invalidContent { bytes = Data("{}".utf8) }
                else { bytes = try JSONEncoder().encode(registration) }
                let path = location.path + "/host-owner.json"
                try bytes.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
                try InstallationStorageFixtures.check(chmod(path, 0o600) == 0, "read fixture private mode")
                var node = stat(); try InstallationStorageFixtures.check(lstat(path, &node) == 0, "read fixture node identity")
                let driver = TestingReadDriver()
                try RuntimeFixtureSession.installationRoot(root).retainNamedSocket(driver)
                var refused = false
                do { try driver.run(path: location.path, registration: registration, cut: cut, deadline: .init(seconds: 3)) }
                catch is CustodyRecordError { refused = true }
                catch is DecodingError { refused = true }
                try InstallationStorageFixtures.check(refused, "failed detached observation returned a successful image")
                try driver.verify(cut: cut, identity: FileIdentity(node))
                var unchanged = stat()
                try InstallationStorageFixtures.check(lstat(path, &unchanged) == 0
                    && FileIdentity(unchanged).matchesStableNode(FileIdentity(node)),
                    "read failure acquired named-node release authority")
            }
        }
    }
    #endif

    func revalidate() throws {
        guard try read() == expected else { throw CustodyRecordError.conflict }
    }
    fileprivate func image(_ slot: InstallationSlot, parent: InstallationCaptureParent) throws -> InstallationSlotImage {
        try revalidate()
        guard let value = expected[slot], value.parentDevice == parent.identity.device,
              value.parentInode == parent.identity.inode else { throw CustodyRecordError.conflict }
        return value
    }
    fileprivate static func read(parent: InstallationCaptureParent, ancestors: [OwnedFileDescriptor],
                                 registration: HostRegistration, deadline: MonotonicDeadline,
                                 enroll: ((OwnedFileDescriptor) throws -> Void)? = nil,
                                 afterRead: (() throws -> Void)? = nil) throws -> [InstallationSlot: InstallationSlotImage] {
        guard !deadline.hasExpired, registration.isValid else { throw CustodyRecordError.fenced }
        try parent.validate()
        guard let (fd, node) = try parent.open("host-owner.json", directory: false, privateMode: true, enroll: enroll) else {
            throw CustodyRecordError.fenced
        }
        let bytes = try InstallationCaptureParent.bytes(fd.value, maximum: 16_384)
        try afterRead?()
        guard try JSONDecoder().decode(HostRegistration.self, from: bytes) == registration else { throw CustodyRecordError.fenced }
        let address = try InstallationNamedSocketObservation.Address(canonicalParent: parent.pinned.path, endpoint: .host)
        let socket = try InstallationNamedSocketObservation.read(address: address, retainedAncestors: ancestors,
            uid: node.uid, deadline: deadline)
        try parent.recheck("host-owner.json", owned: fd, node: node, privateMode: true)
        try parent.validate()
        // Detached turns own this child through success AND throw. Legacy
        // attached observations keep their existing checked-close contract.
        if enroll == nil {
            guard fd.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }
        }
        return [
            .hostOwner: InstallationSlotImage(parentDevice: parent.identity.device, parentInode: parent.identity.inode,
                node: node, size: UInt64(bytes.count), contentDigest: CustodyRecordBinding.digest(bytes), documentReceipts: nil),
            .hostSocket: InstallationSlotImage(parentDevice: parent.identity.device, parentInode: parent.identity.inode,
                node: socket.nodeIdentity, size: nil, contentDigest: nil, documentReceipts: nil),
        ]
    }
}
extension InstallationReadinessEndpoint {
    fileprivate var parentForNormalHostObservation: InstallationCaptureParent { parent }
    fileprivate func normalHostFiles(_ registration: HostRegistration, deadline budget: MonotonicDeadline) throws -> [InstallationSlot: InstallationSlotImage] {
        guard budget.absoluteUptimeNanoseconds <= deadline.absoluteUptimeNanoseconds else { throw CustodyRecordError.fenced }
        try validateParents(observationDeadline: budget)
        return try InstallationNormalHostFiles.read(parent: parent, ancestors: ancestors, registration: registration, deadline: budget)
    }
}
extension InstallationPrecommitHostEndpoint {
    func normalSocketObservation() throws -> InstallationNamedSocketObservation {
        try validateOwnerAndParent()
        let address = try InstallationNamedSocketObservation.Address(canonicalParent: parent.pinned.path, endpoint: .host)
        return try InstallationNamedSocketObservation.read(address: address, retainedAncestors: ancestors,
            uid: control.state.directory.uid, deadline: deadline)
    }
    fileprivate func normalHostFiles(_ registration: HostRegistration) throws -> [InstallationSlot: InstallationSlotImage] {
        try validateOwnerAndParent()
        return try InstallationNormalHostFiles.read(parent: parent, ancestors: ancestors, registration: registration, deadline: deadline)
    }
}

/// Pins the fixed staged layout for the current host. This performs only the
/// existing installation-slot reads, never ordinary admission or activation.
final class InstallationCommittedHostSlots {
    private let observer: InstallationLifecycle
    private let control: InstallationControlRecord
    private let parents: [InstallationCaptureParent]
    private let endpoint: InstallationPrecommitHostEndpoint
    private var normalHostFiles: InstallationNormalHostFiles?
    init(paths: InstallationPaths, control: InstallationControlRecord,
         endpoint: InstallationPrecommitHostEndpoint,
         validationProfile: InstallationValidationProfile = .production) throws {
        guard control.phase == .committed, control.step?.action == .readinessCommit,
              control.step?.status == .complete else { throw CustodyRecordError.fenced }
        observer = InstallationLifecycle(paths: paths, launchAgent: SystemLaunchAgentController(), host: SystemInstalledHostController())
        observer.validationProfile = validationProfile
        self.control = control; self.endpoint = endpoint
        parents = try [URL(fileURLWithPath: paths.app).deletingLastPathComponent().path,
            URL(fileURLWithPath: paths.launchAgent).deletingLastPathComponent().path,
            URL(fileURLWithPath: paths.state.path).deletingLastPathComponent().path,
            paths.state.path].map(InstallationCaptureParent.init)
        try revalidate()
    }
    func observeNormalServer(_ proof: HostControlServer.StartedObservation) throws {
        guard normalHostFiles == nil, control.transaction?.slots.images[.hostOwner]?.node == nil,
              control.transaction?.slots.images[.hostSocket]?.node == nil else { throw CustodyRecordError.fenced }
        normalHostFiles = try InstallationNormalHostFiles.local(proof, endpoint: endpoint)
        try revalidate()
    }
    func revalidate() throws {
        guard let transaction = control.transaction, let candidate = transaction.candidate else { throw CustodyRecordError.fenced }
        let observed = try observer.observeInstallationSlots(stateBinding: control.state, candidate: candidate,
            transactionID: transaction.id, parents: parents, hostEndpoint: endpoint, normalHost: normalHostFiles)
        guard observed.0 == transaction.slots else { throw CustodyRecordError.conflict }
    }
}

/// Host-side pin of the same fixed endpoint. The control image is evidence only;
/// live exact-code peer authentication remains mandatory on the retained stream.
final class InstallationPrecommitHostEndpoint {
    private let admission: LifecycleAdmissionAuthority
    private let launcher: LauncherAuthority
    private let control: InstallationControlRecord
    private let parent: InstallationCaptureParent
    private let expected: InstallationSlotImage
    private let address: InstallationNamedSocketObservation.Address
    private let deadline: MonotonicDeadline
    private var ancestors: [OwnedFileDescriptor] = []
    private var parentObservation: [InstallationNamedSocketObservation.Parent]?
    private var observed: InstallationNamedSocketObservation?
    private var attempted = false
    let connection: OwnedFileDescriptor
    init(admission: LifecycleAdmissionAuthority, launcher: LauncherAuthority, control: InstallationControlRecord,
         deadline: MonotonicDeadline) throws {
        guard let expected = control.transaction?.slots.images[.installationSocket], expected.node != nil,
              !deadline.hasExpired else { throw CustodyRecordError.fenced }
        self.admission = admission; self.launcher = launcher; self.control = control
        self.deadline = deadline; self.expected = expected
        parent = try InstallationCaptureParent(readinessAdmission: admission)
        address = try InstallationNamedSocketObservation.Address(canonicalParent: admission.stateDirectory.path, endpoint: .installation)
        let raw = socket(AF_UNIX, SOCK_STREAM, 0)
        guard raw >= 0 else { throw CustodyRecordError.persistence(errno) }
        connection = OwnedFileDescriptor(raw)
        // No later throwing initializer work: the host enrolls this actual
        // partial observer before configuration, chain capture or connect.
    }
    private func validateOwnerAndParent() throws {
        guard !deadline.hasExpired, admission.commandAdmissionIsOpen else { throw CustodyRecordError.fenced }
        try launcher.validateRetainedInstallation(control.state)
        try parent.validate()
        guard parent.identity.device == control.state.directory.device,
              parent.identity.inode == control.state.directory.inode,
              parent.identity.mode == control.state.directory.mode,
              parent.identity.aclDigest == control.state.directory.aclDigest,
              expected.parentDevice == parent.identity.device, expected.parentInode == parent.identity.inode,
              let parentObservation,
              try InstallationNamedSocketObservation.parents(address: address, retainedAncestors: ancestors,
                uid: control.state.directory.uid, deadline: deadline) == parentObservation else {
            throw CustodyRecordError.conflict
        }
    }
    func connect() throws {
        guard !attempted else { throw CustodyRecordError.fenced }
        attempted = true
        guard !deadline.hasExpired, admission.commandAdmissionIsOpen else { throw CustodyRecordError.fenced }
        try launcher.validateRetainedInstallation(control.state)
        try parent.retainSocketAncestors(address, into: &ancestors, deadline: deadline)
        parentObservation = try InstallationNamedSocketObservation.parents(address: address,
            retainedAncestors: ancestors, uid: control.state.directory.uid, deadline: deadline)
        try validateOwnerAndParent()
        let initial = try InstallationNamedSocketObservation.read(address: address, retainedAncestors: ancestors,
            uid: control.state.directory.uid, deadline: deadline)
        guard initial.nodeIdentity == expected.node else { throw CustodyRecordError.conflict }
        observed = initial
        let raw = connection.value
        try InstallationPrecommitTransport.configure(raw)
        try revalidate()
        var native = address.socketAddress()
        let result = withUnsafePointer(to: &native) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(raw, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw CustodyRecordError.persistence(errno) }
            try HostControlIO.wait(raw, events: Int16(POLLOUT), deadline: deadline)
            var code: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(raw, SOL_SOCKET, SO_ERROR, &code, &size) == 0,
                  size == socklen_t(MemoryLayout<Int32>.size), code == 0 else { throw CustodyRecordError.conflict }
        }
        try revalidate()
        // Existing host.run authenticates the original stream's exact native
        // peer before it reads/sends the readiness transcript. No new authority.
    }
    // Failure cleanup consumes only actual acquired resources, never a name.
    // Each descriptor latches its original close outcome; repeated calls cannot
    // retry a numeric descriptor or erase uncertainty.
    func retireFailedHostResources() -> OwnedFileDescriptor.Retirement {
        let stream = connection.retireChecked()
        guard stream == .succeeded else { return stream }
        return retireObservationResources()
    }
    func retireObservationResources() -> OwnedFileDescriptor.Retirement {
        var result = OwnedFileDescriptor.Retirement.succeeded
        var visited = Set<ObjectIdentifier>()
        for descriptor in ancestors where descriptor !== parent.pinned.ownedDescriptor {
            guard visited.insert(ObjectIdentifier(descriptor)).inserted else { continue }
            let retired = descriptor.retireChecked()
            if result == .succeeded, retired != .succeeded { result = retired }
        }
        return result
    }
    fileprivate var image: InstallationSlotImage { expected }
    fileprivate func parentMatches(_ other: InstallationNodeIdentity) -> Bool {
        parent.identity.device == other.device && parent.identity.inode == other.inode
            && parent.identity.uid == other.uid && parent.identity.mode == other.mode
            && parent.identity.aclDigest == other.aclDigest && other.links > 0
    }
    func revalidate() throws {
        try validateOwnerAndParent()
        guard let observed, observed.nodeIdentity == expected.node else { throw CustodyRecordError.fenced }
        let current = try InstallationNamedSocketObservation.read(address: address, retainedAncestors: ancestors,
            uid: control.state.directory.uid, deadline: deadline)
        guard observed.matchesNamedGeneration(current), current.nodeIdentity == expected.node else {
            throw CustodyRecordError.conflict
        }
        try validateOwnerAndParent()
    }
}



#if SHADOW_SYNC_TESTING
enum InstallationFreshRestorationResourceFault: CaseIterable {
    case pathOpen, pathEnrollment, rosterDuplicate, rosterEnrollment, headroomDuplicate, headroomEnrollment
    case partialPathOpen, partialPathEnrollment, partialRosterDuplicate, partialRosterEnrollment
    var isPartial: Bool {
        [.partialPathOpen, .partialPathEnrollment, .partialRosterDuplicate, .partialRosterEnrollment].contains(self)
    }
}
struct InstallationFreshRestorationResourceObservation {
    let fault: InstallationFreshRestorationResourceFault?
    let acquired: Int
    let closed: Int
    let retained: Int
    let unlinks: Int
}
enum InstallationFreshRestorationCut: Equatable {
    case beforeUnlink(Int), afterUnlink(Int), syncFailure(Int), afterSync(Int), closeUnknown(Int), afterClose(Int)
    case plistAfterUnlink, plistSyncFailure, plistAfterSync, plistCloseUnknown
}
#endif

/// Same-object retirement of the exact promoted candidate. Construction never
/// grants mutation: the journal's restore-application intent is checked at each
/// unlink. No path remover, quarantine, historical adoption or deadline renewal.
fileprivate final class InstallationCandidateRetirement {
    // Existing retention ceilings, plus finite manifest storage/descriptor caps.
    // Resource exhaustion refuses before mutation; no dynamic limit relaxation.
    static let maximumEntries = 10_000
    static let maximumDepth = 512
    static let maximumContentBytes: UInt64 = 1_073_741_824
    static let maximumPathBytes = 4_194_304
    static let maximumMetadataBytes = 4_194_304
    static let maximumDescriptors = 2 * maximumDepth + 2 // original root, two bounded paths, roster
    private enum Stage { case untouched, unlinked, fsynced, retired }
    private final class Node {
        let path: String, name: String, kind: mode_t
        weak var parent: Node?
        let record: [String]
        var identity: stat?
        var acl: String?
        var attributes: [String: Data]?
        var stage: Stage = .untouched
        var children: [Node] = []
        init(path: String, name: String, kind: mode_t, parent: Node?, record: [String]) {
            self.path = path; self.name = name; self.kind = kind; self.parent = parent
            self.record = record
        }
    }
    private let parent: InstallationCaptureParent
    private let rootDescriptor: OwnedFileDescriptor
    private let name: String
    private let original: InstallationSlotImage
    private let permit: CustodyCatalogStore.InstallationStagedJournal.ReadinessRestorationPermit
    private let owner: InstallationTransactionOwner
    private var nodes: [Node] = []
    private var order: [Node] = []
    private var sealed = false
    private var postimageDelivered = false
    private var poisoned = false
    private var retainedSelf: InstallationCandidateRetirement?
    private struct Handle { let node: Node; let descriptor: OwnedFileDescriptor }
    // Root custody is continuous. Descendant handles are freshly checked against
    // the original manifest and never represented as continuous old descriptions.
    private var inspection: [Handle] = []
    private var mutation: [Handle] = []
    private var mutationNode: Node?
    private var mutationRoot = false
    private var resourceProbe: OwnedFileDescriptor?
    private var enumerationRaw: Int32?
    private var enumerationStream: UnsafeMutablePointer<DIR>?
    private var enumerationCloseUnknown = false
    #if SHADOW_SYNC_TESTING
    var testingCut: InstallationFreshRestorationCut?
    private(set) var testingReachedCut: InstallationFreshRestorationCut?
    var testingMutationBarrier: ((Int, String) throws -> Void)?
    var testingResourceFault: InstallationFreshRestorationResourceFault?
    private var testingReachedResourceFault: InstallationFreshRestorationResourceFault?
    private var testingAcquired = 0
    private var testingClosed = 0
    private(set) var testingUnlinks = 0
    var testingResourceObservation: InstallationFreshRestorationResourceObservation {
        .init(fault: testingReachedResourceFault, acquired: testingAcquired, closed: testingClosed,
              retained: inspection.count + mutation.count + (resourceProbe == nil ? 0 : 1)
                + (enumerationRaw == nil && enumerationStream == nil ? 0 : 1), unlinks: testingUnlinks)
    }
    private func resourceFault(_ point: InstallationFreshRestorationResourceFault) -> Bool {
        guard let fault = testingResourceFault else { return false }
        let partialMatches = testingUnlinks == 1 && (
            (fault == .partialPathOpen && point == .pathOpen)
            || (fault == .partialPathEnrollment && point == .pathEnrollment)
            || (fault == .partialRosterDuplicate && point == .rosterDuplicate)
            || (fault == .partialRosterEnrollment && point == .rosterEnrollment))
        guard fault == point || partialMatches else { return false }
        testingResourceFault = nil; testingReachedResourceFault = fault; return true
    }
    private func fail(_ cut: InstallationFreshRestorationCut) throws {
        if testingCut == cut { testingReachedCut = cut; testingCut = nil; throw CustodyRecordError.persistence(EIO) }
    }
    #endif
    init(parent: InstallationCaptureParent, root: OwnedFileDescriptor, name: String,
         original: InstallationSlotImage, permit: CustodyCatalogStore.InstallationStagedJournal.ReadinessRestorationPermit,
         owner: InstallationTransactionOwner) {
        self.parent = parent; rootDescriptor = root; self.name = name
        self.original = original; self.permit = permit; self.owner = owner
        retainedSelf = self
    }
    private func boundary() throws {
        guard !poisoned, !enumerationCloseUnknown, !permit.deadline.hasExpired else { throw CustodyRecordError.fenced }
        try parent.validate()
    }
    private func chain(_ node: Node) -> [Node] {
        var result: [Node] = [], current: Node? = node
        while let next = current { result.append(next); current = next.parent }
        return result.reversed()
    }
    private func closeInspection() throws {
        while let last = inspection.last {
            guard last.descriptor.retireChecked() == .succeeded else { poisoned = true; throw CustodyRecordError.fenced }
            #if SHADOW_SYNC_TESTING
            testingClosed += 1
            #endif
            inspection.removeLast()
        }
    }
    private func openPath(_ node: Node) throws -> (Int32, Int32) {
        try boundary(); guard inspection.isEmpty else { throw CustodyRecordError.fenced }
        var fd = rootDescriptor.value, parentFD = parent.fd
        for part in chain(node) {
            if part.parent != nil {
                parentFD = fd
                guard inspection.count + mutation.count + 2 < Self.maximumDescriptors else { throw CustodyRecordError.fenced }
                #if SHADOW_SYNC_TESTING
                if resourceFault(.pathOpen) { throw CustodyRecordError.persistence(EMFILE) }
                #endif
                let raw = openat(fd, part.name, O_RDONLY | O_CLOEXEC | O_NONBLOCK
                    | (part.kind == S_IFLNK ? O_SYMLINK : O_NOFOLLOW) | (part.kind == S_IFDIR ? O_DIRECTORY : 0))
                guard raw >= 0 else { throw CustodyRecordError.persistence(errno) }
                let descriptor = OwnedFileDescriptor(raw)
                inspection.append(Handle(node: part, descriptor: descriptor)) // enrollment before checks
                #if SHADOW_SYNC_TESTING
                testingAcquired += 1
                if resourceFault(.pathEnrollment) { throw CustodyRecordError.persistence(EIO) }
                #endif
                fd = raw
            }
            if part.identity != nil { try validatePresent(part, fd: fd, parentFD: parentFD, checkContent: false) }
        }
        return (fd,parentFD)
    }
    private func inspect<T>(_ node: Node, _ body: (Int32, Int32) throws -> T) throws -> T {
        do {
            let handles = try openPath(node)
            let result = try body(handles.0, handles.1)
            try closeInspection(); return result
        } catch {
            if !poisoned { try closeInspection() }
            throw error
        }
    }
    private func mutationFD(_ node: Node) throws -> (Int32, Int32) {
        guard mutationNode === node else { throw CustodyRecordError.fenced }
        if mutationRoot { return (rootDescriptor.value,parent.fd) }
        guard let last = mutation.last, last.node === node else { throw CustodyRecordError.fenced }
        let parentFD = mutation.count > 1 ? mutation[mutation.count - 2].descriptor.value : rootDescriptor.value
        return (last.descriptor.value,parentFD)
    }
    private func sameStable(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_gid == b.st_gid
            && a.st_mode == b.st_mode && a.st_flags == b.st_flags && a.st_gen == b.st_gen
            && a.st_birthtimespec.tv_sec == b.st_birthtimespec.tv_sec
            && a.st_birthtimespec.tv_nsec == b.st_birthtimespec.tv_nsec
    }
    private func same(_ a: stat, _ b: stat) -> Bool {
        sameStable(a,b) && a.st_nlink == b.st_nlink && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private func attributes(_ fd: Int32) throws -> [String: Data] {
        try boundary()
        let size = flistxattr(fd, nil, 0, 0)
        guard size >= 0, size <= 4096 else { throw CustodyRecordError.unsafeMetadata }
        var bytes = [CChar](repeating: 0, count: max(1, size))
        guard flistxattr(fd, &bytes, size, 0) == size else { throw CustodyRecordError.conflict }
        let names = bytes.prefix(size).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        guard Set(names).count == names.count, Set(names).isSubset(of: ["com.apple.provenance", "com.apple.quarantine"]) else {
            throw CustodyRecordError.unsafeMetadata
        }
        var result: [String: Data] = [:]
        for name in names {
            try boundary()
            let count = fgetxattr(fd, name, nil, 0, 0, 0)
            guard count >= 0, count <= 65_536 else { throw CustodyRecordError.unsafeMetadata }
            var value = Data(count: count)
            let read = value.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, count, 0, 0) }
            guard read == count else { throw CustodyRecordError.conflict }
            result[name] = value
        }
        return result
    }
    // O_SYMLINK opens the leaf itself on Darwin. Descriptor ACL and xattr APIs
    // must support that handle or this route refuses; never follow its target.
    private func content(_ node: Node, fd: Int32, parentFD: Int32) throws -> (UInt64, String) {
        try boundary()
        if node.kind == S_IFDIR { return (0, "-") }
        if node.kind == S_IFLNK {
            var bytes = [UInt8](repeating: 0, count: 4097)
            let count = readlinkat(parentFD, node.name, &bytes, bytes.count)
            guard count > 0, count <= 4096 else { throw CustodyRecordError.unsafeMetadata }
            let target = Data(bytes.prefix(count))
            guard let text = String(data: target, encoding: .utf8), !text.hasPrefix("/"), !text.contains("\0") else {
                throw CustodyRecordError.unsafeMetadata
            }
            return (UInt64(count), CustodyRecordBinding.digest(target))
        }
        guard let expectedSize = UInt64(node.record[3]), expectedSize <= Self.maximumContentBytes else {
            throw CustodyRecordError.unsafeMetadata
        }
        var digest = SHA256(), offset: UInt64 = 0
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while offset < expectedSize {
            try boundary()
            let count = pread(fd, &bytes, min(bytes.count, Int(expectedSize - offset)), off_t(offset))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw CustodyRecordError.persistence(errno) }
            digest.update(data: Data(bytes.prefix(count))); offset += UInt64(count)
        }
        var extra: UInt8 = 0
        guard pread(fd, &extra, 1, off_t(offset)) == 0 else { throw CustodyRecordError.conflict }
        return (offset, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private func roster(_ node: Node, fd: Int32) throws -> Set<String> {
        try boundary()
        guard node.kind == S_IFDIR, enumerationRaw == nil, enumerationStream == nil else { throw CustodyRecordError.fenced }
        #if SHADOW_SYNC_TESTING
        if resourceFault(.rosterDuplicate) { throw CustodyRecordError.persistence(EMFILE) }
        #endif
        let raw = fcntl(fd, F_DUPFD_CLOEXEC, 3)
        guard raw >= 0 else { throw CustodyRecordError.persistence(errno) }
        enumerationRaw = raw // enroll before fdopendir can fail
        #if SHADOW_SYNC_TESTING
        testingAcquired += 1
        if resourceFault(.rosterEnrollment) {
            // Model fdopendir failure AFTER actual duplicate enrollment. This
            // closes only this owned duplicate; no process rlimit is touched.
            enumerationRaw = nil
            guard Darwin.close(raw) == 0 else { enumerationCloseUnknown = true; throw CustodyRecordError.fenced }
            testingClosed += 1
            throw CustodyRecordError.persistence(ENOMEM)
        }
        #endif
        guard let stream = fdopendir(raw) else {
            enumerationRaw = nil
            let result = Darwin.close(raw)
            if result != 0 { enumerationCloseUnknown = true }
            #if SHADOW_SYNC_TESTING
            if result == 0 { testingClosed += 1 }
            #endif
            throw CustodyRecordError.fenced
        }
        enumerationRaw = nil; enumerationStream = stream
        var result: Set<String> = []
        do {
            rewinddir(stream)
            while true {
                try boundary(); errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw CustodyRecordError.persistence(errno) }; break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                guard !name.isEmpty, !name.contains("/"), name.utf8.count <= Int(NAME_MAX),
                      result.count < Self.maximumEntries, result.insert(name).inserted else { throw CustodyRecordError.conflict }
            }
        } catch {
            enumerationStream = nil
            let closed = closedir(stream) == 0
            if !closed { enumerationCloseUnknown = true }
            #if SHADOW_SYNC_TESTING
            if closed { testingClosed += 1 }
            #endif
            throw error
        }
        enumerationStream = nil // record one close attempt before syscall
        guard closedir(stream) == 0 else { enumerationCloseUnknown = true; throw CustodyRecordError.fenced }
        #if SHADOW_SYNC_TESTING
        testingClosed += 1
        #endif
        return result
    }
    private static func validatedManifest(_ inventory: [String]) throws -> [String: [String]] {
        guard !inventory.isEmpty, inventory.count <= maximumEntries else { throw CustodyRecordError.fenced }
        var records: [String: [String]] = [:], contentBytes: UInt64 = 0, pathBytes = 0
        for record in inventory {
            let parts = record.components(separatedBy: "\0")
            guard parts.count == 5, ["d", "f", "l"].contains(parts[0]), let size = UInt64(parts[3]),
                  size <= Self.maximumContentBytes, contentBytes <= Self.maximumContentBytes - size else { throw CustodyRecordError.fenced }
            let path = parts[1], components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path == "." || (!path.hasPrefix("/") && components.count < Self.maximumDepth
                && components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= Int(NAME_MAX) })),
                  path.utf8.count <= 4096, pathBytes <= Self.maximumPathBytes - path.utf8.count,
                  records.updateValue(parts, forKey: path) == nil else { throw CustodyRecordError.fenced }
            pathBytes += path.utf8.count; contentBytes += size
        }
        guard records["."]?[0] == "d" else { throw CustodyRecordError.fenced }
        return records
    }
    #if SHADOW_SYNC_TESTING
    fileprivate static func testingManifestBounds() throws {
        func refuses(_ records: [String]) throws {
            do { _ = try validatedManifest(records) }
            catch { return }
            throw InstallationStorageFixtures.Failure(message: "fresh retirement manifest bounds accepted invalid input")
        }
        let root = "d\0.\0493\00\0-"
        let digest = String(repeating: "0",count: 64)
        try refuses([])
        try refuses([root,root])
        try refuses([root,"f\0../escape\0420\01\0" + digest])
        try refuses([root,"f\0leaf\0420\018446744073709551615\0" + digest])
        try refuses([root,"f\0a\0420\01073741824\0" + digest,"f\0b\0420\01\0" + digest])
        try refuses([root,"d\0" + Array(repeating:"a",count: maximumDepth).joined(separator:"/") + "\0493\00\0-"])
        try refuses([root] + (0..<maximumEntries).map { "f\0f\($0)\0420\00\0" + digest })
        let longName = String(repeating:"a",count: 250)
        try refuses([root] + (0..<5000).map { "f\0" + longName + "/" + longName + "/" + longName + "/" + longName + "/\($0)\0420\00\0" + digest })
    }
    #endif
    func prepare(_ artifact: BundleArtifactIdentity) throws {
        try boundary()
        guard nodes.isEmpty, !sealed, artifact.canonicalSHA256 == original.contentDigest,
              artifact.inventory.count > 0, artifact.inventory.count <= Self.maximumEntries else { throw CustodyRecordError.fenced }
        let records = try Self.validatedManifest(artifact.inventory)
        var byPath: [String: Node] = [:], metadataBytes = 0
        do {
            for path in records.keys.sorted(by: {
                let a = $0 == "." ? 0 : $0.split(separator: "/").count
                let b = $1 == "." ? 0 : $1.split(separator: "/").count
                return a == b ? $0 < $1 : a < b
            }) {
                try boundary()
                let record = records[path]!, components = path.split(separator: "/")
                let parentPath = components.count == 1 ? "." : components.dropLast().joined(separator: "/")
                let parentNode = path == "." ? nil : byPath[parentPath]
                guard path == "." || parentNode?.kind == S_IFDIR else { throw CustodyRecordError.fenced }
                let leaf = path == "." ? name : String(components.last!)
                let kind = record[0] == "d" ? S_IFDIR : record[0] == "f" ? S_IFREG : S_IFLNK
                let node = Node(path: path, name: leaf, kind: kind, parent: parentNode, record: record)
                nodes.append(node); byPath[path] = node; parentNode?.children.append(node)
                try inspect(node) { descriptor, parentFD in
                    var held = stat(), named = stat()
                    guard fstat(descriptor, &held) == 0,
                          fstatat(parentFD, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
                          same(held,named), held.st_mode & S_IFMT == kind, held.st_uid == geteuid(), held.st_flags == 0,
                          UInt64(held.st_dev) == parent.identity.device, held.st_nlink > 0,
                          kind == S_IFDIR || held.st_nlink == 1,
                          String(held.st_mode & 0o7777) == record[2] else { throw CustodyRecordError.conflict }
                    node.identity = held
                    let acl = try PolicyAuthorityFile.safeACL(descriptor), attrs = try attributes(descriptor)
                    guard acl.utf8.count <= 65_536 else { throw CustodyRecordError.unsafeMetadata }
                    let count = acl.utf8.count + attrs.reduce(0) { $0 + $1.key.utf8.count + $1.value.count }
                    guard count <= Self.maximumMetadataBytes, metadataBytes <= Self.maximumMetadataBytes - count else {
                        throw CustodyRecordError.unsafeMetadata
                    }
                    metadataBytes += count; node.acl = acl; node.attributes = attrs
                    try validatePresent(node, fd: descriptor, parentFD: parentFD)
                }
            }
            order = nodes.sorted { a,b in
                let ad = a.path == "." ? 0 : a.path.split(separator: "/").count
                let bd = b.path == "." ? 0 : b.path.split(separator: "/").count
                return ad == bd ? a.path < b.path : ad > bd
            }
            // Complete the longest possible two-frontier resource acquisition
            // before first unlink. No rlimit change; real descriptor exhaustion
            // refuses here. Close every probe description with checked outcomes.
            if let deepest = nodes.max(by: { chain($0).count < chain($1).count }) {
                _ = try openPath(deepest)
                mutation = inspection; inspection = []; mutationNode = deepest; mutationRoot = deepest.parent == nil
                do {
                    try inspect(deepest) { _,_ in
                        #if SHADOW_SYNC_TESTING
                        if resourceFault(.headroomDuplicate) { throw CustodyRecordError.persistence(EMFILE) }
                        #endif
                        let raw = fcntl(rootDescriptor.value,F_DUPFD_CLOEXEC,3)
                        guard raw >= 0 else { throw CustodyRecordError.persistence(errno) }
                        resourceProbe = OwnedFileDescriptor(raw)
                        #if SHADOW_SYNC_TESTING
                        testingAcquired += 1
                        if resourceFault(.headroomEnrollment) { throw CustodyRecordError.persistence(EIO) }
                        #endif
                        guard resourceProbe?.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }
                        #if SHADOW_SYNC_TESTING
                        testingClosed += 1
                        #endif
                        resourceProbe = nil
                    }
                    try closeMutationFrontier()
                } catch { poisoned = true; throw error }
            }
            for node in nodes where node.kind == S_IFDIR {
                try inspect(node) { fd,_ in try validateRoster(node, fd: fd) }
            }
            sealed = true
            try revalidate()
        } catch {
            // Partial enrollment cannot be retried or rebuilt from names. Keep
            // descriptors and unknown closes owned by this original object.
            poisoned = true
            throw error
        }
    }
    private func validateRoster(_ node: Node, fd: Int32) throws {
        guard try roster(node, fd: fd) == Set(node.children.filter { $0.stage == .untouched }.map(\.name)) else {
            throw CustodyRecordError.conflict
        }
    }
    private func validatePresent(_ node: Node, fd: Int32, parentFD: Int32, checkContent: Bool = true) throws {
        try boundary()
        guard let expected = node.identity, let acl = node.acl, let attrs = node.attributes else { throw CustodyRecordError.fenced }
        var held = stat(), named = stat()
        guard fstat(fd, &held) == 0, same(held,expected),
              fstatat(parentFD, node.name, &named, AT_SYMLINK_NOFOLLOW) == 0, same(named,held),
              try PolicyAuthorityFile.safeACL(fd) == acl, try attributes(fd) == attrs else { throw CustodyRecordError.conflict }
        if checkContent {
            let bytes = try content(node, fd: fd, parentFD: parentFD)
            guard String(bytes.0) == node.record[3], bytes.1 == node.record[4] else { throw CustodyRecordError.conflict }
        }
        guard fstat(fd, &held) == 0, same(held,expected),
              fstatat(parentFD, node.name, &named, AT_SYMLINK_NOFOLLOW) == 0, same(named,held) else { throw CustodyRecordError.conflict }
    }
    private func validateRemoved(_ node: Node) throws {
        guard node.stage != .untouched else { throw CustodyRecordError.fenced }
        func absent(_ fd: Int32) throws {
            var named = stat()
            guard fstatat(fd, node.name, &named, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else { throw CustodyRecordError.conflict }
        }
        if let ancestor = node.parent {
            if ancestor.stage == .untouched { try inspect(ancestor) { fd,_ in try absent(fd) } }
        } else { try absent(parent.fd) }
        if node.stage != .retired {
            let (fd,_) = try mutationFD(node)
            guard let expected = node.identity else { throw CustodyRecordError.fenced }
            var held = stat()
            guard fstat(fd,&held) == 0, sameStable(held,expected), held.st_nlink == 0,
                  try PolicyAuthorityFile.safeACL(fd) == node.acl,
                  try attributes(fd) == node.attributes else { throw CustodyRecordError.conflict }
        }
    }
    func revalidate() throws {
        try boundary(); guard sealed else { throw CustodyRecordError.fenced }
        for node in nodes {
            if node.stage == .untouched {
                try inspect(node) { fd,parentFD in
                    // Original content was hashed between exact metadata checks.
                    // Unchanged inode/size/mtime/ctime binds that content; the
                    // selected leaf is hashed again immediately before unlink.
                    try validatePresent(node, fd: fd, parentFD: parentFD, checkContent: false)
                    if node.kind == S_IFDIR { try validateRoster(node, fd: fd) }
                }
            } else { try validateRemoved(node) }
        }
    }
    private func acceptParentTransition(after child: Node, parentFD: Int32) throws {
        guard let node = child.parent else { try parent.validate(); return }
        guard let before = node.identity else { throw CustodyRecordError.fenced }
        var after = stat()
        guard fstat(parentFD, &after) == 0, sameStable(before,after),
              after.st_nlink == before.st_nlink || (child.kind == S_IFDIR && before.st_nlink > 0 && after.st_nlink == before.st_nlink - 1),
              try PolicyAuthorityFile.safeACL(parentFD) == node.acl,
              try attributes(parentFD) == node.attributes else { throw CustodyRecordError.conflict }
        // Only successful child unlink permits size/mtime/ctime and the bounded
        // directory-child link-count transition. All future checks are exact.
        node.identity = after
        try validateRoster(node, fd: parentFD)
    }
    private func closeMutationFrontier() throws {
        while let last = mutation.last {
            guard last.descriptor.retireChecked() == .succeeded else { poisoned = true; throw CustodyRecordError.fenced }
            #if SHADOW_SYNC_TESTING
            testingClosed += 1
            #endif
            mutation.removeLast()
        }
        mutationNode = nil; mutationRoot = false
    }
    func retire() throws -> InstallationSlotImage {
        try revalidate()
        for (index,node) in order.enumerated() {
            if node.stage == .retired { continue }
            try boundary(); try permit.validate(owner: owner, action: .restoreApplication)
            if node.stage == .untouched {
                try revalidate() // unexplained absence/change stops further mutation
                guard node.children.allSatisfy({ $0.stage == .retired }) else { throw CustodyRecordError.fenced }
                if mutationNode == nil {
                    do { _ = try openPath(node) } catch { try closeInspection(); throw error }
                    mutation = inspection; inspection = []; mutationNode = node; mutationRoot = node.parent == nil
                }
                let (fd,parentFD) = try mutationFD(node)
                try validatePresent(node, fd: fd, parentFD: parentFD)
                #if SHADOW_SYNC_TESTING
                try fail(.beforeUnlink(index))
                // A synchronous in-call seam: first unlink has succeeded and
                // retired; mutate the NEXT boundary without unwinding Bootstrap.
                if index == 1, let barrier = testingMutationBarrier {
                    testingMutationBarrier = nil
                    try barrier(testingUnlinks, node.path)
                }
                #endif
                try permit.validateMutation(owner: owner, action: .restoreApplication)
                try boundary(); try validatePresent(node, fd: fd, parentFD: parentFD)
                try permit.validate(owner: owner, action: .restoreApplication)
                guard unlinkat(parentFD, node.name, node.kind == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else {
                    poisoned = true; throw CustodyRecordError.persistence(errno)
                }
                node.stage = .unlinked // causal success before every throwable boundary
                #if SHADOW_SYNC_TESTING
                testingUnlinks += 1
                #endif
                do { try acceptParentTransition(after: node, parentFD: parentFD) } catch { poisoned = true; throw error }
                #if SHADOW_SYNC_TESTING
                try fail(.afterUnlink(index))
                #endif
            }
            if node.stage == .unlinked {
                try validateRemoved(node); try boundary()
                let (_,parentFD) = try mutationFD(node)
                #if SHADOW_SYNC_TESTING
                try fail(.syncFailure(index))
                #endif
                guard fsync(parentFD) == 0 else { throw CustodyRecordError.persistence(errno) }
                node.stage = .fsynced
                #if SHADOW_SYNC_TESTING
                try fail(.afterSync(index))
                #endif
            }
            if node.stage == .fsynced {
                try validateRemoved(node); try boundary()
                let descriptor = mutationRoot ? rootDescriptor : mutation.last!.descriptor
                #if SHADOW_SYNC_TESTING
                if testingCut == .closeUnknown(index) {
                    testingReachedCut = testingCut; testingCut = nil
                    descriptor.testingClose = { raw in guard Darwin.close(raw) == 0 else { return errno }; return EIO }
                }
                #endif
                guard descriptor.retireChecked() == .succeeded else { poisoned = true; throw CustodyRecordError.fenced }
                node.stage = .retired
                #if SHADOW_SYNC_TESTING
                if !mutationRoot { testingClosed += 1 }
                #endif
                if !mutationRoot { mutation.removeLast() }
                try closeMutationFrontier()
                #if SHADOW_SYNC_TESTING
                try fail(.afterClose(index))
                #endif
            }
        }
        try revalidate()
        guard nodes.allSatisfy({ $0.stage == .retired }), rootDescriptor.retirementObservation == .succeeded else { throw CustodyRecordError.fenced }
        retainedSelf = nil; postimageDelivered = true
        return InstallationSlotImage(parentDevice: parent.identity.device, parentInode: parent.identity.inode,
            node: nil, size: nil, contentDigest: nil, documentReceipts: nil)
    }
    var complete: Bool { sealed && !poisoned && !enumerationCloseUnknown && nodes.allSatisfy { $0.stage == .retired } }
    // A private in-flight image is only used to compare unchanged slot metadata.
    // It is never published as a complete postimage of a partially deleted tree.
    func observedImage(parent candidateParent: InstallationCaptureParent) throws -> InstallationSlotImage {
        guard candidateParent === parent else { throw CustodyRecordError.fenced }
        try revalidate()
        return postimageDelivered ? InstallationSlotImage(parentDevice: parent.identity.device, parentInode: parent.identity.inode,
            node: nil, size: nil, contentDigest: nil, documentReceipts: nil) : original
    }
}

#if SHADOW_SYNC_TESTING
// Fixture-only descriptor handback, after the root guardian joins all original
// children and sessions. This neither resumes rollback nor removes bundle bytes.
extension InstallationCandidateRetirement: InstallationNamedSocketFixtureCustodyOwner {
    func retireNamedSocketFixture(deadline: MonotonicDeadline) throws {
        guard !deadline.hasExpired, enumerationRaw == nil, enumerationStream == nil,
              !enumerationCloseUnknown else { throw CustodyRecordError.fenced }
        for handle in Array(inspection.reversed()) + Array(mutation.reversed()) {
            guard !deadline.hasExpired, handle.descriptor.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }
            testingClosed += 1
        }
        inspection = []; mutation = []; mutationNode = nil
        if let resourceProbe {
            guard resourceProbe.retireChecked() == .succeeded else { throw CustodyRecordError.fenced }
            testingClosed += 1
        }
        resourceProbe = nil
        guard rootDescriptor.retireChecked() == .succeeded,
              testingAcquired == testingClosed else { throw CustodyRecordError.fenced }
        testingMutationBarrier = nil; testingResourceFault = nil
        poisoned = true; retainedSelf = nil
    }
}
#endif

#if SHADOW_SYNC_TESTING
enum InstallationFreshRetirementManifestFixtures {
    static func bounds() throws { try InstallationCandidateRetirement.testingManifestBounds() }
}
#endif
