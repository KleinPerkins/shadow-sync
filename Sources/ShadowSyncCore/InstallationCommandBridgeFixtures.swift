#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

enum InstallationCommandBridgeFixtures {
    typealias H = InstallationStorageFixtures
    typealias J = CustodyCatalogStore.InstallationJournalSession
    private static func fixture(_ body: (String, StateLocation, RunAuthority, InstallationTransactionOwner,
                                         InstallationBindingTestingSource, J) throws -> Void) throws {
        try InstallationOwnershipFixtures.fixture { root, location, original in
            for suffix in ["/home", "/home/Applications", "/home/Library", "/home/Library/LaunchAgents"] {
                try H.check(mkdir(root + suffix, 0o700) == 0, "bridge fixture parent for testingInstallationCandidate")
            }
            let owner = try InstallationTransactionOwner.testingConsume(original, root: root)
            let source = try InstallationBindingTestingSource(root: root,
                candidate: CustodyHelperExecutable.testingInstallationCandidate(),
                process: ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make()),
                boot: CustodyBootIdentity.current())
            try owner.testingSetBindingSource(source)
            let lifecycle = try InstallationLifecycle(paths: .isolated(root: root),
                launchAgent: InstallationSlotCaptureFixtures.NoCommands(), host: InstallationSlotCaptureFixtures.NoCommands())
            let journal = try owner.installationJournal(intent: .install, lifecycle: lifecycle)
            try body(root, location, original, owner, source, journal)
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    private static func reserve(_ journal: J) throws {
        _ = try journal.begin(deadline: MonotonicDeadline(seconds: 0.750))
        _ = try journal.completeReservation(deadline: MonotonicDeadline(seconds: 0.750))
    }
    private static func until(_ condition: () throws -> Bool) throws {
        let deadline = MonotonicDeadline(seconds: 8)
        while try !condition() {
            guard !deadline.hasExpired else { throw H.Failure(message: "bridge fixture convergence") }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
    private static func withRegistry(_ body: (RetainedCleanupRegistry) throws -> Void) throws {
        let registry = RetainedCleanupRegistry.testingInstance()
        do { try body(registry) }
        catch {
            registry.testingRequestCancellation()
            try until { registry.testingOriginalHelpersReaped }
            try registry.testingDispose()
            throw error
        }
        try until { registry.testingCount == 0 }
        try H.check(registry.testingOriginalHelpersReaped, "bridge helper not reaped")
        try registry.testingDispose()
    }
    private static func bytes(_ path: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
    private static func write(_ path: String, _ bytes: Data) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try H.check(fd >= 0, "bridge create replacement"); defer { close(fd) }
        try bytes.withUnsafeBytes { p in
            var offset = 0
            while offset < p.count {
                let n = Darwin.write(fd, p.baseAddress!.advanced(by: offset), p.count - offset)
                try H.check(n > 0, "bridge replacement bytes"); offset += n
            }
        }
        try H.check(fsync(fd) == 0, "bridge replacement durability")
    }
    static func completedCommand() throws {
        try fixture { root, location, original, owner, _, journal in
            try H.refuses { _ = try CommandCustodyContext.testingInstallation(owner, journal: journal, root: root) }
            _ = try journal.begin(deadline: MonotonicDeadline(seconds: 0.750))
            try H.refuses { _ = try CommandCustodyContext.testingInstallation(owner, journal: journal, root: root) }
            _ = try journal.completeReservation(deadline: MonotonicDeadline(seconds: 0.750))
            let control = try bytes(location.path + "/custody/installation.json")
            let context = try CommandCustodyContext.testingInstallation(owner, journal: journal, root: root)
            defer { context.close() }
            try H.refuses { _ = try original.retainCommandLeases() }
            try H.refuses { _ = try CommandCustodyContext.testingInstallation(owner, journal: journal, root: root) }
            try H.refuses { _ = try context.prepareLifecycle(.bootstrap) }
            try H.refuses { _ = try context.prepareLifecycle(.kickstart) }
            try H.refuses { _ = try context.prepareLifecycle(.bootout) }
            try H.refuses { _ = try context.prepare(.installedSignature) }
            let ordinary = try CustodyCatalogStore(leases: owner.retainExclusiveLeases())
            try H.refuses { try ordinary.checkFence(ownRequests: [], scope: context.id, mode: .lifecycleMutation) }
            try withRegistry { registry in
                let handle = try registry.start(context.testingInstallationDiagnostic())
                let result = handle.wait()
                try H.check(result.phase == .finished && result.journal?.outcome == .completed,
                            "testingInstallationDiagnostic owner command did not complete: \(result.phase) \(String(describing: result.reason))")
                try until { registry.testingCount == 0 }
                try H.check(context.testingScope.observation == .open, "completed diagnostic closed phase")
                let again = try registry.start(context.testingInstallationDiagnostic()).wait()
                try H.check(again.phase == .finished && again.journal?.outcome == .completed, "second diagnostic refused")
            }
            try H.check(try bytes(location.path + "/custody/installation.json") == control, "diagnostic changed installation control")
            try H.refuses { try ordinary.checkFence(ownRequests: [], scope: context.id, mode: .lifecycleMutation) }
            context.close()
            try H.refuses { _ = try context.testingInstallationDiagnostic() }
        }
    }
    static func wrongOwnerAndPublisher() throws {
        try fixture { root, _, _, owner, source, journal in
            try reserve(journal)
            try fixture { _, _, _, other, _, _ in
                try H.refuses { _ = try journal.commandPermit(for: other, deadline: MonotonicDeadline(seconds: 0.750)) }
            }
            let context = try CommandCustodyContext.testingInstallation(owner, journal: journal, root: root)
            defer { context.close() }
            try context.testingRevalidate()
            source.available = false
            try H.refuses { try context.testingRevalidate() }
            source.available = true
            try context.testingRevalidate()
            let old = source.identity
            let candidate = old.candidate
            let wrong = InstallationCandidate(release: candidate.release, bundleDigest: String(repeating: "b", count: 64),
                appCDHash: candidate.appCDHash, coordinatorCDHash: candidate.coordinatorCDHash)
            source.identity = try LifecyclePublisher.InstallationIdentity.testing(root: root, candidate: wrong)
            try H.refuses { try context.testingRevalidate() }
            source.identity = old
            try context.testingRevalidate()
            let transaction = try CustodyCatalogStore(leases: owner.retainExclusiveLeases()).testingInstallationRecord().transaction!
            let good = try CustodyHelperExecutable.testingCustodian()
            try good.validateInstallationPublisher(transaction)
            let wrongRelease = try CustodyHelperExecutable.testing(releaseSHA256: String(repeating: "a", count: 64))
            try H.refuses { try wrongRelease.validateInstallationPublisher(transaction) }
            try good.validateInstallationPublisher(transaction)
        }
    }
    static func durableSubstitution() throws {
        for attack in ["control", "receipt", "document", "unknown"] {
            try fixture { root, location, _, owner, _, journal in
                try reserve(journal)
                let context = try CommandCustodyContext.testingInstallation(owner, journal: journal, root: root)
                defer { context.close() }
                let command = try context.testingInstallationDiagnostic()
                try command.revalidate()
                let receipts = location.path + "/custody/receipts"
                let receipt = try FileManager.default.contentsOfDirectory(atPath: receipts).first { $0.hasPrefix(attack == "document" ? InstallationDocumentPreimage.prefix : InstallationStepReceipt.prefix) }!
                let target = attack == "control" ? location.path + "/custody/installation.json"
                    : attack == "receipt" || attack == "document" ? receipts + "/" + receipt : receipts + "/unknown.json"
                let retained = root + "/bridge-displaced"
                if attack == "unknown" { try write(target, Data("unknown".utf8)) }
                else {
                    let old = try bytes(target)
                    try H.check(rename(target, retained) == 0, "bridge displace")
                    try write(target, old)
                }
                try H.refuses { try command.revalidate() }
                try H.check(unlink(target) == 0, "bridge remove own replacement")
                if attack != "unknown" { try H.check(rename(retained, target) == 0, "bridge restore original") }
                try command.revalidate()
                try withRegistry { registry in
                    let result = try registry.start(command).wait()
                    try H.check(result.phase == .finished && result.journal?.outcome == .completed, "restored binding failed")
                }
            }
        }
    }
    static func closureAndPending() throws {
        try fixture { root, location, _, owner, _, journal in
            try reserve(journal)
            let context = try CommandCustodyContext.testingInstallation(owner, journal: journal, root: root)
            try withRegistry { registry in
                let budget = try CustodyBudget.make(kind: .launchctlRead, workSeconds: 2, termSeconds: 0.2, killSeconds: 0.2, receiptSeconds: 0.2)
                let handle = try registry.start(context.testingInstallationDiagnostic("resist", budget: budget))
                try until { !handle.snapshot().stdout.isEmpty }
                let before = try bytes(location.path + "/custody/installation.json")
                try H.refuses { _ = try journal.recordFailure(.commandPending, deadline: MonotonicDeadline(seconds: 0.750)) }
                try H.check(try bytes(location.path + "/custody/installation.json") == before, "live command changed control")
                try H.refuses { _ = try owner.closeBorrowing() }
                try H.check(!owner.commandAdmissionIsOpen, "failed close reopened borrowing")
                try H.refuses { _ = try context.testingInstallationDiagnostic() }
                context.close()
                handle.cancel()
                _ = handle.wait()
                try until { registry.testingCount == 0 }
                try H.check(context.testingScope.observation == .terminal, "registry did not retire scope")
                try H.refuses { _ = try owner.closeBorrowing() } // live journal/context still retain aliases
                try InstallationOwnershipFixtures.excluded(location)
            }
        }
    }
    static func helperRejectsChangedControl() throws {
        try fixture { root, location, _, owner, _, journal in
            try reserve(journal)
            let context = try CommandCustodyContext.testingInstallation(owner, journal: journal, root: root)
            defer { context.close() }
            let command = try context.testingInstallationDiagnostic("after-admit")
            try withRegistry { registry in
                // Existing resource-only TEST seam prevents caller revalidation
                // from satisfying this assertion: the helper must reject the cut.
                let handle = try registry.start(resources: command.resources, helper: command.helper)
                let path = location.path + "/custody/" + command.resources.request.binding.requestID + ".json"
                try until {
                    guard let data = try? bytes(path), let j = try? CustodyJournal.decode(data) else { return false }
                    return j.phase == .admitted
                }
                let target = location.path + "/custody/installation.json", retained = root + "/bridge-original-control"
                let data = try bytes(target)
                try H.check(rename(target, retained) == 0, "helper cut retain")
                try write(target, data)
                let result = handle.wait()
                try until { registry.testingCount == 0 }
                try H.check(result.phase == .finished && result.journal?.outcome != .completed && result.stdout.isEmpty,
                            "helper resumed target after identical control substitution")
                try H.check(unlink(target) == 0 && rename(retained, target) == 0, "helper cut restore")
                try InstallationOwnershipFixtures.excluded(location)
            }
        }
    }
    static func terminalIsNotRetirement() throws {
        try fixture { root, location, _, owner, _, journal in
            try reserve(journal)
            let context = try CommandCustodyContext.testingInstallation(owner, journal: journal, root: root)
            defer { context.close() }
            try withRegistry { registry in
                registry.testingDeferNextRead(.outputUntilReleased)
                let budget = try CustodyBudget.make(kind: .launchctlRead, workSeconds: 2, termSeconds: 0.2, killSeconds: 0.2, receiptSeconds: 0.2)
                let handle = try registry.start(context.testingInstallationDiagnostic(budget: budget))
                try until {
                    guard let value = registry.testingReadObservation(handle) else { return false }
                    return value.terminalReceived && value.statusEOF && value.reapedObservations > 0 && !value.outputEOF
                }
                try H.check(registry.testingCount == 1, "unread EOF retired registry")
                let pending = handle.wait()
                try H.check(pending.phase == .cleanupPending && registry.testingCount == 1,
                            "deadline claimed terminal without actual EOF")
                try H.refuses { _ = try journal.recordFailure(.commandPending, deadline: MonotonicDeadline(seconds: 0.750)) }
                try H.refuses { _ = try owner.closeBorrowing() }
                try H.refuses { _ = try context.testingInstallationDiagnostic() }
                try InstallationOwnershipFixtures.excluded(location)
                registry.testingReleaseDeferredRead(handle)
                try until { registry.testingCount == 0 }
                try H.check(context.testingScope.observation == .terminal, "pending retirement not completed by registry")
            }
        }
    }

    static func retirementAfterRelease() throws {
        try InstallationOwnershipFixtures.fixture { root, location, original in
            for suffix in ["/home", "/home/Applications", "/home/Library", "/home/Library/LaunchAgents"] {
                try H.check(mkdir(root + suffix, 0o700) == 0, "retirement fixture parent")
            }
            let owner = try InstallationTransactionOwner.testingConsume(original, root: root)
            let source = try InstallationBindingTestingSource(root: root,
                candidate: CustodyHelperExecutable.testingInstallationCandidate(),
                process: ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make()),
                boot: CustodyBootIdentity.current())
            try owner.testingSetBindingSource(source)
            let lifecycle = try InstallationLifecycle(paths: .isolated(root: root),
                launchAgent: InstallationSlotCaptureFixtures.NoCommands(), host: InstallationSlotCaptureFixtures.NoCommands())
            var journal: J? = try owner.installationJournal(intent: .install, lifecycle: lifecycle)
            try reserve(journal!)
            var context: CommandCustodyContext? = try .testingInstallation(owner, journal: journal!, root: root)
            try withRegistry { registry in
                let result = try registry.start(context!.testingInstallationDiagnostic()).wait()
                try H.check(result.phase == .finished && result.journal?.outcome == .completed, "retirement command failed")
                try until { registry.testingCount == 0 }
                try H.refuses { _ = try owner.closeBorrowing() }
                weak var releasedContext = context
                weak var releasedJournal = journal
                context!.close(); context = nil; journal = nil
                // close enqueues existing registry work that retains its scope.
                // Observe actual queue/reference release, never assume that an
                // empty catalog or assigning nil has released every alias.
                try until { registry.testingCount == 0 && releasedContext == nil && releasedJournal == nil }
                let closed = try owner.closeBorrowing()
                let retired = try registry.installationRetirement(after: closed)
                try retired.revalidate(for: owner)
                try H.refuses { _ = try owner.retainExclusiveLeases() }
                try H.refuses { _ = try original.retainCommandLeases() }
                try InstallationOwnershipFixtures.excluded(location)
            }
        }
    }

    static func sealedShape() throws {
        try fixture { _, _, _, owner, source, journal in
            try reserve(journal)
            let permit = try journal.commandPermit(for: owner, deadline: MonotonicDeadline(seconds: 0.750))
            let input = try permit.sealedInput(), binding = try InstallationCommandBinding.decode(input)
            try H.check(try binding.encode() == input, "canonical binding roundtrip")
            guard case var .object(wire) = binding.wire else { throw H.Failure(message: "binding fixture shape") }
            let stepsOnly = binding.receiptNodes.filter { $0.key.hasPrefix(InstallationStepReceipt.prefix) }
            try H.check(stepsOnly.count < binding.receiptNodes.count, "fixture has no document receipt")
            wire["receipts"] = .object(stepsOnly.mapValues(\.wire))
            try H.refuses { _ = try InstallationCommandBinding.decode(CustodyWire.encode(.object(wire), maximum: 65_536)) }
            try binding.validateParent(source.process, helper: CustodyHelperExecutable.testingCustodian())
            let wrong = ProcessIdentity(processID: source.process.processID, processGroupID: source.process.processGroupID,
                userID: source.process.userID, startSeconds: source.process.startSeconds + 1,
                startMicroseconds: source.process.startMicroseconds, executablePath: source.process.executablePath,
                generation: source.process.generation)
            try H.refuses { try binding.validateParent(wrong, helper: CustodyHelperExecutable.testingCustodian()) }
            try binding.validateParent(source.process, helper: CustodyHelperExecutable.testingCustodian())
        }
    }

}
#endif
