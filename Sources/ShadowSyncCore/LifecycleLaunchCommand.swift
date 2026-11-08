import Darwin
import Foundation

/// Closed launchd forms for the current installation. A decoded command is
/// intent only: the custodian must retain publisher, plist and actual leases.
struct LifecycleLaunchCommand {
    enum Operation: String, CaseIterable { case bootstrap, kickstart, bootout }
    let operation: Operation
    let account: EffectiveAccount
    var app: String { account.homeDirectory + "/Applications/ShadowSync.app" }
    var executable: String { app + "/Contents/MacOS/ShadowSync" }
    var plist: String { account.homeDirectory + "/Library/LaunchAgents/" + InstallationPaths.label + ".plist" }
    var service: String { "gui/\(account.uid)/\(InstallationPaths.label)" }
    var printArguments: [String] { ["print", service] }
    var arguments: [String] {
        switch operation {
        case .bootstrap: ["bootstrap", "gui/\(account.uid)", plist]
        case .kickstart: ["kickstart", service]
        case .bootout: ["bootout", service]
        }
    }
    init(operation: Operation, account: EffectiveAccount) {
        self.operation = operation; self.account = account
    }
    init(arguments: [String], account: EffectiveAccount) throws {
        guard let first = arguments.first, let operation = Operation(rawValue: first) else {
            throw CustodyResourceError.invalidResource
        }
        self.init(operation: operation, account: account)
        guard arguments == self.arguments else { throw CustodyResourceError.invalidResource }
    }

    /// Consume complete streams and the actual raw wait status. In particular,
    /// arbitrary nonzero errors containing an absence phrase are not absence.
    func state(waitStatus: Int32, stdout: Data, stderr: Data) throws -> LaunchAgentState {
        func text(_ bytes: Data) throws -> String {
            guard bytes.count <= LifecycleCommandRunner.outputLimit, !bytes.contains(0),
                  let value = String(data: bytes, encoding: .utf8) else { throw CustodyResourceError.invalidResource }
            return value
        }
        let output = try text(stdout), error = try text(stderr)
        if waitStatus == 113 << 8, output.isEmpty,
           error == "Bad request.\nCould not find service \"\(InstallationPaths.label)\" in domain for user gui: \(account.uid)\n" {
            return .absent
        }
        guard waitStatus == 0, error.isEmpty, output.hasSuffix("\n") else { throw CustodyResourceError.invalidResource }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard lines.first == service + " = {" else { throw CustodyResourceError.invalidResource }
        var depth = 1, ended = false, fields: [String: String] = [:]
        var arguments: [String] = [], inArguments = false, sawArguments = false
        for line in lines.dropFirst() {
            if ended {
                guard line.isEmpty else { throw CustodyResourceError.invalidResource }
                continue
            }
            if line.isEmpty { continue }
            if line == "}" {
                guard depth > 0 else { throw CustodyResourceError.invalidResource }
                if depth == 2, inArguments { inArguments = false }
                depth -= 1; ended = depth == 0
                continue
            }
            if line.hasSuffix(" = {") {
                guard !inArguments, depth < 16 else { throw CustodyResourceError.invalidResource }
                if depth == 1 {
                    let key = String(line.dropLast(4))
                    guard fields.updateValue("{", forKey: key) == nil else { throw CustodyResourceError.invalidResource }
                    if key == "arguments" { inArguments = true; sawArguments = true }
                }
                depth += 1; continue
            }
            if inArguments {
                guard depth == 2, arguments.count < 2 else { throw CustodyResourceError.invalidResource }
                arguments.append(line); continue
            }
            if depth == 1 {
                guard let separator = line.range(of: " = ") else { throw CustodyResourceError.invalidResource }
                let key = String(line[..<separator.lowerBound]), value = String(line[separator.upperBound...])
                guard !key.isEmpty, !value.isEmpty, fields.updateValue(value, forKey: key) == nil else {
                    throw CustodyResourceError.invalidResource
                }
            }
        }
        guard ended, depth == 0, sawArguments,
              fields["program"] == executable, fields["path"] == plist,
              fields["type"] == "LaunchAgent",
              arguments == [executable, InstallationPaths.managedHostArgument] else { throw CustodyResourceError.invalidResource }
        var pid: pid_t?
        if let value = fields["pid"] {
            guard let parsed = pid_t(value), parsed > 1, String(parsed) == value else { throw CustodyResourceError.invalidResource }
            pid = parsed
        }
        return .loaded(program: executable, processID: pid)
    }

