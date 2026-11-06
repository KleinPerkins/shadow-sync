import AppKit
import Darwin
import ShadowSyncCore
import Foundation

enum AppLifecyclePhaseKind:
    String, CaseIterable, Equatable, Sendable {
    case idle
    case chooser
    case savingDefaults
    case bindingSelection
    case hydratingSelected
    case onboardingAuthority
    case cardsAndReview
    case executing
    case cancelling
    case drainingForQuit
}

struct AppLifecyclePhase: Equatable, Sendable {
    let kind: AppLifecyclePhaseKind
    let generation: UInt64
    let controllerID: ObjectIdentifier?
    let selectedRepositoryIDs: Set<String>

    static let idle = AppLifecyclePhase(
        kind: .idle,
        generation: 0,
        controllerID: nil,
        selectedRepositoryIDs: []
    )
}

struct AppDrainEvidence: Equatable, Sendable {
    var processAdmissionClosed = false
    var ownedTasksSettled = false
    var allChildrenReaped = false
    var workerPostReapVerified = false
    var workerOwnershipSettled = false
    var body3WorkersTerminal = false
    var confirmationWaitersSettled = false
    var inventoryAuthorityReleased = false
    var operationAuthorityReleased = false
    var lifecycleAuthorityReleased = false
    var transactionsSettled = false
    var preferenceOutcomeRecorded = false
    var generation: UInt64 = 0

    mutating func accountForRetainedCommands(_ retained: Bool) {
        guard retained else { return }
        ownedTasksSettled = false; allChildrenReaped = false
        inventoryAuthorityReleased = false; operationAuthorityReleased = false; transactionsSettled = false
    }

    static func noWork(generation: UInt64) -> AppDrainEvidence {
        AppDrainEvidence(
            processAdmissionClosed: true,
            ownedTasksSettled: true,
            allChildrenReaped: true,
            workerPostReapVerified: true,
            workerOwnershipSettled: true,
            body3WorkersTerminal: true,
            confirmationWaitersSettled: true,
            inventoryAuthorityReleased: true,
            operationAuthorityReleased: true,
            lifecycleAuthorityReleased: true,
            transactionsSettled: true,
            preferenceOutcomeRecorded: true,
            generation: generation
        )
    }
}

final class SelectedHydrationDrainTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var hydrationStarted = false
    private var authorityCycles = 0
    private var settledAuthorityCycles = 0
    private var activeChildCount = 0
    private var invalidSequence = false

    func markCustodyPending() {
        lock.lock(); hydrationStarted = true; invalidSequence = true; lock.unlock()
    }

    func markHydrationStarted() {
        lock.lock()
        hydrationStarted = true
        lock.unlock()
    }

    func observe(_ event: RepositoryInventoryLifecycleEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .authorityAcquired:
            guard authorityCycles == settledAuthorityCycles else {
                invalidSequence = true
                return
            }
            authorityCycles += 1
            activeChildCount = 0
        case let .childStarted(count, _):
            guard authorityCycles == settledAuthorityCycles + 1,
                  count == activeChildCount + 1 else {
                invalidSequence = true
                return
            }
            activeChildCount = count
        case let .finished(childCount),
             let .failed(childCount),
             let .cancelled(childCount):
            guard authorityCycles == settledAuthorityCycles + 1,
                  childCount == activeChildCount else {
                invalidSequence = true
                return
            }
            settledAuthorityCycles += 1
            activeChildCount = 0
        case .repositoryStarted, .repositoryProgress,
             .cleanupProgress:
            break
        }
    }

    func evidenceAfterTaskCompletion(
        generation: UInt64
    ) -> AppDrainEvidence {
        lock.lock()
        let started = hydrationStarted
        let settled =
            !invalidSequence
            && authorityCycles > 0
            && authorityCycles == settledAuthorityCycles
        lock.unlock()
        guard started else {
            return .noWork(generation: generation)
        }
        var evidence = AppDrainEvidence.noWork(generation: generation)
        if !settled {
            evidence.allChildrenReaped = false
            evidence.inventoryAuthorityReleased = false
            evidence.transactionsSettled = false
        }
        return evidence
    }
}

