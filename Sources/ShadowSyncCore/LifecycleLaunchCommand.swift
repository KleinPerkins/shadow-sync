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

    init(request: UnvalidatedCustodyRequest, helper: CustodyHelperExecutable, account: EffectiveAccount) throws {
        guard helper.isLifecycleCoordinator, request.kind == .launchctlMutation,
              request.authority == .lifecycleMutation,
              request.environment == ClosedProcessRunner.environment(account: account) else { throw CustodyRecordError.fenced }
        command = try LifecycleLaunchCommand(arguments: request.arguments, account: account)
        self.helper = helper
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
              command.operation == .bootout || contract.sha256 == helper.releaseSHA256 else { throw PublisherPolicyError.unavailable }
        try PublisherCodeVerifier.sealed(contract, relativePath: "Resources/release-contract.json", code: code)
        let plist = try InstallationLifecycle.captureCurrentLaunchAgent(command.plist, executable: command.executable)
        files = [info, contract, seal, plist]
        try revalidate()
    }
    func revalidate() throws {
        try helper.revalidate(); try readGraph.revalidate(); try mutationGraph.revalidate()
        for file in files { try file.revalidate() }
        guard executable == (try PublisherExecutableSnapshot.capture(path: command.executable, owner: command.account.uid)),
              identity == (try PublisherCodeVerifier.verifiedStatic(path: command.app,
                identifier: ReleaseIdentity.bundleIdentifier, team: ReleaseIdentity.publisherTeamIdentifier).1) else {
            throw PublisherPolicyError.unavailable
        }
    }
}