    /// Semantic convergence only. The caller must separately authenticate the
    /// retained live socket and compare its full current process identity.
    func validateReadyHost(_ state: LaunchAgentState, host: ProcessIdentity) throws {
        guard case .loaded(let program, let pid) = state, program == executable,
              pid == host.processID, host.processID > 1, host.userID == account.uid, host.executablePath == executable else { throw CustodyRecordError.fenced }
    }

    func validateCompletion(_ result: CustodyRegistryResult) throws {
        guard result.phase == .finished, result.reason == nil,
              let journal = result.journal, journal.kind == .launchctlMutation,
              journal.authority == .lifecycleMutation, journal.phase == .terminal,
              journal.ordinal == 5, journal.reason == CustodyReason.none, let raw = journal.waitStatus,
              journal.outcome == (operation == .bootout ? .commandFailed : .completed) else {
            throw CustodyRecordError.fenced
        }
        // bootout's final print exits 113. Preserve that actual child result in
        // custody; only the closed semantic adapter can recognize proven absence.
        try validatePostflight(state(waitStatus: Int32(raw), stdout: result.stdout, stderr: result.stderr))
    }

    // Separate from ordinary lifecycle completion. This validates semantics only;
    // the registry-minted token supplies actual retirement and journal succession.
    func validateStagedCompletion(_ result: CustodyRegistryResult, request: UnvalidatedCustodyRequest) throws {
        guard request.authority.isInstallationStaged, request.kind == .launchctlMutation,
              request.arguments == arguments, result.phase == .finished, result.reason == nil,
              let journal = result.journal, journal.binding == (try CustodyRecordBinding(request.binding)),
              journal.kind == request.kind, journal.authority == request.authority,
              journal.budget == request.budget, journal.inputSHA256 == request.inputSHA256,
              journal.resourcesSHA256 == request.resourcesSHA256,
              journal.phase == .terminal, journal.ordinal == 5, journal.reason == CustodyReason.none,
              journal.outcome == (operation == .bootout ? .commandFailed : .completed),
              let raw = journal.waitStatus else { throw CustodyRecordError.fenced }
        guard (operation == .bootout) == (request.authority == .installationStagedStop) else { throw CustodyRecordError.fenced }
        try validatePostflight(state(waitStatus: Int32(raw), stdout: result.stdout, stderr: result.stderr))
    }
    enum RecoveryLayout { case before, after, unchangedLoaded }
    /// Filesystem equality does not classify launchd state or prove no start ran.
    /// Missing PID is an unchanged loaded layout, never authenticated readiness.
    func recoveryLayout(action: InstallationAction, state: LaunchAgentState) throws -> RecoveryLayout {
        switch (action, state) {
        case (.bootstrapCandidate, .absent): return .before
        case (.bootstrapCandidate, .loaded(let program, nil)):
            guard program == executable else { throw CustodyRecordError.fenced }; return .after
        case (.kickstartCandidate, .loaded(let program, nil)):
            guard program == executable else { throw CustodyRecordError.fenced }; return .unchangedLoaded
        case (.kickstartCandidate, .loaded(let program, let pid)):
            guard program == executable, let pid,
                  SystemLaunchAgentController().processDisposition(processID: pid, expectedProgram: executable) == .matching else {
                throw CustodyRecordError.fenced
            }
            return .after
        default: throw CustodyRecordError.fenced
        }
    }
    func validatePreflight(_ state: LaunchAgentState) throws {
        switch (operation, state) {
        case (.bootstrap, .absent): return
        case (.kickstart, .loaded(let program, let pid)), (.bootout, .loaded(let program, let pid)):
            guard program == executable else { throw CustodyResourceError.invalidResource }
            if let pid {
                let disposition = SystemLaunchAgentController().processDisposition(processID: pid, expectedProgram: executable)
                guard disposition != .mismatch, operation != .kickstart || disposition == .absent else {
                    throw CustodyResourceError.invalidResource
                }
            }
        default: throw CustodyResourceError.invalidResource
        }
    }
    func validatePostflight(_ state: LaunchAgentState) throws {
        switch (operation, state) {
        case (.bootout, .absent): return
        case (.bootstrap, .loaded(let program, nil)):
            guard program == executable else { throw CustodyResourceError.invalidResource }
        case (.kickstart, .loaded(let program, let pid)):
            guard program == executable else { throw CustodyResourceError.invalidResource }
            if let pid {
                guard SystemLaunchAgentController().processDisposition(processID: pid, expectedProgram: executable) == .matching else {
                    throw CustodyResourceError.invalidResource
                }
            }
        default: throw CustodyResourceError.invalidResource
        }
    }
    #if SHADOW_SYNC_TESTING
    static let fixtureModes = ["lifecycle-bootstrap", "lifecycle-kickstart", "lifecycle-bootout",
        "lifecycle-preflight-foreign", "lifecycle-mutation-failure", "lifecycle-postflight-absent",
        "lifecycle-preflight-cancel", "lifecycle-mutation-cancel", "lifecycle-postflight-cancel",
        "lifecycle-between-cancel", "lifecycle-next-before-record", "lifecycle-postflight-timeout",
        "lifecycle-next-before-spawn", "lifecycle-next-after-spawn", "lifecycle-preflight-overflow", "lifecycle-postflight-overflow"]
    static func fixture(mode: String, account: EffectiveAccount) -> Self? {
        guard fixtureModes.contains(mode) else { return nil }
        return Self(operation: mode == "lifecycle-kickstart" ? .kickstart : mode == "lifecycle-bootout" ? .bootout : .bootstrap,
                    account: account)
    }
    var fixtureLoadedOutput: Data {
        Data((service + " = {\n\tpath = " + plist + "\n\ttype = LaunchAgent\n\tprogram = " + executable
            + "\n\targuments = {\n\t\t" + executable + "\n\t\t--managed-host\n\t}\n}\n").utf8)
    }
    var fixtureAbsentError: Data {
        Data("Bad request.\nCould not find service \"\(InstallationPaths.label)\" in domain for user gui: \(account.uid)\n".utf8)
    }
    #endif

}

