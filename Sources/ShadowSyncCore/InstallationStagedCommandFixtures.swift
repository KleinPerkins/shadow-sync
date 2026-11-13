#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

enum InstallationStagedCommandFixtures {
    typealias H = InstallationStorageFixtures
    private static func until(_ stage: String, _ predicate: () throws -> Bool) throws {
        let deadline = MonotonicDeadline(seconds: 8)
        while try !predicate() {
            guard !deadline.hasExpired else { throw H.Failure(message: "staged command retirement deadline \(stage)") }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
    static func transportAndClosure() throws {
        try pendingRetirement()
        try failedAdmission()
        try catalogFences()
        try wrongRequests()
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
            var context: CommandCustodyContext? = try .testingStaged(admission, intent: intent, root: root)
            weak var released = context
            let control = intent.binding.control
            do {
                let command = try context!.testingStagedLifecycle(.bootstrap)
                try command.revalidate()
                let request = command.resources.request
                try H.check(request.authority == .installationStagedStart && request.kind == .launchctlMutation,
                            "staged start transport mode")
                try H.check(request.inputSHA256 == CustodyRecordBinding.digest(intent.binding.encode()), "staged input digest")
                try H.check(Set(request.descriptors.map(\.role)) == [.request, .control, .status, .state, .namespace,
                    .lifecycle, .operation, .input, .workingDirectory], "staged descriptor closure")
                try H.refuses { _ = try context!.testingStagedLifecycle(.kickstart) }
                try H.refuses { _ = try context!.testingStagedLifecycle(.bootout) }
                try H.refuses { _ = try context!.prepareSystemConfiguration(budget: .make(kind: .systemGitConfig, workSeconds: 5), cancellation: CancellationToken()) }
                // A synthetic helper cannot enter the production coordinator
                // adapter even with enough typed authority to seal a request.
                try H.refuses { _ = try context!.prepareLifecycle(.bootstrap) }
                let expired = try CustodyBudget.make(kind: .launchctlRead, workSeconds: 0.001, now: 1)
                do {
                    _ = try context!.prepare(.serviceStatus, budget: expired)
                    throw H.Failure(message: "expired staged diagnostic budget accepted")
                } catch CustodyProtocolError.invalidBudget {}
            }
            let initialCatalog = try context!.testingScope.testingRead()
            let result = try registry.start(context!.testingInstallationDiagnostic()).wait()
            try H.check(result.phase == .finished && result.journal?.authority == .installationStagedStart,
                        "staged helper did not complete disposable diagnostic")
            try until("diagnostic-retirement") { registry.testingCount == 0 }
            let advanced = try context!.testingScope.testingRead()
            try H.check(advanced.revision > initialCatalog.revision && advanced.entries.isEmpty,
                        "diagnostic did not advance and retire command catalog")
            try context!.testingRevalidate()
            // A later mutation must still join the original installation intent
            // after the diagnostic has advanced the command catalog.
            try serialMutation(context!, registry: registry, location: location, operation: .bootstrap)
            let after = try InstallationControlRecord.decode(Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json")))
            try H.check(after == control && after.step?.status == .intent && after.readinessCommit == nil,
                        "command result became installation completion")
            context!.close()
            try H.refuses { _ = try context!.testingInstallationDiagnostic() }
            context = nil
            try until("context-release") { released == nil && registry.testingOriginalHelpersReaped }
            try H.check(released == nil, "staged command retained caller")
            let closed = try admission.closeStarts()
            _ = try registry.installationStagedStartRetirement(after: closed)
        }
    }
    private static func pendingRetirement() throws {
        for mutation in [false, true] {
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
            let context = try CommandCustodyContext.testingStaged(admission, intent: intent, root: root)
            defer { context.close() }
            registry.testingDeferNextRead(.outputUntilReleased)
            let budget = try CustodyBudget.make(kind: mutation ? .launchctlMutation : .launchctlRead,
                workSeconds: 2, termSeconds: 0.2, killSeconds: 0.2, receiptSeconds: 0.2)
            let command = try mutation ? context.testingStagedLifecycle(.bootstrap, budget: budget)
                : context.testingInstallationDiagnostic(budget: budget)
            let handle = try registry.start(command)
            defer { registry.testingReleaseDeferredRead(handle) }
            try until("pending-output-proof") {
                guard let state = registry.testingReadObservation(handle) else { return false }
                return state.terminalReceived && state.statusEOF && state.reapedObservations > 0 && !state.outputEOF
            }
            let result = handle.wait()
            try H.check(result.phase == .cleanupPending && registry.testingCount == 1, "staged terminal bypassed EOF retirement")
            try H.refuses { _ = try context.testingInstallationDiagnostic() }
            try H.refuses { _ = try admission.closeStarts() }
            try InstallationOwnershipFixtures.excluded(location)
            registry.testingReleaseDeferredRead(handle)
            try until("pending-output-retirement") { registry.testingCount == 0 }
            try H.check(context.testingScope.observation == .terminal, "staged pending scope did not retire")
            try unchangedIntent(intent.binding, location: location)
            try H.check(registry.testingOriginalHelpersReaped && !registry.hasRetainedWork,
                        "staged EOF case retained helper or reservation")
        }
        }
    }
    static func stopTransport() throws {
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            let retirement = try registry.installationStagedStartRetirement(after: admission.closeStarts())
            let stop = try admission.stopOnly(after: retirement)
            let intent = try journal.candidateStopIntent(admission: stop, deadline: .init(seconds: 3))
            let context = try CommandCustodyContext.testingStaged(stop, intent: intent, root: root)
            defer { context.close() }
            let command = try context.testingStagedLifecycle(.bootout)
            try command.revalidate()
            try H.check(command.resources.request.authority == .installationStagedStop, "stop transport mode")
            try H.refuses { _ = try context.testingStagedLifecycle(.bootstrap) }
            try H.refuses { _ = try context.testingStagedLifecycle(.kickstart) }
            let result = try registry.start(context.testingInstallationDiagnostic()).wait()
            try H.check(result.phase == .finished && result.journal?.authority == .installationStagedStop,
                        "staged stop helper diagnostic failed")
            try until("stop-diagnostic-retirement") { registry.testingCount == 0 }
            try context.testingRevalidate()
            try H.check(intent.binding.control.step?.status == .intent, "stop diagnostic invented exit")
            try serialMutation(context, registry: registry, location: location, operation: .bootout)
            try unchangedIntent(intent.binding, location: location)
        }
    }
    private static func unchangedIntent(_ binding: InstallationCommandBinding, location: StateLocation) throws {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json"))
        let control = try InstallationControlRecord.decode(bytes)
        try H.check(control == binding.control && control.step?.status == .intent && control.readinessCommit == nil,
                    "staged command changed durable installation intent")
    }
    private static func serialMutation(_ context: CommandCustodyContext, registry: RetainedCleanupRegistry,
                                       location: StateLocation, operation: LifecycleLaunchCommand.Operation) throws {
        let command = try context.testingStagedLifecycle(operation)
        let request = command.resources.request
        let handle = try registry.start(command)
        try H.refuses { _ = try registry.start(command) }
        let result = handle.wait()
        try until("mutation-retirement") { registry.testingCount == 0 && registry.testingOriginalHelpersReaped }
        guard let journal = result.journal else { throw H.Failure(message: "staged mutation terminal missing") }
        let lines = String(decoding: result.stderr, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let markers = lines.filter { $0.hasPrefix("shadow-sync-fixture-serial:") }.map { $0.split(separator: ":").map(String.init) }
        try H.check(markers.allSatisfy { $0.count == 4 && Int($0[1]) != nil && UInt32($0[3]) != nil },
                    "invalid staged serial marker")
        let resumed = markers.filter { $0[2] == "resumed" }, retired = markers.filter { $0[2] == "retired" }
        try H.check(resumed.map { $0[1] } == ["0", "1", "2"] && retired.map { $0[1] } == ["0", "1"],
                    "staged mutation did not run all three serial children")
        for index in 1...2 {
            let previous = markers.firstIndex { $0[1] == String(index - 1) && $0[2] == "retired" }
            let next = markers.firstIndex { $0[1] == String(index) && $0[2] == "resumed" }
            try H.check(previous != nil && next != nil && previous! < next!, "staged predecessor not retired before successor")
        }
        let raw: UInt32 = operation == .bootout ? 113 << 8 : 0
        try H.check(result.phase == .finished && result.reason == nil && journal.phase == .terminal
            && journal.kind == .launchctlMutation && journal.authority == request.authority
            && journal.binding == CustodyRecordBinding(request.binding) && journal.budget == request.budget
            && journal.ordinal == 5 && journal.reason == CustodyReason.none && journal.waitStatus == raw
            && journal.outcome == (operation == .bootout ? .commandFailed : .completed),
                    "staged mutation lost exact authority, binding, budget or actual child status")
        let account = try EffectiveAccount.isolated(homeDirectory: location.anchorPath + "/home")
        let launch = LifecycleLaunchCommand(operation: operation, account: account)
        let cleanError = Data(lines.filter { !$0.hasPrefix("shadow-sync-fixture-serial:") }.joined(separator: "\n").utf8)
        try launch.validatePostflight(launch.state(waitStatus: Int32(raw), stdout: result.stdout, stderr: cleanError))
        let catalog = try context.testingScope.testingRead()
        try H.check(catalog.entries.isEmpty && !registry.hasRetainedWork, "staged mutation not fully retired")
        let receiptPath = location.path + "/custody/receipts/" + request.binding.requestID + ".caller.json"
        let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: receiptPath))) as? [String: Any]
        try H.check(receipt?["event"] as? String == "custodian-reaped", "staged caller did not reap helper")
        try context.testingRevalidate()
        // Use a NEW sealed request after retirement: a duplicate Prepared value
        // alone would only test its local claim bit, not the intent's reservation.
        let replay = try context.testingStagedLifecycle(operation)
        try H.check(replay.resources.request.binding.requestID != request.binding.requestID, "replay reused request ID")
        try H.refuses { _ = try context.testingScope.prepare(replay.resources.request) }
        try H.check(context.testingScope.observation == .pending
            && (try context.testingScope.testingRead()) == catalog && registry.testingCount == 0,
                    "staged intent admitted a second mutation after full retirement")
        try H.refuses { _ = try registry.start(command) }
    }
    private static func failedAdmission() throws {
        try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
            let context = try CommandCustodyContext.testingStaged(admission, intent: intent, root: root)
            defer { context.close() }
            let command = try context.testingStagedLifecycle(.bootstrap)
            let retry = try context.testingStagedLifecycle(.bootstrap)
            registry.testingFault(.beforeSpawn)
            let handle = try registry.start(command)
            try until("failed-admission-retirement") { registry.testingCount == 0 }
            // Entry removal precedes the queued terminal publication. Join that
            // actual result under the handle's original receipt deadline.
            let result = handle.wait()
            do {
                try H.check(result.phase == .finished && result.journal?.outcome == .admissionRefused
                    && result.journal?.reason == .startFailure && result.journal?.authority == .installationStagedStart
                    && result.journal?.kind == .launchctlMutation && result.stdout.isEmpty && result.stderr.isEmpty,
                            "staged pre-spawn failure did not retire refused mutation")
            } catch {
                // Preserve the failed snapshot and assertion. Only after failure,
                // observe whether the injection was reached and join the already
                // queued publication turn; neither observation can make this pass.
                let faultPending = registry.testingFaultIsPending(.beforeSpawn)
                let afterQueue = handle.snapshot()
                func fields(_ value: CustodyRegistryResult) -> String {
                    "phase=\(value.phase),reason=\(value.reason?.rawValue ?? "nil"),"
                        + "journal=\(value.journal != nil),outcome=\(value.journal?.outcome?.rawValue ?? "nil"),"
                        + "journalReason=\(value.journal?.reason?.rawValue ?? "nil"),"
                        + "authority=\(value.journal?.authority.rawValue ?? "nil"),kind=\(value.journal?.kind.rawValue ?? "nil"),"
                        + "stdoutBytes=\(value.stdout.count),stderrBytes=\(value.stderr.count)"
                }
                throw H.Failure(message: "staged pre-spawn failure did not retire refused mutation; "
                    + "observation-v1 initial[\(fields(result))] afterQueue[\(fields(afterQueue))] "
                    + "beforeSpawnFaultPending=\(faultPending)")
            }
            let catalog = try context.testingScope.testingRead()
            try H.check(catalog.entries.isEmpty && registry.testingOriginalHelpersReaped && !registry.hasRetainedWork,
                        "failed staged admission retained resources")
            try H.refuses { _ = try registry.start(command) }
            try H.refuses { _ = try context.testingScope.prepare(retry.resources.request) }
            try H.refuses { _ = try context.testingStagedLifecycle(.bootstrap) }
            try H.check((try context.testingScope.testingRead()) == catalog, "failed staged admission allowed retry")
            try unchangedIntent(intent.binding, location: location)
            // The durable intent also cannot mint a replacement same-owner scope.
            try H.refuses { _ = try CommandCustodyContext.testingStaged(admission, intent: intent, root: root) }
        }
    }
    private static func wrongRequests() throws {
        for defect in ["mode", "action"] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                _ = try journal.completeAdmission(deadline: .init(seconds: 3))
                let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
                let context = try CommandCustodyContext.testingStaged(admission, intent: intent, root: root)
                defer { context.close() }
                let request = try context.testingStagedLifecycle(.bootstrap).resources.request
                let wrong = UnvalidatedCustodyRequest(binding: request.binding, kind: request.kind,
                    authority: defect == "mode" ? .installationStagedStop : request.authority,
                    arguments: defect == "action" ? ["kickstart", "gui/\(geteuid())/\(InstallationPaths.label)"] : request.arguments,
                    environment: request.environment, budget: request.budget, stdoutLimit: request.stdoutLimit,
                    stderrLimit: request.stderrLimit, inputSHA256: request.inputSHA256,
                    resourcesSHA256: request.resourcesSHA256, descriptors: request.descriptors)
                let catalog = try context.testingScope.testingRead()
                try H.refuses { _ = try context.testingScope.prepare(wrong) }
                try H.check((try context.testingScope.testingRead()) == catalog && registry.testingCount == 0,
                            "wrong staged request reserved command")
                try unchangedIntent(intent.binding, location: location)
            }
        }
    }
    private static func catalogFences() throws {
        // These are deliberate metadata-only reservations: no process is spawned
        // and no synthetic record serves as runtime retirement evidence.
        for defect in ["foreign", "foreign-terminal", "expired", "draining", "cleanup-pending"] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                _ = try journal.completeAdmission(deadline: .init(seconds: 3))
                let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
                let context = try CommandCustodyContext.testingStaged(admission, intent: intent, root: root)
                defer { context.close() }
                let budget = try CustodyBudget.make(kind: .launchctlRead, workSeconds: defect == "expired" ? 2 : 10)
                let command = try context.testingInstallationDiagnostic(budget: budget)
                let scope = context.testingScope
                let ticket = try scope.prepare(command.resources.request)
                try context.testingRevalidate() // A live own reservation is permitted.
                if defect.hasPrefix("foreign") {
                    var record = ticket.testingJournal
                    if defect == "foreign-terminal" {
                        record = try record.advancing(to: .terminal, outcome: .admissionRefused, reason: .startFailure)
                    }
                    guard case .object(var fields) = record.wire,
                          case .object(var binding) = fields["binding"] else { throw H.Failure(message: "foreign fixture shape") }
                    binding["scope"] = .string(RunIdentity.make()); fields["binding"] = .object(binding)
                    let foreign = try CustodyJournal.decode(CustodyWire.encode(.object(fields), maximum: CustodyJournal.maximumBytes))
                    let catalog = try scope.testingRead()
                    let bytes = try CustodyWire.encode(.object([
                        "schema": .string("shadow-sync-custody-catalog/v1"),
                        "initialized": .string("shadow-sync-custody-initialized/v1"),
                        "revision": .unsigned(catalog.revision), "entries": .array([CustodyCatalogEntry(foreign).wire]),
                    ]), maximum: CustodyCatalog.maximumBytes)
                    try fixtureWrite(foreign.encode(), path: location.path + "/custody/" + ticket.requestID + ".json")
                    try fixtureWrite(bytes, path: location.path + "/custody/catalog.json")
                } else if defect == "expired" {
                    // ChildProcessBudget scales this synthetic command budget.
                    // Wait for that existing absolute expiry, as expiredScope
                    // does, rather than comparing it to an unrelated 8s wait.
                    let expiry = budget.work, now = DispatchTime.now().uptimeNanoseconds
                    if now < expiry { Thread.sleep(forTimeInterval: Double(expiry - now) / 1_000_000_000 + 0.02) }
                    try H.check(DispatchTime.now().uptimeNanoseconds >= expiry, "staged reservation has not expired")
                } else {
                    let draining = try ticket.testingJournal.advancing(to: .draining)
                    try scope.testingAdvance(ticket, to: draining)
                    if defect == "cleanup-pending" { try scope.testingAdvance(ticket, to: draining.advancing(to: .cleanupPending)) }
                }
                let before = try Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/catalog.json"))
                try H.refuses { try context.testingRevalidate() }
                try H.refuses { _ = try context.testingStagedLifecycle(.bootstrap) }
                try H.check(registry.testingCount == 0 && !registry.hasRetainedWork
                    && (try Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/catalog.json"))) == before,
                            "staged catalog fence mutated or admitted work")
                try unchangedIntent(intent.binding, location: location)
            }
        }
    }
    private static func fixtureWrite(_ bytes: Data, path: String) throws {
        // Only already-created, owner-private fixture metadata is replaced.
        let fd = open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw H.Failure(message: "fixture metadata open") }
        defer { close(fd) }
        var info = stat()
        try H.check(fstat(fd, &info) == 0 && info.st_uid == geteuid() && info.st_mode == S_IFREG | 0o600
            && info.st_nlink == 1, "fixture metadata identity")
        try H.check(ftruncate(fd, 0) == 0, "fixture metadata truncate")
        try bytes.withUnsafeBytes { raw in
            try H.check(Darwin.write(fd, raw.baseAddress, raw.count) == raw.count && fsync(fd) == 0,
                        "fixture metadata persistence")
        }
    }
    static func ownersAndCandidate() throws {
        try InstallationStagedJournalFixtures.fixture { _, _, _, _, _, journal, _ in
            _ = try journal.completeAdmission(deadline: .init(seconds: 3))
            let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
            try InstallationStagedJournalFixtures.fixture { root, _, _, _, other, _, _ in
                try H.refuses { _ = try CommandCustodyContext.testingStaged(other, intent: intent, root: root) }
            }
        }
        for stopMode in [false, true] {
            try InstallationStagedJournalFixtures.fixture { root, _, _, _, admission, journal, registry in
                _ = try journal.completeAdmission(deadline: .init(seconds: 3))
                let context: CommandCustodyContext
                if stopMode {
                    let retired = try registry.installationStagedStartRetirement(after: admission.closeStarts())
                    let stop = try admission.stopOnly(after: retired)
                    context = try .testingStaged(stop, intent: journal.candidateStopIntent(admission: stop, deadline: .init(seconds: 3)), root: root)
                } else {
                    context = try .testingStaged(admission, intent: journal.bootstrapCandidateIntent(deadline: .init(seconds: 3)), root: root)
                }
                defer { context.close() }
                let path = root + "/home/Library/LaunchAgents/" + InstallationPaths.label + ".plist"
                try FileManager.default.moveItem(atPath: path, toPath: root + "/held-plist")
                try FileManager.default.copyItem(atPath: root + "/held-plist", toPath: path)
                try H.refuses { try context.testingRevalidate() }
                try H.refuses { _ = try context.testingInstallationDiagnostic() }
                try H.check(registry.testingCount == 0, "candidate mismatch reserved command")
            }
        }
    }
    static func helperSubstitution() throws {
        for target in ["control", "receipt", "candidate"] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                _ = try journal.completeAdmission(deadline: .init(seconds: 3))
                let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
                let context = try CommandCustodyContext.testingStaged(admission, intent: intent, root: root)
                defer { context.close() }
                let command = try context.testingInstallationDiagnostic("after-admit")
                // Resource-only fixture entry omits caller revalidation after
                // preparation: refusal must come from the actual custodian.
                let handle = try registry.start(resources: command.resources, helper: command.helper)
                let commandPath = location.path + "/custody/" + command.resources.request.binding.requestID + ".json"
                try until("helper-admitted") {
                    guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: commandPath)),
                          let record = try? CustodyJournal.decode(bytes) else { return false }
                    return record.phase == .admitted
                }
                let path = target == "control" ? location.path + "/custody/installation.json"
                    : target == "candidate" ? root + "/home/Library/LaunchAgents/" + InstallationPaths.label + ".plist"
                    : location.path + "/custody/receipts/" + intent.binding.receiptNodes.keys.sorted().first!
                let retained = root + "/held-helper-evidence"
                try FileManager.default.moveItem(atPath: path, toPath: retained)
                try FileManager.default.copyItem(atPath: retained, toPath: path)
                let result = handle.wait()
                try until("helper-refusal-retirement") { registry.testingCount == 0 }
                try H.check(result.phase == .finished && result.journal?.outcome != .completed && result.stdout.isEmpty,
                            "staged helper resumed after substituted evidence")
                try FileManager.default.removeItem(atPath: path)
                try FileManager.default.moveItem(atPath: retained, toPath: path)
                try H.check(registry.testingOriginalHelpersReaped, "staged helper refusal leaked child")
            }
        }
    }
    static func changedEvidence() throws {
        for target in ["control", "receipt", "operation"] {
            try InstallationStagedJournalFixtures.fixture { root, location, _, _, admission, journal, registry in
                _ = try journal.completeAdmission(deadline: .init(seconds: 3))
                let intent = try journal.bootstrapCandidateIntent(deadline: .init(seconds: 3))
                let context = try CommandCustodyContext.testingStaged(admission, intent: intent, root: root)
                defer { context.close() }
                let path: String
                if target == "control" { path = location.path + "/custody/installation.json" }
                else if target == "operation" { path = location.path + "/operation.lock" }
                else { path = location.path + "/custody/receipts/" + intent.binding.receiptNodes.keys.sorted().first! }
                let prepared = try context.testingInstallationDiagnostic("after-admit")
                // Replace exact metadata after caller preparation. Caller must
                // refuse before admission; independently inherited validation is
                // exercised by the successful real-helper cases above.
                try FileManager.default.moveItem(atPath: path, toPath: root + "/held-" + target)
                try FileManager.default.copyItem(atPath: root + "/held-" + target, toPath: path)
                try H.refuses { try prepared.revalidate() }
                try H.check(registry.testingCount == 0, "changed evidence admitted command")
                // Restore only this fixture's exact retained original inode, so
                // outer exclusion probes inspect the lock we actually own.
                try FileManager.default.removeItem(atPath: path)
                try FileManager.default.moveItem(atPath: root + "/held-" + target, toPath: path)
            }
        }
    }
    // Metadata-only acceptance of closed wire shapes is deliberately separate
    // from actual owner minting and from the unqualified signed helper below.
    private static func committedWireRefuses(_ wire: PolicyWireValue) throws {
        do {
            _ = try InstallationCommandBinding.decode(CustodyWire.encode(wire, maximum: 65_536))
            throw H.Failure(message: "cross-variant committed wire accepted")
        } catch is CustodyRecordError {} catch is PolicyProtocolError {}
    }
    private static func metadataBinding(_ h: InstallationControlFixtures.Harness,
        committed: Bool) throws -> InstallationCommandBinding {
        var nodes: [String: InstallationNodeIdentity] = [:]
        for (index, receipt) in h.receipts.enumerated() {
            nodes[try receipt.filename(uid: h.state.directory.uid)] = InstallationControlFixtures.node(UInt64(index + 200))
        }
        return InstallationCommandBinding(control: h.record, controlNode: InstallationControlFixtures.node(100),
            receiptNodes: nodes, committedStopDeadline: committed ? MonotonicDeadline(seconds: 0.750).absoluteUptimeNanoseconds : nil)
    }
    static func committedBindingClosure() throws {
        var original = try InstallationControlFixtures.Harness()
        try original.throughReady(); try original.commitReady()
        let committed = original.record.readinessCommit
        for action in [InstallationAction.readinessCommit, .cleanupCoordination, .cleanupBackups, .cleanupIncoming] {
            for status in [InstallationStepStatus.intent, .complete] {
                if action == .readinessCommit && status == .intent { continue }
                var h = original
                if action != .readinessCommit {
                    for prior in [InstallationAction.cleanupCoordination, .cleanupBackups, .cleanupIncoming] {
                        try h.add(prior, status: .intent)
                        if prior == action && status == .intent { break }
                        try h.add(prior, status: .complete)
                        if prior == action { break }
                    }
                }
                try h.recover(.startupUncertain)
                let binding = try metadataBinding(h, committed: true)
                try H.check(try InstallationCommandBinding.decode(binding.encode()) == binding,
                    "committed stop lost canonical variant")
                try H.check(binding.control.readinessCommit == committed, "subordinate stop altered commit")
                try binding.validateStagedOperation(mode: .installationStagedStop, operation: .bootout)
                try H.refuses { try binding.validateStagedOperation(mode: .installationStagedStart, operation: .bootstrap) }
                try H.refuses { try binding.validateStagedOperation(mode: .installationStagedStop, operation: .kickstart) }
                try H.refuses { try metadataBinding(h, committed: false).validate() }
                for name in binding.receiptNodes.keys {
                    var nodes = binding.receiptNodes; nodes.removeValue(forKey: name)
                    try H.refuses { try InstallationCommandBinding(control: binding.control, controlNode: binding.controlNode,
                        receiptNodes: nodes, committedStopDeadline: binding.committedStopDeadline).validate() }
                }
                guard case var .object(wire) = binding.wire else { throw H.Failure(message: "committed wire shape") }
                wire["purpose"] = .string("candidate-start")
                try committedWireRefuses(.object(wire))
                wire["purpose"] = .string("committed-candidate-stop"); wire["schema"] = .string("shadow-sync-installation-command/v1")
                try committedWireRefuses(.object(wire))
            }
        }
        for status in [InstallationStepStatus.intent, .complete] {
            var h = original
            for action in [InstallationAction.cleanupCoordination, .cleanupBackups, .cleanupIncoming] { try h.pair(action) }
            try h.add(.finish, status: .intent)
            if status == .complete { try h.add(.finish, status: .complete) }
            // Even forged recovery wire around terminal metadata cannot decode.
            let recovered = InstallationControlRecord(revision: h.record.revision + 1, phase: .recovery,
                state: h.record.state, transaction: h.record.transaction, step: h.record.step,
                latestReceiptDigest: h.record.latestReceiptDigest, readinessCommit: h.record.readinessCommit,
                recoveryReason: .startupUncertain)
            let b = try metadataBinding(h, committed: true)
            try H.refuses { try InstallationCommandBinding(control: recovered, controlNode: b.controlNode,
                receiptNodes: b.receiptNodes, committedStopDeadline: b.committedStopDeadline).validate() }
        }
    }
    static func candidateReadyStopOrdinal() throws {
        var original = try InstallationControlFixtures.Harness()
        for action in [InstallationAction.reserve, .drainPrior, .stageApplication, .stagePlist, .retireApplication,
            .retirePlist, .retireCoordination, .translateState, .moveStateForward, .promoteApplication,
            .promotePlist, .openStagedAdmission, .bootstrapCandidate, .kickstartCandidate] { try original.pair(action) }
        let stopExpected = try InstallationReadinessStopBinding.expectedControl(after: original.record)
        var table = original
        try table.pair(.candidateReady); try table.recover(.readinessFailed); try table.add(.candidateStop, status: .intent)
        try H.check(stopExpected == table.record, "readiness stop framing differs from exact action table")
        let ready = InstallationReadinessMessage(event: .ready,
            transactionID: InstallationControlFixtures.uuid, boot: InstallationControlFixtures.boot,
            controlRevision: original.record.revision,
            candidateReleaseDigest: InstallationControlFixtures.otherSHA,
            stateBindingDigest: try original.state.digest(), hostGeneration: InstallationControlFixtures.generation,
            sessionNonce: String(repeating: "a", count: 32), previousMessageDigest: InstallationControlFixtures.sha)
        let deadline = MonotonicDeadline(seconds: 0.750)
        let message = try InstallationReadinessStopBinding.stop(after: ready, control: stopExpected, deadline: deadline)
        let stopped = try InstallationReadinessStopBinding.stopped(after: message, deadline: deadline)
        try H.check(try message.previousMessageDigest == ready.digest() && stopped.previousMessageDigest == message.digest()
            && message.event == .stop && stopped.event == .stopped,
            "readiness stop transcript did not retain the exact ready chain")
        try H.refuses { _ = try InstallationReadinessStopBinding.expectedControl(after: table.record) }
        try H.refuses { _ = try InstallationReadinessStopBinding.stopped(after: ready, deadline: deadline) }
        try H.refuses { _ = try InstallationReadinessStopBinding.stop(after: ready, control: original.record, deadline: deadline) }
        try H.refuses { _ = try InstallationReadinessStopBinding.stop(after: ready, control: stopExpected,
            deadline: MonotonicDeadline(uptimeNanoseconds: 0)) }
        var h = try InstallationControlFixtures.Harness()
        try h.throughReady(); try h.recover(.readinessFailed); try h.add(.candidateStop, status: .intent)
        let binding = try metadataBinding(h, committed: false)
        try binding.control.validateReceiptChain(h.receipts)
        try binding.validateStagedOperation(mode: .installationStagedStop, operation: .bootout)
        try H.check(binding.control.step?.ordinal == 16 && binding.receiptNodes.count == 31,
                    "candidate-ready stop ordinal not exactly derived")
        try H.refuses { try metadataBinding(h, committed: true).validate() }
        var early = try InstallationControlFixtures.Harness()
        try early.pair(.reserve)
        try H.refuses { try metadataBinding(early, committed: true).validate() }
        try H.check(try InstallationCommandBinding.decode(binding.encode()) == binding, "precommit variant changed")
    }
    static func committedOwnerRefusal() throws {
        try InstallationStagedJournalFixtures.fixture { root, location, owner, _, admission, journal, registry in
            _ = try journal.completeAdmission(deadline: .init(seconds: 0.750))
            let before = try Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json"))
            // Supply the real command fixture contract, then exercise the signed
            // helper's actual unauthenticated prerequisite. This is refusal
            // coverage only; no normal-started or stopped token is fabricated.
            _ = try TestIsolation.validateRoot(root)
            do {
                let path = root + "/home/.staged-completion-quiet"
                let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                try H.check(fd >= 0, "committed stop prerequisite marker create")
                defer { close(fd) }
                let bytes = Data("staged-completion-quiet/v1\n".utf8)
                try bytes.withUnsafeBytes {
                    try H.check(Darwin.write(fd, $0.baseAddress, $0.count) == $0.count && fsync(fd) == 0,
                                "committed stop prerequisite marker durability")
                }
            }
            for cut in [CommittedDrainCut.none, .lifecycleContender, .partialAlias] {
                do {
                    try authenticatedCommittedStopCustody(journal, admission: admission, registry: registry,
                                                          root: root, location: location, cut: cut)
                    throw H.Failure(message: "signed committed stop accepted an unauthenticated journal")
                } catch CustodyRecordError.fenced { }
            }
            let observation = journal.stoppedHostObservation()
            try H.check(observation.0 == nil && observation.1 == .notAttempted
                && journal.testingStopDeliveryProbe == nil && registry.testingCount == 0
                && owner.testingTerminalOwnership().operation == .notAttempted
                && (try Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json"))) == before,
                "committed stop prerequisite refusal changed actual custody or durable control")
            let retired = try registry.installationStagedStartRetirement(after: admission.closeStarts())
            let stop = try admission.stopOnly(after: retired)
            try H.refuses { _ = try journal.committedCandidateStop(admission: stop) }
            try H.refuses { _ = try journal.committedCandidateStop(admission: stop) }
            try H.check(try Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json")) == before,
                "noncommitted caller minted recovery or changed receipts")
            try InstallationOwnershipFixtures.excluded(location)
        }
    }
    /// Signed-driver seam only. It requires a genuinely authenticated committed
    /// journal, exact original admission and registry. It does not synthesize
    /// ready/normal/stopped tokens. Native launchd behavior remains unqualified.
    enum CommittedDrainCut { case none, lifecycleContender, partialAlias }
    @_silgen_name("shadowSyncTesting_authenticatedCommittedStopCustody")
    @inline(never)
    static func authenticatedCommittedStopCustody(_ journal: CustodyCatalogStore.InstallationStagedJournal,
        admission: InstallationStagedAdmission, registry: RetainedCleanupRegistry,
        root: String, location: StateLocation, cut: CommittedDrainCut = .none) throws {
        _ = try TestIsolation.validateRoot(root)
        let quiet = try PolicyAuthorityFile.read(path: root + "/home/.staged-completion-quiet",
            owner: geteuid(), maximumBytes: 32)
        try H.check(quiet.bytes == Data("staged-completion-quiet/v1\n".utf8), "signed driver omitted actual command fixture contract")
        let started = try journal.takeNormalStarted()
        let stopped = try journal.stopStartedHost(started)
        let retirement = try registry.installationStagedStartRetirement(after: admission.closeStarts())
        let stop = try admission.stopOnly(after: retirement)
        let capability = try journal.committedCandidateStop(admission: stop)
        let before = try Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json"))
        try H.check(capability.deadline.absoluteUptimeNanoseconds == stopped.deadline.absoluteUptimeNanoseconds,
                    "committed stop reset original candidate budget")
        try H.refuses { _ = try journal.committedCandidateStop(admission: stop) }
        var context: CommandCustodyContext? = try .testingCommittedStop(capability, root: root)
        try H.refuses { _ = try context!.testingStagedLifecycle(.bootstrap) }
        try H.refuses { _ = try context!.testingStagedLifecycle(.kickstart) }
        var command: PreparedCustodyCommand? = try context!.testingCommittedBootout()
        let handle = try registry.start(command!)
        let result = handle.wait()
        try H.check(result.phase == .finished, "actual committed command did not retire")
        let token = try handle.stagedCompletion()
        try H.refuses { _ = try journal.completeCommittedCandidateStop(capability, after: token) }
        context!.close(); context = nil
        try H.refuses { _ = try journal.completeCommittedCandidateStop(capability, after: token) }
        command = nil
        while registry.testingCount != 0 || !registry.testingOriginalHelpersReaped {
            guard !capability.deadline.hasExpired else { throw CustodyRecordError.busy }
            Thread.sleep(forTimeInterval: min(0.001, Double(capability.deadline.remainingMilliseconds) / 1_000))
        }
        _ = try journal.completeCommittedCandidateStop(capability, after: token)
        try H.refuses { _ = try journal.completeCommittedCandidateStop(capability, after: token) }
        try H.refuses { _ = try capability.commandPermit() }
        try H.check(try Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json")) == before,
                    "subordinate command appended an installation receipt")
        try InstallationOwnershipFixtures.excluded(location)
        let owner = journal.testingOwner
        if cut == .partialAlias {
            var alias: CustodyAuthorityLeaseSet? = try stop.retainStopLeases()
            alias!.testingFailNextDuplicate(after: 2, uncertain: true)
            try H.refuses { _ = try alias!.duplicate() }
            alias = nil
            try H.refuses { _ = try stop.closeStops(deadline: stopped.deadline) }
            try H.refuses { _ = try stop.retainStopLeases() }
            try InstallationOwnershipFixtures.excluded(location)
            try H.check(owner.testingTerminalOwnership().operation == .notAttempted,
                        "partial stopped alias retired original operation")
            return
        }
        let closed = try stop.closeStops(deadline: stopped.deadline)
        let stoppedRetirement = try registry.installationStagedStopRetirement(after: closed)
        let drain = try journal.committedCandidateDrain(retirement: stoppedRetirement, registry: registry)
        try H.refuses { _ = try journal.committedCandidateDrain(retirement: stoppedRetirement, registry: registry) }
        let intent = try journal.stoppedRecoveryIntent(after: drain)
        try H.refuses { _ = try journal.stoppedRecoveryIntent(after: drain) }
        try H.check(intent.deadline.absoluteUptimeNanoseconds == stopped.deadline.absoluteUptimeNanoseconds,
                    "stopped reentry reset candidate deadline")
        try InstallationOwnershipFixtures.excluded(location)
        try InstallationOwnershipFixtures.excluded(location, name: "lifecycle.lock")
        if cut == .lifecycleContender {
            let fd = open(location.path + "/lifecycle.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw H.Failure(message: "stopped lifecycle contender open") }
            let contender = OwnedFileDescriptor(fd)
            defer { contender.closeNow() }
            try H.check(flock(fd, LOCK_SH | LOCK_NB) == 0, "staged lifecycle contender not admitted")
            try H.refuses { _ = try owner.reenterStoppedRecovery(intent) }
            try H.refuses { _ = try owner.reenterStoppedRecovery(intent) }
            try InstallationOwnershipFixtures.excluded(location)
            try H.check(owner.testingTerminalOwnership().operation == .notAttempted,
                        "failed stopped reentry retired original operation")
            try H.check(contender.retireChecked() == .succeeded, "stopped contender close uncertain")
            return
        }
        let exclusive = try owner.reenterStoppedRecovery(intent)
        try exclusive.revalidate()
        try H.refuses { _ = try owner.reenterStoppedRecovery(intent) }
        try H.refuses { _ = try admission.retainStartLeases() }
        try H.refuses { _ = try stop.retainStopLeases() }
        try InstallationOwnershipFixtures.excluded(location)
        try InstallationOwnershipFixtures.excluded(location, name: "lifecycle.lock")
        try H.check(owner.testingTerminalOwnership().operation == .notAttempted,
                    "stopped exclusive attempted operation release")
        try H.check(try Data(contentsOf: URL(fileURLWithPath: location.path + "/custody/installation.json")) == before,
                    "bounded stopped continuation rewrote installation action")
    }

}
#endif
