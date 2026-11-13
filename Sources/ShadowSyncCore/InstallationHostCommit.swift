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
                                transcriptDigest: String,
                                validationProfile: InstallationValidationProfile = .production) throws -> InstallationControlRecord {
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
                try record.validate(profile: validationProfile)
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

/// Closed postcommit transcript. These values provide framing only; the live
/// endpoints separately authenticate native peers and current durable records.
struct InstallationStartupTranscript {
    private var previous: InstallationReadinessMessage
    private enum Phase { case committed, started, stopping, stopped }
    private var phase: Phase = .committed
    init(commit: InstallationReadinessMessage) throws {
        try commit.validate()
        guard commit.event == .commit else { throw CustodyProtocolError.invalidSequence }
        previous = commit
    }
    func message(_ event: InstallationReadinessMessage.Event,
                 deadline: MonotonicDeadline) throws -> InstallationReadinessMessage {
        guard !deadline.hasExpired else { throw CustodyRecordError.busy }
        let revision: UInt64
        switch (phase, event) {
        case (.committed, .normalStarted): revision = previous.controlRevision
        case (.started, .stop):
            guard previous.controlRevision < UInt64.max else { throw CustodyProtocolError.invalidSequence }
            revision = previous.controlRevision + 1
        case (.stopping, .stopped): revision = previous.controlRevision
        default: throw CustodyProtocolError.invalidSequence
        }
        return InstallationReadinessMessage(event: event, transactionID: previous.transactionID,
            boot: previous.boot, controlRevision: revision,
            candidateReleaseDigest: previous.candidateReleaseDigest, stateBindingDigest: previous.stateBindingDigest,
            hostGeneration: previous.hostGeneration, sessionNonce: previous.sessionNonce,
            previousMessageDigest: try previous.digest())
    }
    mutating func consume(_ value: InstallationReadinessMessage,
        sender: InstallationReadinessMessage.Endpoint, deadline: MonotonicDeadline) throws {
        guard value.event.sender == sender, value == (try message(value.event, deadline: deadline)) else {
            throw CustodyProtocolError.invalidSequence
        }
        try value.validate()
        switch value.event {
        case .normalStarted: phase = .started
        case .stop: phase = .stopping
        case .stopped: phase = .stopped
        default: throw CustodyProtocolError.invalidSequence
        }
        previous = value
    }
    static func recovery(after committed: InstallationControlRecord) throws -> InstallationControlRecord {
        guard committed.phase == .committed, committed.readinessCommit != nil,
              committed.revision < UInt64.max else { throw CustodyRecordError.fenced }
        return InstallationControlRecord(revision: committed.revision + 1, phase: .recovery,
            state: committed.state, transaction: committed.transaction, step: committed.step,
            latestReceiptDigest: committed.latestReceiptDigest, readinessCommit: committed.readinessCommit,
            recoveryReason: .startupUncertain)
    }
}

/// Framing for the bounded candidate-ready-complete rollback branch. These
/// deterministic values are observations, never authentication or drain proof.
enum InstallationReadinessStopBinding {
    static func expectedControl(after original: InstallationControlRecord,
                                validationProfile: InstallationValidationProfile = .production) throws -> InstallationControlRecord {
        guard original.phase == .active, original.readinessCommit == nil,
              original.recoveryReason == nil, original.step?.action == .kickstartCandidate,
              original.step?.status == .complete, original.step?.ordinal == 14,
              original.revision <= UInt64.max - 4, let transaction = original.transaction else {
            throw CustodyRecordError.fenced
        }
        var record = original
        for status in [InstallationStepStatus.intent, .complete] {
            let receipt = InstallationStepReceipt(transactionID: transaction.id, ordinal: 15,
                previousReceiptDigest: record.latestReceiptDigest, action: .candidateReady, status: status,
                preimage: transaction.slots, postimage: status == .complete ? transaction.slots : nil,
                bindingDigest: try transaction.bindingDigest(state: original.state))
            let observation = try InstallationStepReceipt.CanonicalObservation(validating: receipt, uid: original.state.directory.uid)
            record = InstallationControlRecord(revision: record.revision + 1, phase: .active,
                state: original.state, transaction: transaction, step: try receipt.step(),
                latestReceiptDigest: observation.digest, readinessCommit: nil, recoveryReason: nil)
        }
        let stop = InstallationStepReceipt(transactionID: transaction.id, ordinal: 16,
            previousReceiptDigest: record.latestReceiptDigest, action: .candidateStop, status: .intent,
            preimage: transaction.slots, postimage: nil,
            bindingDigest: try transaction.bindingDigest(state: original.state))
        let observation = try InstallationStepReceipt.CanonicalObservation(validating: stop, uid: original.state.directory.uid)
        let result = InstallationControlRecord(revision: record.revision + 2, phase: .recovery,
            state: original.state, transaction: transaction, step: try stop.step(),
            latestReceiptDigest: observation.digest, readinessCommit: nil, recoveryReason: .readinessFailed)
        try result.validate(profile: validationProfile)
        return result
    }
    static func stop(after ready: InstallationReadinessMessage, control: InstallationControlRecord,
                     deadline: MonotonicDeadline) throws -> InstallationReadinessMessage {
        guard !deadline.hasExpired, ready.event == .ready, ready.controlRevision <= UInt64.max - 4,
              control.revision == ready.controlRevision + 4, control.phase == .recovery,
              control.readinessCommit == nil, control.step?.action == .candidateStop,
              control.step?.status == .intent, control.step?.ordinal == 16,
              control.transaction?.id == ready.transactionID, control.transaction?.boot == ready.boot,
              control.transaction?.candidate?.release.releaseContractSHA256 == ready.candidateReleaseDigest,
              try control.state.digest() == ready.stateBindingDigest else { throw CustodyRecordError.fenced }
        return InstallationReadinessMessage(event: .stop, transactionID: ready.transactionID,
            boot: ready.boot, controlRevision: control.revision, candidateReleaseDigest: ready.candidateReleaseDigest,
            stateBindingDigest: ready.stateBindingDigest, hostGeneration: ready.hostGeneration,
            sessionNonce: ready.sessionNonce, previousMessageDigest: try ready.digest())
    }
    static func stopped(after stop: InstallationReadinessMessage,
                        deadline: MonotonicDeadline) throws -> InstallationReadinessMessage {
        guard !deadline.hasExpired, stop.event == .stop else { throw CustodyRecordError.fenced }
        return InstallationReadinessMessage(event: .stopped, transactionID: stop.transactionID,
            boot: stop.boot, controlRevision: stop.controlRevision, candidateReleaseDigest: stop.candidateReleaseDigest,
            stateBindingDigest: stop.stateBindingDigest, hostGeneration: stop.hostGeneration,
            sessionNonce: stop.sessionNonce, previousMessageDigest: try stop.digest())
    }
}