/// Independently reconstructed in the coordinator custodian, never imported
/// from caller assertions. It remains alive across all three command stages.
final class LifecycleLaunchAuthority {
    let command: LifecycleLaunchCommand
    let readGraph: QualifiedCommandGraph
    let mutationGraph: QualifiedCommandGraph
    private let helper: CustodyHelperExecutable
    private let identity: PublisherCodeVerifier.Identity
    private let executable: PublisherExecutableSnapshot
    private let files: [PolicyAuthorityFile]
    private let stagedCandidate: InstallationStagedCandidateAuthority?

    init(request: UnvalidatedCustodyRequest, helper: CustodyHelperExecutable, account: EffectiveAccount,
         installation: InstallationCommandBinding? = nil) throws {
        guard helper.isLifecycleCoordinator, request.kind == .launchctlMutation,
              request.authority == .lifecycleMutation || request.authority.isInstallationStaged,
              request.environment == ClosedProcessRunner.environment(account: account) else { throw CustodyRecordError.fenced }
        command = try LifecycleLaunchCommand(arguments: request.arguments, account: account)
        self.helper = helper
        if request.authority.isInstallationStaged {
            guard let installation else { throw CustodyRecordError.fenced }
            try installation.validateStagedOperation(mode: request.authority, operation: command.operation)
            stagedCandidate = try InstallationStagedCandidateAuthority(binding: installation, helper: helper, account: account)
        } else {
            guard installation == nil else { throw CustodyRecordError.fenced }
            stagedCandidate = nil
        }
        readGraph = try QualifiedCommandGraph.production(kind: .launchctlRead, helper: helper)
        mutationGraph = try QualifiedCommandGraph.production(kind: .launchctlMutation, helper: helper)
        executable = try PublisherExecutableSnapshot.capture(path: command.executable, owner: account.uid)
        let (code, identity) = try PublisherCodeVerifier.verifiedStatic(path: command.app,
            identifier: ReleaseIdentity.bundleIdentifier, team: ReleaseIdentity.publisherTeamIdentifier)
        self.identity = identity
        let info = try PolicyAuthorityFile.read(path: command.app + "/Contents/Info.plist", owner: account.uid, maximumBytes: 65_536)
        let contract = try PolicyAuthorityFile.read(path: command.app + "/Contents/Resources/release-contract.json", owner: account.uid, maximumBytes: 65_536)
        let seal = try PolicyAuthorityFile.read(path: command.app + "/Contents/_CodeSignature/CodeResources", owner: account.uid, maximumBytes: 1_048_576)
        guard let dictionary = try PropertyListSerialization.propertyList(from: info.bytes, format: nil) as? [String: Any] else {
            throw PublisherPolicyError.unavailable
        }
        let release = try ReleaseIdentity(infoDictionary: dictionary); try release.validate(requireProduction: true)
        guard release.releaseContractSHA256 == contract.sha256,
              (command.operation == .bootout && !request.authority.isInstallationStaged) || contract.sha256 == helper.releaseSHA256 else { throw PublisherPolicyError.unavailable }
        try PublisherCodeVerifier.sealed(contract, relativePath: "Resources/release-contract.json", code: code)
        let plist = try InstallationLifecycle.captureCurrentLaunchAgent(command.plist, executable: command.executable)
        files = [info, contract, seal, plist]
        try revalidate()
    }
    func revalidate() throws {
        try helper.revalidate(); try readGraph.revalidate(); try mutationGraph.revalidate()
        try stagedCandidate?.revalidate()
        for file in files { try file.revalidate() }
        guard executable == (try PublisherExecutableSnapshot.capture(path: command.executable, owner: command.account.uid)),
              identity == (try PublisherCodeVerifier.verifiedStatic(path: command.app,
                identifier: ReleaseIdentity.bundleIdentifier, team: ReleaseIdentity.publisherTeamIdentifier).1) else {
            throw PublisherPolicyError.unavailable
        }
    }
}

