import Darwin
import Foundation
import Security

enum PolicyHelperError: Error, CustomStringConvertible {
    case unavailable, cleanupPending
    var description: String {
        switch self {
        case .unavailable: "Repository policy classification is unavailable."
        case .cleanupPending: "Repository policy work is still stopping."
        }
    }
}

/// Process transport only. The host-binding factory must supply publisher-verified
/// resource bytes, an explicitly qualified interpreter, and a revalidation closure
/// binding those snapshots to the current deployed policy. There is no PATH lookup
/// or permissive production default. Candidate paths are opaque stdin data.
struct PolicyHelperTransport {
    let interpreter: String
    let adapter: Data
    let contract: Data
    let bindingSHA256: String
    let policySHA256: String
    let moduleSHA256: String
    let account: EffectiveAccount
    let revalidateAuthority: () throws -> Void
    let validateSuspendedChild: (pid_t) throws -> Void

    private let custody: PolicyCustodyExecution?

    init(snapshot: HostPolicySnapshot, publisher: PublisherPolicyResources,
         context: CommandCustodyContext) {
        interpreter = publisher.interpreter; adapter = publisher.adapter; contract = publisher.contract
        bindingSHA256 = snapshot.bindingSHA256; policySHA256 = snapshot.binding.policy.sha256
        moduleSHA256 = snapshot.binding.module.sha256; account = snapshot.account
        let admission = context.phaseAdmissionCheck()
        revalidateAuthority = { try admission(); try snapshot.revalidate(); try publisher.revalidate() }
        validateSuspendedChild = { try publisher.validateSuspendedInterpreter($0) }
        custody = PolicyCustodyExecution(context: context, snapshot: snapshot, publisher: publisher)
    }
    #if SHADOW_SYNC_TESTING
    /// The raw interpreter/closure construction exists only for isolated legacy
    /// transport fixtures. Production callers require typed publisher authority.
    init(interpreter: String, adapter: Data, contract: Data, bindingSHA256: String,
         policySHA256: String, moduleSHA256: String, account: EffectiveAccount,
         revalidateAuthority: @escaping () throws -> Void,
         validateSuspendedChild: @escaping (pid_t) throws -> Void) {
        self.interpreter = interpreter; self.adapter = adapter; self.contract = contract
        self.bindingSHA256 = bindingSHA256; self.policySHA256 = policySHA256; self.moduleSHA256 = moduleSHA256
        self.account = account; self.revalidateAuthority = revalidateAuthority
        self.validateSuspendedChild = validateSuspendedChild; custody = nil
    }
    #endif

    func classify(
        candidates: [String],
        scratchDescriptor: Int32,
        timeout: TimeInterval,
        absoluteDeadline: UInt64? = nil,
        cancellation: CancellationToken,
        audit: CommandAudit? = nil
    ) throws -> [PolicyDecision] {
        #if SHADOW_SYNC_TESTING
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        var diagnosticStage = DiscoveryFixtureDiagnostic.Stage.budget
        var diagnosticPassed = false
        var diagnosticMilestones: [UInt64] = []
        defer {
            DiscoveryFixtureDiagnostic.record(.transport, stage: diagnosticStage,
                started: diagnosticStart, deadline: absoluteDeadline, succeeded: diagnosticPassed,
                milestones: diagnosticMilestones)
        }
        #endif
        do {
            // One absolute budget starts before nonce/serialization/authority
            // work; helper and registry consume this same remaining time.
            let budget = try PolicyCommandWire.budget(timeout: timeout, absoluteDeadline: absoluteDeadline)
            guard !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed,
                  timeout.isFinite, timeout > 0, timeout <= 2,
                  adapter.count > 0, adapter.count <= 65_536,
                  contract.count > 0, contract.count <= 16_384,
                  [bindingSHA256, policySHA256, moduleSHA256].allSatisfy(Self.digestShape)
            else { throw PolicyHelperError.unavailable }
            var random = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
                throw PolicyHelperError.unavailable
            }
            let nonce = random.map { String(format: "%02x", $0) }.joined()
            #if SHADOW_SYNC_TESTING
            diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
            diagnosticStage = .input
            #endif
            // Validate every candidate before authority reads or scratch creation.
            let request = try PolicyRequestEncoder.encode(
                candidates: candidates, nonce: nonce, bindingSHA256: bindingSHA256)
            let expected = ExpectedPolicyResponse(nonce: nonce, bindingSHA256: bindingSHA256,
                policySHA256: policySHA256, moduleSHA256: moduleSHA256,
                candidateCount: candidates.count)
            #if SHADOW_SYNC_TESTING
            diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
            diagnosticStage = .authorityBefore
            #endif
            try revalidateAuthority()
            guard !cancellation.isCancelled else { throw PolicyHelperError.unavailable }
            #if SHADOW_SYNC_TESTING
            diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
            diagnosticStage = .resources
            #endif
            let resources = try PolicyCommandWire.resources(adapter: adapter, contract: contract)
            let output: Data
            #if SHADOW_SYNC_TESTING
            diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
            diagnosticStage = .execution
            #endif
            if let custody {
                output = try custody.execute(input: request, code: resources, budget: budget, cancellation: cancellation, audit: audit)
            } else {
                #if SHADOW_SYNC_TESTING
                let input = try ClosedProcessInput(data: request, directory: scratchDescriptor,
                                                   owner: account.uid)
                let code = try ClosedProcessInput(data: resources, directory: scratchDescriptor,
                                                  owner: account.uid)
                let result = try withExtendedLifetime((input, code)) {
                    try ClosedProcessRunner(outputLimit: 65_536, audit: audit).run(
                        command: ClosedProcessCommand(
                            executable: interpreter,
                            arguments: PolicyCommandWire.interpreterArguments,
                            logicalExecutable: "shadow-sync-policy-helper",
                            logicalArguments: ["isolated-policy-classification"],
                            inheritedReadSnapshotDescriptor: code.descriptor,
                            standardInputDescriptor: input.descriptor),
                        environment: ClosedProcessRunner.environment(account: account),
                        workingDirectoryDescriptor: scratchDescriptor,
                        account: account, timeout: timeout, cancellation: cancellation,
                        validateSuspendedChild: validateSuspendedChild)
                }
                guard result.succeeded, result.stderr.isEmpty, !result.terminationRequested else {
                    throw PolicyHelperError.unavailable
                }
                output = result.stdout
                #else
                throw PolicyHelperError.unavailable
                #endif
            }
            guard !cancellation.isCancelled else { throw PolicyHelperError.unavailable }
            #if SHADOW_SYNC_TESTING
            diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
            diagnosticStage = .authorityAfter
            #endif
            try revalidateAuthority()
            guard !cancellation.isCancelled else { throw PolicyHelperError.unavailable }
            #if SHADOW_SYNC_TESTING
            diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
            diagnosticStage = .decode
            #endif
            let decoded = try PolicyResponseDecoder.decode(output, expected: expected)
            #if SHADOW_SYNC_TESTING
            diagnosticPassed = true
            #endif
            return decoded
        } catch PolicyHelperError.cleanupPending {
            throw PolicyHelperError.cleanupPending
        } catch {
            // Never expose arbitrary child output, errors or private candidate text.
            throw PolicyHelperError.unavailable
        }
    }

    private static func digestShape(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

}