enum AppDrainBarrierVerdict: Equatable, Sendable {
    case satisfied
    case blocked([String])
}

enum AppDrainBarrier {
    static func evaluate(
        _ evidence: AppDrainEvidence,
        quitGeneration: UInt64
    ) -> AppDrainBarrierVerdict {
        var missing: [String] = []
        if evidence.generation != quitGeneration {
            missing.append("quit-generation")
        }
        for (ready, label) in [
            (evidence.processAdmissionClosed, "admission"),
            (evidence.ownedTasksSettled, "tasks"),
            (evidence.allChildrenReaped, "children"),
            (evidence.workerPostReapVerified, "worker-post-reap"),
            (evidence.workerOwnershipSettled, "worker-ownership"),
            (evidence.body3WorkersTerminal, "body3"),
            (evidence.confirmationWaitersSettled, "confirmations"),
            (evidence.inventoryAuthorityReleased, "inventory-authority"),
            (evidence.operationAuthorityReleased, "operation-authority"),
            (evidence.lifecycleAuthorityReleased, "lifecycle-authority"),
            (evidence.transactionsSettled, "transactions"),
            (evidence.preferenceOutcomeRecorded, "preferences"),
        ] where !ready {
            missing.append(label)
        }
        return missing.isEmpty ? .satisfied : .blocked(missing)
    }
}

enum AppLifecycleRouteResult: Equatable {
    case accepted(UInt64)
    case ignored
    case terminate
    case quitPaused([String])
}

@MainActor
final class AppLifecycleRouter {
    private(set) var phase: AppLifecyclePhase = .idle
    private(set) var deferredQuit = false
    private(set) var drainEvidence = AppDrainEvidence.noWork(
        generation: 0
    )
    private var generation: UInt64 = 0
    private var phaseBeforeQuit: AppLifecyclePhase?
    private var terminationIssuedGeneration: UInt64?
    private(set) var lastPreferenceRenameLinearized: Bool?

    func decideLegacyAction(
        _ action: LifecycleGateAction,
        state: LifecycleGateSnapshot
    ) -> LifecycleGateDecision {
        LifecycleGate.decide(action, from: state)
    }

    func decideRecoveryStart(
        from evidence: RecoveryStartEvidence
    ) -> LifecycleGateDecision {
        LifecycleGate.decideRecoveryStart(from: evidence)
    }

    @discardableResult
    func showChooser(controller: NSWindowController)
        -> AppLifecycleRouteResult {
        guard phase.kind == .idle
                || phase.kind == .cardsAndReview
                || phase.kind == .chooser else {
            return .ignored
        }
        generation &+= 1
        phase = AppLifecyclePhase(
            kind: .chooser,
            generation: generation,
            controllerID: ObjectIdentifier(controller),
            selectedRepositoryIDs: []
        )
        drainEvidence = .noWork(generation: generation)
        deferredQuit = false
        phaseBeforeQuit = nil
        terminationIssuedGeneration = nil
        lastPreferenceRenameLinearized = nil
        return .accepted(generation)
    }

    @discardableResult
    func beginSave(
        generation expected: UInt64,
        controller: NSWindowController
    ) -> AppLifecycleRouteResult {
        guard accepts(
            .chooser,
            generation: expected,
            controller: controller
        ) else {
            return .ignored
        }
        phase = AppLifecyclePhase(
            kind: .savingDefaults,
            generation: expected,
            controllerID: ObjectIdentifier(controller),
            selectedRepositoryIDs: []
        )
        drainEvidence.preferenceOutcomeRecorded = false
        drainEvidence.ownedTasksSettled = false
        lastPreferenceRenameLinearized = nil
        return .accepted(expected)
    }

