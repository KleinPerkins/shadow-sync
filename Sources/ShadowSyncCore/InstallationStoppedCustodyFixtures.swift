#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

/// Real consumed owners and actual aliases/registry. No candidate drain or
/// stopped-exclusive capability is constructed by these source fixtures.
enum InstallationStoppedCustodyFixtures {
    typealias H = InstallationStorageFixtures
    private static func marker() { fputs("M6 CLOSED STAGED STOP CUSTODY FIXTURE\n", stderr) }
    private static func fixture(_ body: (String, StateLocation, InstallationTransactionOwner,
        InstallationStagedAdmission, InstallationStagedStopAdmission,
        CustodyCatalogStore.InstallationStagedJournal, RetainedCleanupRegistry) throws -> Void) throws {
        marker()
        try InstallationStagedJournalFixtures.fixture { root, location, owner, _, admission, journal, registry in
            let stop = try admission.stopOnly(after: registry.installationStagedStartRetirement(after: admission.closeStarts()))
            try body(root, location, owner, admission, stop, journal, registry)
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    static func completionClosureReceipt() throws {
        try fixture { _, _, owner, _, stop, _, registry in
            var completion: CustodyAuthorityLeaseSet? = try owner.retainStagedCommandCompletionLeases(mode: .installationStagedStop)
            let receipt = completion!.checkedClosure
            var child: CustodyAuthorityLeaseSet? = try completion!.duplicate()
            try H.check(receipt.observation == .notAttempted, "live completion reported checked retirement")
            completion = nil
            try H.check(receipt.observation == .notAttempted, "held descendant reported completion retirement")
            let deadline = MonotonicDeadline(seconds: 3)
            try H.refuses { _ = try stop.closeStops(deadline: deadline) }
            child = nil
            try H.check(receipt.observation == .succeeded, "actual completion destructor lacked positive receipt")
            let closed = try stop.closeStops(deadline: deadline)
            try registry.installationStagedStopRetirement(after: closed).revalidate(for: owner, registry: registry)
        }
    }
    static func completionClosureUncertain() throws {
        try fixture { _, _, owner, _, stop, _, _ in
            var completion: CustodyAuthorityLeaseSet? = try owner.retainStagedCommandCompletionLeases(mode: .installationStagedStop)
            let receipt = completion!.checkedClosure
            var child: CustodyAuthorityLeaseSet? = try completion!.duplicate()
            try child!.testingUncertainInstallationClose()
            completion = nil
            try H.check(receipt.observation == .notAttempted, "held uncertain child retired its parent")
            child = nil
            try H.check(receipt.observation == .uncertain(EIO), "actual uncertain close was forgotten")
            try H.refuses { _ = try stop.closeStops(deadline: .init(seconds: 3)) }
            try H.check(receipt.observation == .uncertain(EIO), "reconciliation retried uncertain descriptor")
        }
    }
    static func completionClosurePartialCopy() throws {
        for uncertain in [false, true] {
            try fixture { _, _, owner, _, stop, _, registry in
                var completion: CustodyAuthorityLeaseSet? = try owner.retainStagedCommandCompletionLeases(mode: .installationStagedStop)
                let receipt = completion!.checkedClosure
                completion!.testingFailNextDuplicate(after: 2, uncertain: uncertain)
                try H.refuses { _ = try completion!.duplicate() }
                try H.check(receipt.observation == .notAttempted, "partial copy destroyed its live source")
                completion = nil
                try H.check(receipt.observation == (uncertain ? .uncertain(EIO) : .succeeded),
                            "positive completion receipt lost actual partial-copy close outcome")
                if uncertain { try H.refuses { _ = try stop.closeStops(deadline: .init(seconds: 3)) } }
                else {
                    let closed = try stop.closeStops(deadline: .init(seconds: 3))
                    try registry.installationStagedStopRetirement(after: closed).revalidate(for: owner, registry: registry)
                }
            }
        }
    }
    static func closedSessionHasNoStopDelivery() throws {
        try InstallationStagedJournalFixtures.fixture { _, location, owner, _, _, journal, registry in
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            try journal.closeReadiness(deadline: .init(seconds: 3))
            let observation = journal.stoppedHostObservation()
            try H.check(observation.0 == nil && observation.1 == .notAttempted,
                        "service closure manufactured authenticated stop retirement")
            try H.refuses { _ = try journal.takeNormalStarted() }
            // Exercise the real signed cut helper's prerequisite gate. A closed,
            // unauthenticated session must fail before installing any fault probe;
            // these refusals do not qualify any signed positive or cut execution.
            let controlPath = URL(fileURLWithPath: location.path + "/custody/installation.json")
            let controlBefore = try Data(contentsOf: controlPath)
            for cut in [InstallationStartupFixtures.StopRetirementCut.store, .completion, .heldCompletion] {
                do {
                    try InstallationStartupFixtures.authenticatedStopRetirementCut(journal, location: location, cut: cut)
                    throw H.Failure(message: "signed stop cut accepted a closed unauthenticated session")
                } catch CustodyRecordError.fenced { }
                let after = journal.stoppedHostObservation()
                try H.check(after.0 == nil && after.1 == .notAttempted
                    && journal.testingStopDeliveryProbe == nil && registry.testingCount == 0
                    && (try Data(contentsOf: controlPath)) == controlBefore,
                    "signed stop prerequisite refusal changed control, probe or actual custody")
            }
            try H.check(owner.testingTerminalOwnership().operation == .notAttempted,
                        "unstarted stop retirement released original operation")
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    static func closedProof() throws {
        try fixture { _, location, owner, admission, stop, journal, registry in
            var root: CustodyAuthorityLeaseSet? = try stop.retainStopLeases()
            var child: CustodyAuthorityLeaseSet? = try root!.duplicate()
            var descendant: CustodyAuthorityLeaseSet? = try child!.duplicate()
            weak var gone = root
            root = nil; child = nil
            let deadline = MonotonicDeadline(seconds: 3)
            try H.refuses { _ = try stop.closeStops(deadline: deadline) }
            try H.refuses { _ = try stop.retainStopLeases() }
            try H.refuses { _ = try admission.retainStartLeases() }
            try H.refuses { _ = try descendant!.duplicate() }
            try H.check(gone != nil, "descendant lost original stop family")
            descendant = nil
            try H.check(gone == nil, "last descendant failed to retire")
            let closed = try stop.closeStops(deadline: deadline)
            let retired = try registry.installationStagedStopRetirement(after: closed)
            try retired.revalidate(for: owner, registry: registry)
            // Actual checked alias + registry retirement alone is insufficient:
            // this journal has no authenticated stopped candidate or bootout.
            try H.refuses { _ = try journal.committedCandidateDrain(retirement: retired, registry: registry) }
            try H.refuses { _ = try journal.committedCandidateDrain(retirement: retired, registry: registry) }
            try H.refuses { _ = try journal.readinessCandidateDrain(retirement: retired, registry: registry) }
            try H.refuses { _ = try journal.stopReadinessOnlyHost(admission: stop) }
            try H.refuses { _ = try journal.readinessCandidateDrain(retirement: retired, registry: registry) }
            try InstallationOwnershipFixtures.excluded(location, name: "lifecycle.lock")
            try H.refuses { _ = try registry.installationStagedStopRetirement(after: closed) }
            try H.refuses { _ = try stop.closeStops(deadline: deadline) }
            try H.refuses { _ = try admission.closeStarts() }
            let original = owner.testingTerminalOwnership()
            try H.check(!original.attempted && original.operation == .notAttempted,
                        "closed stop proof attempted original operation release")
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    static func wrongBinding() throws {
        try fixture { _, _, owner, _, stop, _, registry in
            let closed = try stop.closeStops(deadline: .init(seconds: 3))
            let wrong = RetainedCleanupRegistry.testingInstance()
            try H.refuses { _ = try wrong.installationStagedStopRetirement(after: closed) }
            let token = try registry.installationStagedStopRetirement(after: closed)
            try H.refuses { try token.revalidate(for: owner, registry: wrong) }
            try InstallationOwnershipFixtures.fixture { root, _, authority in
                let other = try InstallationTransactionOwner.testingConsume(authority, root: root)
                try H.refuses { try token.revalidate(for: other, registry: registry) }
                try H.check(!closed.belongs(to: other), "closed family accepted another owner")
            }
            try token.revalidate(for: owner, registry: registry)
        }
    }
    static func completionAlias() throws {
        try fixture { _, _, owner, _, stop, _, registry in
            var completion: CustodyAuthorityLeaseSet? = try owner.retainStagedCommandCompletionLeases(mode: .installationStagedStop)
            var observation: CustodyAuthorityLeaseSet? = try completion!.duplicate()
            completion = nil
            let deadline = MonotonicDeadline(seconds: 3)
            try H.refuses { _ = try stop.closeStops(deadline: deadline) }
            try H.refuses { _ = try observation!.duplicate() }
            observation = nil
            let closed = try stop.closeStops(deadline: deadline)
            let token = try registry.installationStagedStopRetirement(after: closed)
            try token.revalidate(for: owner, registry: registry)
        }
    }
    static func uncertainAlias() throws {
        try fixture { _, _, owner, _, stop, _, _ in
            var root: CustodyAuthorityLeaseSet? = try stop.retainStopLeases()
            var child: CustodyAuthorityLeaseSet? = try root!.duplicate()
            weak var gone = root
            try child!.testingUncertainInstallationClose()
            root = nil; child = nil
            try H.check(gone == nil, "uncertain alias object did not unwind")
            try H.refuses { _ = try stop.closeStops(deadline: .init(seconds: 3)) }
            try H.refuses { _ = try stop.retainStopLeases() }
            try H.refuses { try owner.validateStagedCommandAliasesRetired() }
        }
    }
    static func partialDuplicates() throws {
        for uncertain in [false, true] {
            try fixture { _, _, owner, _, stop, _, registry in
                var root: CustodyAuthorityLeaseSet? = try stop.retainStopLeases()
                root!.testingFailNextDuplicate(after: 2, uncertain: uncertain)
                try H.refuses { _ = try root!.duplicate() }
                weak var gone = root
                root = nil
                try H.check(gone == nil, "partial duplicate retained unexplained family")
                if uncertain {
                    try H.refuses { _ = try stop.closeStops(deadline: .init(seconds: 3)) }
                } else {
                    let closed = try stop.closeStops(deadline: .init(seconds: 3))
                    let token = try registry.installationStagedStopRetirement(after: closed)
                    try token.revalidate(for: owner, registry: registry)
                }
            }
        }
    }
    private static func until(_ predicate: () throws -> Bool) throws {
        let deadline = MonotonicDeadline(seconds: 8)
        while try !predicate() {
            guard !deadline.hasExpired else { throw H.Failure(message: "closed stop fixture retirement pending") }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
    static func uncertainResource() throws { try actualRegistryArchives(uncertain: true) }
    static func actualRegistryArchives(uncertain: Bool = false) throws {
        marker()
        try InstallationStagedJournalFixtures.fixture { root, location, owner, _, admission, journal, registry in
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            _ = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
            let stop = try admission.stopOnly(after: registry.installationStagedStartRetirement(after: admission.closeStarts()))
            let recovery = try journal.beginStartRecovery(admission: stop, deadline: .init(seconds: 3))
            var context: CommandCustodyContext? = try .testingRecovery(recovery, root: root)
            var prepared: PreparedCustodyCommand? = try context!.testingInstallationDiagnostic("installation-absent")
            if uncertain { try prepared!.resources.testingUncertainStagedResourceClose() }
            let handle = try registry.start(prepared!)
            let actual = handle.wait()
            guard actual.phase == .finished, let archive = actual.journal else {
                throw H.Failure(message: "actual stopped registry command did not retire")
            }
            let commandRetired = try handle.stagedRecoveryRetirement()
            try H.refuses { try owner.validateStagedCommandAliasesRetired() }
            prepared = nil; context!.close(); context = nil
            try until { (try? commandRetired.validate()) != nil }
            _ = try journal.reconcileStart(recovery, after: commandRetired, deadline: .init(seconds: 3))
            try journal.closeReadiness(deadline: .init(seconds: 3))
            let closed = try stop.closeStops(deadline: .init(seconds: 3))
            if uncertain {
                try H.refuses { _ = try registry.installationStagedStopRetirement(after: closed) }
                try H.refuses { _ = try registry.installationStagedStopRetirement(after: closed) }
                try InstallationOwnershipFixtures.excluded(location)
                return
            }
            let token = try registry.installationStagedStopRetirement(after: closed)
            try token.revalidate(for: owner, registry: registry)
            // Actual fsynced archive bytes, never a synthetic retirement token.
            let path = location.path + "/custody/receipts/" + archive.binding.requestID + ".caller.json"
            let fd = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw H.Failure(message: "closed stop archive open failed") }
            let descriptor = OwnedFileDescriptor(fd)
            var first: UInt8 = 0
            try H.check(pread(fd, &first, 1, 0) == 1, "closed stop archive read failed")
            var changed = first ^ 1
            try H.check(pwrite(fd, &changed, 1, 0) == 1 && fsync(fd) == 0, "closed stop archive fault failed")
            try H.refuses { try token.revalidate(for: owner, registry: registry) }
            try H.check(pwrite(fd, &first, 1, 0) == 1 && fsync(fd) == 0,
                        "closed stop fixture archive restoration failed")
            try H.check(descriptor.retireChecked() == .succeeded, "archive fixture close uncertain")
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    static func pendingCancellation() throws {
        marker()
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            _ = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
            let stop = try admission.stopOnly(after: registry.installationStagedStartRetirement(after: admission.closeStarts()))
            let recovery = try journal.beginStartRecovery(admission: stop, deadline: .init(seconds: 3))
            var context: CommandCustodyContext? = try .testingRecovery(recovery, root: root)
            registry.testingDeferNextRead(.outputUntilReleased)
            var prepared: PreparedCustodyCommand? = try context!.testingInstallationDiagnostic("installation-absent")
            let handle = try registry.start(prepared!)
            defer { registry.testingReleaseDeferredRead(handle) }
            try until {
                guard let observation = registry.testingReadObservation(handle) else { return false }
                return observation.terminalReceived && !observation.outputEOF
            }
            handle.cancel()
            try H.check(registry.hasRetainedWork, "cancellation fabricated registry retirement")
            try H.refuses { _ = try stop.closeStops(deadline: .init(seconds: 3)) }
            try H.refuses { _ = try stop.retainStopLeases() }
            registry.testingReleaseDeferredRead(handle)
            _ = handle.wait()
            prepared = nil; context!.close(); context = nil
            try until { registry.testingCount == 0 && registry.testingOriginalHelpersReaped }
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    static func originalDeadline() throws {
        try fixture { _, _, _, _, stop, _, _ in
            try H.refuses { _ = try stop.closeStops(deadline: .init(seconds: 0)) }
            try H.refuses { _ = try stop.closeStops(deadline: .init(seconds: 3)) }
            try H.refuses { _ = try stop.retainStopLeases() }
        }
    }
}
#endif