/// Weak phase admission prevents escaped sessions from retaining a read lock.
/// Once submitted, the prepared command/registry retain actual authority until
/// durable retirement, independently of caller return or cancellation.
private final class PolicyCustodyExecution {
    private weak var context: CommandCustodyContext?
    private let snapshot: HostPolicySnapshot
    private let publisher: PublisherPolicyResources
    init(context: CommandCustodyContext, snapshot: HostPolicySnapshot, publisher: PublisherPolicyResources) {
        self.context = context; self.snapshot = snapshot; self.publisher = publisher
    }
    func execute(input: Data, code: Data, budget: CustodyBudget,
                 cancellation: CancellationToken, audit: CommandAudit?) throws -> Data {
        #if SHADOW_SYNC_TESTING
        let diagnosticStart = DispatchTime.now().uptimeNanoseconds
        var diagnosticStage = DiscoveryFixtureDiagnostic.Stage.prepare
        var diagnosticPassed = false
        var diagnosticMilestones: [UInt64] = []
        var diagnosticResultBits: UInt64 = 0
        defer {
            DiscoveryFixtureDiagnostic.record(.custody, stage: diagnosticStage,
                started: diagnosticStart, deadline: budget.work, resultBits: diagnosticResultBits,
                succeeded: diagnosticPassed, milestones: diagnosticMilestones)
        }
        #endif
        guard let context else { throw PolicyHelperError.unavailable }
        let command = try context.preparePolicy(input: input, code: code, snapshot: snapshot,
            publisher: publisher, budget: budget, cancellation: cancellation)
        guard !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else { throw PolicyHelperError.unavailable }
        #if SHADOW_SYNC_TESTING
        diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
        diagnosticStage = .start
        #endif
        let handle = try RetainedCleanupRegistry.shared.start(command)
        audit?.record(CommandInvocation(executable: "shadow-sync-policy-helper",
            arguments: PolicyCommandWire.logicalArguments,
            environmentKeys: ClosedProcessRunner.environment(account: snapshot.account).keys.sorted()))
        let observer = cancellation.observeCustodyCancellation(handle)
        defer { cancellation.removeCustodyCancellation(observer) }
        #if SHADOW_SYNC_TESTING
        diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
        diagnosticStage = .wait
        #endif
        let result = handle.wait()
        #if SHADOW_SYNC_TESTING
        diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
        diagnosticStage = .result
        diagnosticResultBits = (result.phase == .finished ? 1 : 0)
        diagnosticResultBits |= (result.journal?.phase == .terminal ? 2 : 0)
        diagnosticResultBits |= (result.journal?.outcome == .completed ? 4 : 0)
        diagnosticResultBits |= (result.journal?.waitStatus == 0 ? 8 : 0)
        diagnosticResultBits |= (result.stderr.isEmpty ? 16 : 0)
        diagnosticResultBits |= (result.trace.isEmpty ? 32 : 0)
        diagnosticResultBits |= (!cancellation.isCancelled && !cancellation.areFutureChildAdmissionsClosed ? 64 : 0)
        diagnosticResultBits |= (result.reason == nil || result.reason == CustodyReason.none ? 128 : 0)
        #endif
        if result.phase == .cleanupPending {
            context.close(); cancellation.closeFutureChildAdmissions()
            throw PolicyHelperError.cleanupPending
        }
        guard result.phase == .finished, result.reason == nil || result.reason == CustodyReason.none,
              let journal = result.journal, journal.phase == .terminal,
              journal.outcome == .completed, journal.waitStatus == 0,
              result.stderr.isEmpty, result.trace.isEmpty,
              !cancellation.isCancelled, !cancellation.areFutureChildAdmissionsClosed else {
            throw PolicyHelperError.unavailable
        }
        #if SHADOW_SYNC_TESTING
        diagnosticMilestones.append(DispatchTime.now().uptimeNanoseconds)
        diagnosticStage = .postflight
        #endif
        try context.validatePhaseAdmission(); try snapshot.revalidate(); try publisher.revalidate()
        #if SHADOW_SYNC_TESTING
        diagnosticPassed = true
        #endif
        return result.stdout
    }
}