    func completeSave(
        generation expected: UInt64,
        renameLinearized: Bool,
        controller: NSWindowController?
    ) -> AppLifecycleRouteResult {
        guard phase.generation == expected,
              activePhaseKind == .savingDefaults else {
            return .ignored
        }
        // The drain barrier requires an observed outcome, not a successful
        // rename. A pre-rename failure owns no pending transaction, while this
        // value preserves whether persistence actually linearized.
        lastPreferenceRenameLinearized = renameLinearized
        drainEvidence.preferenceOutcomeRecorded = true
        drainEvidence.ownedTasksSettled = true
        if deferredQuit {
            return serviceDeferredQuit(generation: expected)
        }
        phase = AppLifecyclePhase(
            kind: .chooser,
            generation: expected,
            controllerID: controller.map(ObjectIdentifier.init),
            selectedRepositoryIDs: []
        )
        return .accepted(expected)
    }

    @discardableResult
    func beginContinue(
        generation expected: UInt64,
        controller: NSWindowController,
        selectedRepositoryIDs: Set<String>
    ) -> AppLifecycleRouteResult {
        guard !selectedRepositoryIDs.isEmpty,
              accepts(
                  .chooser,
                  generation: expected,
                  controller: controller
              ) else {
            return .ignored
        }
        phase = AppLifecyclePhase(
            kind: .bindingSelection,
            generation: expected,
            controllerID: ObjectIdentifier(controller),
            selectedRepositoryIDs: selectedRepositoryIDs
        )
        drainEvidence = AppDrainEvidence(
            processAdmissionClosed: false,
            ownedTasksSettled: false,
            allChildrenReaped: true,
            workerPostReapVerified: true,
            workerOwnershipSettled: true,
            body3WorkersTerminal: true,
            confirmationWaitersSettled: true,
            inventoryAuthorityReleased: true,
            operationAuthorityReleased: true,
            lifecycleAuthorityReleased: true,
            transactionsSettled: true,
            preferenceOutcomeRecorded: true,
            generation: expected
        )
        return .accepted(expected)
    }

    func enterHydration(generation expected: UInt64)
        -> AppLifecycleRouteResult {
        transition(
            from: .bindingSelection,
            to: .hydratingSelected,
            generation: expected
        )
    }

    func enterOnboarding(generation expected: UInt64)
        -> AppLifecycleRouteResult {
        let result = transition(
            from: .hydratingSelected,
            to: .onboardingAuthority,
            generation: expected
        )
        if case .accepted = result {
            drainEvidence.ownedTasksSettled = true
            drainEvidence.inventoryAuthorityReleased = true
        }
        return deferredQuit
            ? serviceDeferredQuit(generation: expected)
            : result
    }

    func enterCards(generation expected: UInt64)
        -> AppLifecycleRouteResult {
        guard phase.generation == expected,
              phase.kind == .hydratingSelected
                || phase.kind == .onboardingAuthority else {
            return .ignored
        }
        phase = AppLifecyclePhase(
            kind: .cardsAndReview,
            generation: expected,
            controllerID: nil,
            selectedRepositoryIDs: phase.selectedRepositoryIDs
        )
        drainEvidence.ownedTasksSettled = true
        drainEvidence.inventoryAuthorityReleased = true
        return deferredQuit
            ? serviceDeferredQuit(generation: expected)
            : .accepted(expected)
    }

    func settleHydrationFailure(
        generation expected: UInt64,
        controller: NSWindowController?,
        evidence: AppDrainEvidence
    ) -> AppLifecycleRouteResult {
        guard phase.generation == expected,
              evidence.generation == expected,
              phase.kind == .hydratingSelected
                || phase.kind == .bindingSelection
                || phase.kind == .cancelling
                || phase.kind == .drainingForQuit else {
            return .ignored
        }
        drainEvidence = evidence
        if deferredQuit {
            return serviceDeferredQuit(generation: expected)
        }
        if case let .blocked(missing) = AppDrainBarrier.evaluate(
            evidence,
            quitGeneration: expected
        ) {
            // The hydration task has completed, so no later callback can
            // strengthen this receipt. Retain the active phase and closed
            // admission as the terminal fail-closed Needs Attention state;
            // a new run must not overwrite unverified ownership evidence.
            return .quitPaused(missing)
        }
        phase = AppLifecyclePhase(
            kind: .chooser,
            generation: expected,
            controllerID: controller.map(ObjectIdentifier.init),
            selectedRepositoryIDs: []
        )
        return .accepted(expected)
    }

