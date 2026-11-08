import Darwin
import Foundation

/// Pure observations, never an admission factory. The live host independently
/// authenticates the retained stream and reads the complete durable chain.
enum InstallationHostCommitBinding {
    /// Framing observation only. After actual commit consumption EOF is not
    /// rollback; extra bytes still refuse this component's future startup edge.
    static func requireNoPostcommitInput(_ socket: OwnedFileDescriptor) throws {
        let fd = try socket.duplicate(); defer { close(fd) }
        var byte: UInt8 = 0
        let count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        guard count == 0 || (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) else {
            throw CustodyProtocolError.invalidSequence
        }
    }

    static func expectedControl(after original: InstallationControlRecord,
                                host: InstallationProcessObservation,
                                transcriptDigest: String) throws -> InstallationControlRecord {
        guard original.phase == .active, original.readinessCommit == nil,
              original.recoveryReason == nil, original.step?.action == .kickstartCandidate,
              original.step?.status == .complete, original.step?.ordinal == 14,
              original.revision <= UInt64.max - 4,
              let transaction = original.transaction, let candidate = transaction.candidate else {
            throw CustodyRecordError.fenced
        }
        var record = original
        var candidateReadyDigest: String?
        for (action, ordinal) in [(InstallationAction.candidateReady, UInt64(15)), (.readinessCommit, UInt64(16))] {
            for status in [InstallationStepStatus.intent, .complete] {
                let receipt = InstallationStepReceipt(transactionID: transaction.id, ordinal: ordinal,
                    previousReceiptDigest: record.latestReceiptDigest, action: action, status: status,
                    preimage: transaction.slots, postimage: status == .complete ? transaction.slots : nil,
                    bindingDigest: try transaction.bindingDigest(state: original.state))
                let observation = try InstallationStepReceipt.CanonicalObservation(validating: receipt,
                    uid: original.state.directory.uid)
                if action == .candidateReady && status == .complete { candidateReadyDigest = observation.digest }
                var commit: InstallationReadinessCommit?
                if action == .readinessCommit && status == .complete {
                    guard let candidateReadyDigest else { throw CustodyRecordError.fenced }
                    commit = InstallationReadinessCommit(transactionID: transaction.id,
                        commitRevision: record.revision + 1,
                        candidateReleaseDigest: candidate.release.releaseContractSHA256,
                        candidateBundleDigest: candidate.bundleDigest, candidateAppCDHash: candidate.appCDHash,
                        candidateCoordinatorCDHash: candidate.coordinatorCDHash,
                        stateBindingDigest: try original.state.digest(), completedStepReceiptDigest: candidateReadyDigest,
                        host: host, precommitTranscriptDigest: transcriptDigest)
                }
                record = InstallationControlRecord(revision: record.revision + 1,
                    phase: commit == nil ? .active : .committed, state: original.state, transaction: transaction,
                    step: try receipt.step(), latestReceiptDigest: observation.digest,
                    readinessCommit: commit, recoveryReason: nil)
                try record.validate()
            }
        }
        return record
    }

    static func validateMessage(_ message: InstallationReadinessMessage, ready: InstallationReadinessMessage,
                                committed: InstallationControlRecord, deadline: MonotonicDeadline) throws {
        guard !deadline.hasExpired, ready.event == .ready, committed.phase == .committed,
              let commit = committed.readinessCommit, commit.commitRevision == committed.revision,
              ready.controlRevision <= UInt64.max - 4,
              committed.revision == ready.controlRevision + 4,
              message == InstallationReadinessMessage(event: .commit, transactionID: ready.transactionID,
                boot: ready.boot, controlRevision: committed.revision,
                candidateReleaseDigest: ready.candidateReleaseDigest, stateBindingDigest: ready.stateBindingDigest,
                hostGeneration: ready.hostGeneration, sessionNonce: ready.sessionNonce,
                previousMessageDigest: try ready.digest()) else { throw CustodyProtocolError.invalidSequence }
        try message.validate()
    }
}
