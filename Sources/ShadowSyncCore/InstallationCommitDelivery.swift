import Foundation

/// Value-only ordering shared with fixtures. This contains no socket, journal,
/// ReadyObservation or authority. Session state holds it under its own mutex.
struct InstallationCommitDeliveryState {
    private enum Phase { case idle, submitted, sending, delivered, terminal }
    private var phase: Phase = .idle
    mutating func submit() throws {
        guard phase == .idle else { throw CustodyRecordError.fenced }
        phase = .submitted
    }
    mutating func begin() throws {
        guard phase == .submitted else { throw CustodyRecordError.fenced }
        phase = .sending
    }
    mutating func finish() throws {
        guard phase == .sending else { throw CustodyRecordError.fenced }
        phase = .delivered
    }
    mutating func cancel() { phase = .terminal }
    mutating func fail() { phase = .terminal }
}

/// Pure frame construction, not send permission. The session additionally
/// requires the actual journal's identity-bound one-shot delivery capability.
enum InstallationCommitDeliveryBinding {
    static func message(ready: InstallationReadinessMessage, committed: InstallationControlRecord,
                        deadline: MonotonicDeadline,
                        validationProfile: InstallationValidationProfile = .production) throws -> InstallationReadinessMessage {
        try ready.validate(); try committed.validate(profile: validationProfile)
        guard !deadline.hasExpired, let transaction = committed.transaction,
              let commit = committed.readinessCommit, ready.event == .ready,
              ready.transactionID == transaction.id, ready.boot == transaction.boot,
              ready.candidateReleaseDigest == commit.candidateReleaseDigest,
              ready.stateBindingDigest == commit.stateBindingDigest,
              ready.hostGeneration == commit.host.generation else { throw CustodyRecordError.fenced }
        let message = InstallationReadinessMessage(event: .commit, transactionID: ready.transactionID,
            boot: ready.boot, controlRevision: committed.revision,
            candidateReleaseDigest: ready.candidateReleaseDigest, stateBindingDigest: ready.stateBindingDigest,
            hostGeneration: ready.hostGeneration, sessionNonce: ready.sessionNonce,
            previousMessageDigest: try ready.digest())
        try InstallationHostCommitBinding.validateMessage(message, ready: ready, committed: committed, deadline: deadline)
        return message
    }
}