    func beginExecution(generation expected: UInt64)
        -> AppLifecycleRouteResult {
        transition(
            from: .cardsAndReview,
            to: .executing,
            generation: expected
        )
    }

    func beginCancel(generation expected: UInt64)
        -> AppLifecycleRouteResult {
        guard phase.generation == expected,
              [
                  .bindingSelection, .hydratingSelected,
                  .onboardingAuthority, .executing,
              ].contains(phase.kind) else {
            return .ignored
        }
        phase = AppLifecyclePhase(
            kind: .cancelling,
            generation: expected,
            controllerID: phase.controllerID,
            selectedRepositoryIDs: phase.selectedRepositoryIDs
        )
        drainEvidence.processAdmissionClosed = true
        return .accepted(expected)
    }

    func settleOwnedWork(
        generation expected: UInt64,
        evidence: AppDrainEvidence
    ) -> AppLifecycleRouteResult {
        guard phase.generation == expected,
              evidence.generation == expected else {
            return .ignored
        }
        drainEvidence = evidence
        if deferredQuit {
            return serviceDeferredQuit(generation: expected)
        }
        if phase.kind == .cancelling {
            phase = AppLifecyclePhase(
                kind: .idle,
                generation: expected,
                controllerID: nil,
                selectedRepositoryIDs: []
            )
        }
        return .accepted(expected)
    }

    func settleExecution(
        generation expected: UInt64,
        evidence: AppDrainEvidence
    ) -> AppLifecycleRouteResult {
        guard phase.generation == expected,
              evidence.generation == expected,
              activePhaseKind == .executing
                || activePhaseKind == .cancelling else {
            return .ignored
        }
        drainEvidence = evidence
        if deferredQuit {
            return serviceDeferredQuit(generation: expected)
        }
        guard case .satisfied = AppDrainBarrier.evaluate(
            evidence,
            quitGeneration: expected
        ) else {
            return .accepted(expected)
        }
        phase = AppLifecyclePhase(
            kind: .idle,
            generation: expected,
            controllerID: nil,
            selectedRepositoryIDs: []
        )
        return .accepted(expected)
    }

    func requestQuit(
        evidence: AppDrainEvidence? = nil
    ) -> AppLifecycleRouteResult {
        let quitGeneration = phase.generation
        if let evidence {
            guard evidence.generation == quitGeneration else {
                return .ignored
            }
            drainEvidence = evidence
        }
        deferQuit()
        return serviceDeferredQuit(generation: quitGeneration)
    }

    func deferQuit() {
        guard !deferredQuit else { return }
        deferredQuit = true
        phaseBeforeQuit = phase
        phase = AppLifecyclePhase(
            kind: .drainingForQuit,
            generation: phase.generation,
            controllerID: phase.controllerID,
            selectedRepositoryIDs: phase.selectedRepositoryIDs
        )
        drainEvidence.processAdmissionClosed = true
    }

    func cancelDeferredQuit() {
        guard deferredQuit else { return }
        deferredQuit = false
        if let phaseBeforeQuit {
            phase = phaseBeforeQuit
        }
        phaseBeforeQuit = nil
    }

    private func serviceDeferredQuit(
        generation expected: UInt64
    ) -> AppLifecycleRouteResult {
        guard deferredQuit, phase.generation == expected else {
            return .ignored
        }
        switch AppDrainBarrier.evaluate(
            drainEvidence,
            quitGeneration: expected
        ) {
        case .satisfied:
            guard terminationIssuedGeneration != expected else {
                return .ignored
            }
            return .terminate
        case let .blocked(missing):
            return .quitPaused(missing)
        }
    }

    func consumeTermination(generation expected: UInt64) -> Bool {
        guard deferredQuit,
              phase.generation == expected,
              terminationIssuedGeneration != expected,
              AppDrainBarrier.evaluate(
                  drainEvidence,
                  quitGeneration: expected
              ) == .satisfied else {
            return false
        }
        terminationIssuedGeneration = expected
        deferredQuit = false
        phaseBeforeQuit = nil
        return true
    }