/// Candidate-only identity for BOTH staged start and stop, including fixed
/// diagnostics. The live owner or authenticated inherited publisher supplies
/// authority; this observation only narrows it to the promoted bytes/inodes.
final class InstallationStagedCandidateAuthority {
    private let binding: InstallationCommandBinding
    private let helper: CustodyHelperExecutable
    private let command: LifecycleLaunchCommand
    private let slots: InstallationStagedCandidateSlots
    private let plist: PolicyAuthorityFile
    init(binding: InstallationCommandBinding, helper: CustodyHelperExecutable, account: EffectiveAccount) throws {
        try binding.validate()
        guard binding.stagedMode != nil else { throw CustodyRecordError.fenced }
        self.binding = binding; self.helper = helper
        command = LifecycleLaunchCommand(operation: .bootstrap, account: account)
        slots = try InstallationStagedCandidateSlots(binding: binding, account: account)
        plist = try InstallationLifecycle.captureCurrentLaunchAgent(command.plist, executable: command.executable)
        try revalidate()
    }
    func revalidate() throws {
        guard let transaction = binding.control.transaction, let candidate = transaction.candidate,
              transaction.sourceReleaseDigest == helper.releaseSHA256,
              candidate.release.releaseContractSHA256 == helper.releaseSHA256,
              let app = transaction.slots.images[.application], let launch = transaction.slots.images[.launchPlist] else {
            throw CustodyRecordError.fenced
        }
        try helper.validateInstallationPublisher(transaction); try slots.revalidate(); try plist.revalidate()
        let artifact = try BundleArtifactIdentity.inspect(bundlePath: command.app, requireProduction: true)
        guard artifact.release == candidate.release, artifact.canonicalSHA256 == candidate.bundleDigest,
              app.contentDigest == artifact.canonicalSHA256, launch.contentDigest == plist.sha256,
              launch.size == UInt64(plist.bytes.count) else { throw CustodyRecordError.fenced }
        #if SHADOW_SYNC_TESTING
        if helper.testingInstallationSourceRoot != nil {
            // Only the already authenticated disposable custodian fixture can
            // use inert unsigned bytes. Production always checks both CDHashes.
            try slots.revalidate(); return
        }
        #endif
        let appCode = try PublisherCodeVerifier.verifiedStatic(path: command.app,
            identifier: ReleaseIdentity.bundleIdentifier, team: ReleaseIdentity.publisherTeamIdentifier).1
        let coordinatorCode = try PublisherCodeVerifier.verifiedStatic(path: command.app + LifecyclePublisher.relativeExecutable,
            identifier: LifecyclePublisher.identifier, team: ReleaseIdentity.publisherTeamIdentifier).1
        guard appCode.codeDirectory.map({ String(format: "%02x", $0) }).joined() == candidate.appCDHash,
              coordinatorCode.codeDirectory.map({ String(format: "%02x", $0) }).joined() == candidate.coordinatorCDHash else {
            throw CustodyRecordError.fenced
        }
        try slots.revalidate(); try plist.revalidate(); try helper.validateInstallationPublisher(transaction)
    }
}