    private func accepts(
        _ kind: AppLifecyclePhaseKind,
        generation expected: UInt64,
        controller: NSWindowController
    ) -> Bool {
        phase.kind == kind
            && phase.generation == expected
            && phase.controllerID == ObjectIdentifier(controller)
    }

    private var activePhaseKind: AppLifecyclePhaseKind {
        if phase.kind == .drainingForQuit,
           let phaseBeforeQuit {
            return phaseBeforeQuit.kind
        }
        return phase.kind
    }

    private func transition(
        from: AppLifecyclePhaseKind,
        to: AppLifecyclePhaseKind,
        generation expected: UInt64
    ) -> AppLifecycleRouteResult {
        guard phase.kind == from,
              phase.generation == expected else {
            return .ignored
        }
        phase = AppLifecyclePhase(
            kind: to,
            generation: expected,
            controllerID: phase.controllerID,
            selectedRepositoryIDs: phase.selectedRepositoryIDs
        )
        return .accepted(expected)
    }
}

#if SHADOW_SYNC_TESTING
private struct V3LifecycleProbeRequest: Codable {
    let schema: String
}

private struct V3LifecycleProbeResponse: Codable {
    let schema: String
    let independentDrainCuts: Int
    let saveLinearizationBeforeQuit: Bool
    let saveFailureOutcomeBeforeQuit: Bool
    let staleCallbackIgnored: Bool
    let doubleAdmissionRejected: Bool
    let continueIntentFailureRecovered: Bool
    let hydrationDrainEvidenceExact: Bool
    let exactlyOnceTermination: Bool
}

@MainActor
enum V3LifecycleProbeDriver {
    private static let mode =
        "--shadow-sync-v3-lifecycle-probe-channel"

    static func dispatch(arguments: [String]) -> Int32? {
        guard arguments.count >= 2, arguments[1] == mode else {
            return nil
        }
        guard arguments.count == 3,
              let descriptor = Int32(arguments[2]),
              descriptor >= 0,
              fcntl(descriptor, F_GETFD) >= 0 else {
            return 2
        }
        do {
            let request = try JSONLineChannel.readOne(
                V3LifecycleProbeRequest.self,
                descriptor: descriptor
            )
            guard request.schema
                    == "shadow-sync-v3-lifecycle-probe/v1" else {
                return 2
            }
            let labels: [(WritableKeyPath<AppDrainEvidence, Bool>, String)] = [
                (\.processAdmissionClosed, "admission"),
                (\.ownedTasksSettled, "tasks"),
                (\.allChildrenReaped, "children"),
                (\.workerPostReapVerified, "worker-post-reap"),
                (\.workerOwnershipSettled, "worker-ownership"),
                (\.body3WorkersTerminal, "body3"),
                (\.confirmationWaitersSettled, "confirmations"),
                (\.inventoryAuthorityReleased, "inventory-authority"),
                (\.operationAuthorityReleased, "operation-authority"),
                (\.lifecycleAuthorityReleased, "lifecycle-authority"),
                (\.transactionsSettled, "transactions"),
                (\.preferenceOutcomeRecorded, "preferences"),
            ]
            var independentCuts = 0
            for (keyPath, label) in labels {
                let router = AppLifecycleRouter()
                let controller = NSWindowController()
                guard case let .accepted(generation) =
                        router.showChooser(controller: controller) else {
                    return 2
                }
                var evidence = AppDrainEvidence.noWork(
                    generation: generation
                )
                evidence[keyPath: keyPath] = false
                router.deferQuit()
                guard case let .quitPaused(missing) =
                        router.settleOwnedWork(
                            generation: generation,
                            evidence: evidence
                        ),
                      missing == [label] else {
                    return 2
                }
                independentCuts += 1
            }

            let saveRouter = AppLifecycleRouter()
            let saveController = NSWindowController()
            guard case let .accepted(saveGeneration) =
                    saveRouter.showChooser(
                        controller: saveController
                    ),
                  case .accepted = saveRouter.beginSave(
                      generation: saveGeneration,
                      controller: saveController
                  ) else {
                return 2
            }
            var saving = AppDrainEvidence.noWork(
                generation: saveGeneration
            )
            saving.ownedTasksSettled = false
            saving.preferenceOutcomeRecorded = false
            guard case .quitPaused =
                    saveRouter.requestQuit(evidence: saving) else {
                return 2
            }
            let saveLinearized: Bool
            if case .terminate = saveRouter.completeSave(
                generation: saveGeneration,
                renameLinearized: true,
                controller: saveController
            ), saveRouter.lastPreferenceRenameLinearized == true {
                saveLinearized = true
            } else {
                saveLinearized = false
            }

            let failedSaveRouter = AppLifecycleRouter()
            let failedSaveController = NSWindowController()
            guard case let .accepted(failedSaveGeneration) =
                    failedSaveRouter.showChooser(
                        controller: failedSaveController
                    ),
                  case .accepted = failedSaveRouter.beginSave(
                      generation: failedSaveGeneration,
                      controller: failedSaveController
                  ) else {
                return 2
            }
            var failedSaving = AppDrainEvidence.noWork(
                generation: failedSaveGeneration
            )
            failedSaving.ownedTasksSettled = false
            failedSaving.preferenceOutcomeRecorded = false
            guard case .quitPaused =
                    failedSaveRouter.requestQuit(evidence: failedSaving) else {
                return 2
            }
            let saveFailureRecorded =
                failedSaveRouter.completeSave(
                    generation: failedSaveGeneration,
                    renameLinearized: false,
                    controller: failedSaveController
                ) == .terminate
                && failedSaveRouter.lastPreferenceRenameLinearized == false

            let routeRouter = AppLifecycleRouter()
            let routeController = NSWindowController()
            guard case let .accepted(routeGeneration) =
                    routeRouter.showChooser(
                        controller: routeController
                    ),
                  case .accepted = routeRouter.beginContinue(
                      generation: routeGeneration,
                      controller: routeController,
                      selectedRepositoryIDs: ["owner/repository"]
                  ) else {
                return 2
            }
            let staleIgnored =
                routeRouter.enterHydration(
                    generation: routeGeneration &+ 1
                ) == .ignored
            let doubleRejected =
                routeRouter.beginContinue(
                    generation: routeGeneration,
                    controller: routeController,
                    selectedRepositoryIDs: ["owner/repository"]
                ) == .ignored
            let settledIntentFailure: Bool
            if case .accepted = routeRouter.settleHydrationFailure(
                generation: routeGeneration,
                controller: routeController,
                evidence: .noWork(generation: routeGeneration)
            ) {
                settledIntentFailure = true
            } else {
                settledIntentFailure = false
            }
            let chooserReopened =
                routeRouter.phase.kind == .chooser
            let retryAfterIntentFailure: Bool
            if case .accepted = routeRouter.beginContinue(
                generation: routeGeneration,
                controller: routeController,
                selectedRepositoryIDs: ["owner/repository"]
            ) {
                retryAfterIntentFailure = true
            } else {
                retryAfterIntentFailure = false
            }
            let intentFailureRecovered =
                settledIntentFailure
                && chooserReopened
                && retryAfterIntentFailure

            let incompleteHydration = SelectedHydrationDrainTracker()
            incompleteHydration.markHydrationStarted()
            incompleteHydration.observe(.authorityAcquired)
            incompleteHydration.observe(
                .childStarted(count: 1, phase: "git_read")
            )
            let incompleteEvidence =
                incompleteHydration.evidenceAfterTaskCompletion(
                    generation: routeGeneration
                )
            let completedHydration = SelectedHydrationDrainTracker()
            completedHydration.markHydrationStarted()
            completedHydration.observe(.authorityAcquired)
            completedHydration.observe(
                .childStarted(count: 1, phase: "git_read")
            )
            completedHydration.observe(.failed(childCount: 1))
            let completedEvidence =
                completedHydration.evidenceAfterTaskCompletion(
                    generation: routeGeneration
                )
            let cancelDrainRouter = AppLifecycleRouter()
            let cancelDrainController = NSWindowController()
            guard case let .accepted(cancelDrainGeneration) =
                    cancelDrainRouter.showChooser(
                        controller: cancelDrainController
                    ),
                  case .accepted = cancelDrainRouter.beginContinue(
                      generation: cancelDrainGeneration,
                      controller: cancelDrainController,
                      selectedRepositoryIDs: ["owner/repository"]
                  ),
                  case .accepted = cancelDrainRouter.enterHydration(
                      generation: cancelDrainGeneration
                  ),
                  case .accepted = cancelDrainRouter.beginCancel(
                      generation: cancelDrainGeneration
                  ) else {
                return 2
            }
            var blockedCancelEvidence = incompleteEvidence
            blockedCancelEvidence.generation = cancelDrainGeneration
            let cancelDrainRoute =
                cancelDrainRouter.settleHydrationFailure(
                    generation: cancelDrainGeneration,
                    controller: cancelDrainController,
                    evidence: blockedCancelEvidence
                )
            let cancelDrainBlocked: Bool
            if case .quitPaused = cancelDrainRoute {
                cancelDrainBlocked =
                    cancelDrainRouter.phase.kind == .cancelling
            } else {
                cancelDrainBlocked = false
            }
            let pendingPolicy = SelectedHydrationDrainTracker()
            pendingPolicy.markCustodyPending()
            let pendingPolicyEvidence = pendingPolicy.evidenceAfterTaskCompletion(generation: routeGeneration)
            var retainedPolicyEvidence = AppDrainEvidence.noWork(generation: routeGeneration)
            retainedPolicyEvidence.accountForRetainedCommands(true)
            let hydrationDrainEvidenceExact =
                AppDrainBarrier.evaluate(
                    incompleteEvidence,
                    quitGeneration: routeGeneration
                ) == .blocked([
                    "children",
                    "inventory-authority",
                    "transactions",
                ])
                && AppDrainBarrier.evaluate(
                    completedEvidence,
                    quitGeneration: routeGeneration
                ) == .satisfied
                && cancelDrainBlocked
                && AppDrainBarrier.evaluate(retainedPolicyEvidence, quitGeneration: routeGeneration) != .satisfied
                && !retainedPolicyEvidence.allChildrenReaped && !retainedPolicyEvidence.operationAuthorityReleased
                && AppDrainBarrier.evaluate(pendingPolicyEvidence, quitGeneration: routeGeneration) == .blocked([
                    "children", "inventory-authority", "transactions",
                ])

            let quitRouter = AppLifecycleRouter()
            let quitController = NSWindowController()
            guard case let .accepted(quitGeneration) =
                    quitRouter.showChooser(
                        controller: quitController
                    ) else {
                return 2
            }
            let ready = AppDrainEvidence.noWork(
                generation: quitGeneration
            )
            let once =
                quitRouter.requestQuit(evidence: ready) == .terminate
                    && quitRouter.consumeTermination(
                        generation: quitGeneration
                    )
                    && quitRouter.requestQuit(evidence: ready)
                        == .ignored

            try JSONLineChannel.write(
                V3LifecycleProbeResponse(
                    schema:
                        "shadow-sync-v3-lifecycle-probe-result/v1",
                    independentDrainCuts: independentCuts,
                    saveLinearizationBeforeQuit: saveLinearized,
                    saveFailureOutcomeBeforeQuit:
                        saveFailureRecorded,
                    staleCallbackIgnored: staleIgnored,
                    doubleAdmissionRejected: doubleRejected,
                    continueIntentFailureRecovered:
                        intentFailureRecovered,
                    hydrationDrainEvidenceExact:
                        hydrationDrainEvidenceExact,
                    exactlyOnceTermination: once
                ),
                descriptor: descriptor
            )
            return 0
        } catch {
            return 2
        }
    }
}
#endif
