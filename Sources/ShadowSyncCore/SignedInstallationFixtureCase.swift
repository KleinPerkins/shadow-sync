#if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
import Darwin
import Foundation

/// A finite scenario for one original guardian/root/bootstrap. This roster
/// includes only source-connected cases with separately owned fixture teardown.
/// Required pending-cut cases remain explicit unavailable coverage in discovery.
enum SignedInstallationFixtureCase: String, CaseIterable {
    case startupStop = "signed-installation/startup-stop"
    case stopStore = "signed-installation/stop-store-uncertain"
    case stopCompletion = "signed-installation/stop-completion-uncertain"
    case stopHeldCompletion = "signed-installation/stop-held-completion"
    case cleanupPositive = "signed-installation/cleanup-positive"
    case terminalPositive = "signed-installation/terminal-positive"

    case cleanupEndpointBeforeUnlink = "signed-installation/cleanup-endpoint/beforeUnlink"
    case cleanupEndpointUnlinkFailure = "signed-installation/cleanup-endpoint/unlinkFailure"
    case cleanupEndpointAfterUnlink = "signed-installation/cleanup-endpoint/afterUnlink"
    case cleanupEndpointParentSyncFailure = "signed-installation/cleanup-endpoint/parentSyncFailure"
    case cleanupEndpointAfterParentSync = "signed-installation/cleanup-endpoint/afterParentSync"
    case cleanupEndpointBeforeAncestorClose = "signed-installation/cleanup-endpoint/beforeAncestorClose"
    case cleanupPublicationAfterReceipt = "signed-installation/cleanup-publication/afterReceipt"
    case cleanupPublicationBeforeControl = "signed-installation/cleanup-publication/beforeControl"
    case cleanupPublicationReceiptBeforeSwap = "signed-installation/cleanup-publication/receiptBeforeSwap"
    case cleanupPublicationReceiptAfterSwap = "signed-installation/cleanup-publication/receiptAfterSwap"
    case cleanupPublicationReceiptAfterDirectorySync = "signed-installation/cleanup-publication/receiptAfterDirectorySync"
    case cleanupPublicationControlBeforeSwap = "signed-installation/cleanup-publication/controlBeforeSwap"
    case cleanupPublicationControlAfterSwap = "signed-installation/cleanup-publication/controlAfterSwap"
    case cleanupPublicationControlAfterDirectorySync = "signed-installation/cleanup-publication/controlAfterDirectorySync"
    case cleanupPublicationControlAfterPreimageUnlink = "signed-installation/cleanup-publication/controlAfterPreimageUnlink"
    case cleanupReaderAlias = "signed-installation/cleanup/reader-alias"
    case cleanupQueueJoin = "signed-installation/cleanup/queue-join"
    case cleanupControlReplacement = "signed-installation/cleanup/control-replacement"
    case cleanupNamedMissing = "signed-installation/cleanup/named-missing"
    case cleanupNamedSubstituted = "signed-installation/cleanup/named-substituted"
    case cleanupNamedCutAfterParking = "signed-installation/cleanup-named-cut/afterParking"
    case cleanupNamedCutAfterReplacementOpen = "signed-installation/cleanup-named-cut/afterReplacementOpen"
    case cleanupNamedCutAfterReplacementIdentity = "signed-installation/cleanup-named-cut/afterReplacementIdentity"
    case cleanupNamedCutAfterReplacementClose = "signed-installation/cleanup-named-cut/afterReplacementClose"
    case terminalPublicationCleanupBackupsIntentAfterReceipt = "signed-installation/terminal-publication/cleanupBackups/intent/afterReceipt"
    case terminalPublicationCleanupBackupsIntentBeforeControl = "signed-installation/terminal-publication/cleanupBackups/intent/beforeControl"
    case terminalPublicationCleanupBackupsIntentReceiptBeforeSwap = "signed-installation/terminal-publication/cleanupBackups/intent/receiptBeforeSwap"
    case terminalPublicationCleanupBackupsIntentReceiptAfterSwap = "signed-installation/terminal-publication/cleanupBackups/intent/receiptAfterSwap"
    case terminalPublicationCleanupBackupsIntentReceiptAfterDirectorySync = "signed-installation/terminal-publication/cleanupBackups/intent/receiptAfterDirectorySync"
    case terminalPublicationCleanupBackupsIntentControlBeforeSwap = "signed-installation/terminal-publication/cleanupBackups/intent/controlBeforeSwap"
    case terminalPublicationCleanupBackupsIntentControlAfterSwap = "signed-installation/terminal-publication/cleanupBackups/intent/controlAfterSwap"
    case terminalPublicationCleanupBackupsIntentControlAfterDirectorySync = "signed-installation/terminal-publication/cleanupBackups/intent/controlAfterDirectorySync"
    case terminalPublicationCleanupBackupsIntentControlAfterPreimageUnlink = "signed-installation/terminal-publication/cleanupBackups/intent/controlAfterPreimageUnlink"
    case terminalPublicationCleanupBackupsCompleteAfterReceipt = "signed-installation/terminal-publication/cleanupBackups/complete/afterReceipt"
    case terminalPublicationCleanupBackupsCompleteBeforeControl = "signed-installation/terminal-publication/cleanupBackups/complete/beforeControl"
    case terminalPublicationCleanupBackupsCompleteReceiptBeforeSwap = "signed-installation/terminal-publication/cleanupBackups/complete/receiptBeforeSwap"
    case terminalPublicationCleanupBackupsCompleteReceiptAfterSwap = "signed-installation/terminal-publication/cleanupBackups/complete/receiptAfterSwap"
    case terminalPublicationCleanupBackupsCompleteReceiptAfterDirectorySync = "signed-installation/terminal-publication/cleanupBackups/complete/receiptAfterDirectorySync"
    case terminalPublicationCleanupBackupsCompleteControlBeforeSwap = "signed-installation/terminal-publication/cleanupBackups/complete/controlBeforeSwap"
    case terminalPublicationCleanupBackupsCompleteControlAfterSwap = "signed-installation/terminal-publication/cleanupBackups/complete/controlAfterSwap"
    case terminalPublicationCleanupBackupsCompleteControlAfterDirectorySync = "signed-installation/terminal-publication/cleanupBackups/complete/controlAfterDirectorySync"
    case terminalPublicationCleanupBackupsCompleteControlAfterPreimageUnlink = "signed-installation/terminal-publication/cleanupBackups/complete/controlAfterPreimageUnlink"
    case terminalPublicationCleanupIncomingIntentAfterReceipt = "signed-installation/terminal-publication/cleanupIncoming/intent/afterReceipt"
    case terminalPublicationCleanupIncomingIntentBeforeControl = "signed-installation/terminal-publication/cleanupIncoming/intent/beforeControl"
    case terminalPublicationCleanupIncomingIntentReceiptBeforeSwap = "signed-installation/terminal-publication/cleanupIncoming/intent/receiptBeforeSwap"
    case terminalPublicationCleanupIncomingIntentReceiptAfterSwap = "signed-installation/terminal-publication/cleanupIncoming/intent/receiptAfterSwap"
    case terminalPublicationCleanupIncomingIntentReceiptAfterDirectorySync = "signed-installation/terminal-publication/cleanupIncoming/intent/receiptAfterDirectorySync"
    case terminalPublicationCleanupIncomingIntentControlBeforeSwap = "signed-installation/terminal-publication/cleanupIncoming/intent/controlBeforeSwap"
    case terminalPublicationCleanupIncomingIntentControlAfterSwap = "signed-installation/terminal-publication/cleanupIncoming/intent/controlAfterSwap"
    case terminalPublicationCleanupIncomingIntentControlAfterDirectorySync = "signed-installation/terminal-publication/cleanupIncoming/intent/controlAfterDirectorySync"
    case terminalPublicationCleanupIncomingIntentControlAfterPreimageUnlink = "signed-installation/terminal-publication/cleanupIncoming/intent/controlAfterPreimageUnlink"
    case terminalPublicationCleanupIncomingCompleteAfterReceipt = "signed-installation/terminal-publication/cleanupIncoming/complete/afterReceipt"
    case terminalPublicationCleanupIncomingCompleteBeforeControl = "signed-installation/terminal-publication/cleanupIncoming/complete/beforeControl"
    case terminalPublicationCleanupIncomingCompleteReceiptBeforeSwap = "signed-installation/terminal-publication/cleanupIncoming/complete/receiptBeforeSwap"
    case terminalPublicationCleanupIncomingCompleteReceiptAfterSwap = "signed-installation/terminal-publication/cleanupIncoming/complete/receiptAfterSwap"
    case terminalPublicationCleanupIncomingCompleteReceiptAfterDirectorySync = "signed-installation/terminal-publication/cleanupIncoming/complete/receiptAfterDirectorySync"
    case terminalPublicationCleanupIncomingCompleteControlBeforeSwap = "signed-installation/terminal-publication/cleanupIncoming/complete/controlBeforeSwap"
    case terminalPublicationCleanupIncomingCompleteControlAfterSwap = "signed-installation/terminal-publication/cleanupIncoming/complete/controlAfterSwap"
    case terminalPublicationCleanupIncomingCompleteControlAfterDirectorySync = "signed-installation/terminal-publication/cleanupIncoming/complete/controlAfterDirectorySync"
    case terminalPublicationCleanupIncomingCompleteControlAfterPreimageUnlink = "signed-installation/terminal-publication/cleanupIncoming/complete/controlAfterPreimageUnlink"
    case terminalPublicationFinishIntentAfterReceipt = "signed-installation/terminal-publication/finish/intent/afterReceipt"
    case terminalPublicationFinishIntentBeforeControl = "signed-installation/terminal-publication/finish/intent/beforeControl"
    case terminalPublicationFinishIntentReceiptBeforeSwap = "signed-installation/terminal-publication/finish/intent/receiptBeforeSwap"
    case terminalPublicationFinishIntentReceiptAfterSwap = "signed-installation/terminal-publication/finish/intent/receiptAfterSwap"
    case terminalPublicationFinishIntentReceiptAfterDirectorySync = "signed-installation/terminal-publication/finish/intent/receiptAfterDirectorySync"
    case terminalPublicationFinishIntentControlBeforeSwap = "signed-installation/terminal-publication/finish/intent/controlBeforeSwap"
    case terminalPublicationFinishIntentControlAfterSwap = "signed-installation/terminal-publication/finish/intent/controlAfterSwap"
    case terminalPublicationFinishIntentControlAfterDirectorySync = "signed-installation/terminal-publication/finish/intent/controlAfterDirectorySync"
    case terminalPublicationFinishIntentControlAfterPreimageUnlink = "signed-installation/terminal-publication/finish/intent/controlAfterPreimageUnlink"
    case terminalPublicationFinishCompleteAfterReceipt = "signed-installation/terminal-publication/finish/complete/afterReceipt"
    case terminalPublicationFinishCompleteBeforeControl = "signed-installation/terminal-publication/finish/complete/beforeControl"
    case terminalPublicationFinishCompleteReceiptBeforeSwap = "signed-installation/terminal-publication/finish/complete/receiptBeforeSwap"
    case terminalPublicationFinishCompleteReceiptAfterSwap = "signed-installation/terminal-publication/finish/complete/receiptAfterSwap"
    case terminalPublicationFinishCompleteReceiptAfterDirectorySync = "signed-installation/terminal-publication/finish/complete/receiptAfterDirectorySync"
    case terminalPublicationFinishCompleteControlBeforeSwap = "signed-installation/terminal-publication/finish/complete/controlBeforeSwap"
    case terminalPublicationFinishCompleteControlAfterSwap = "signed-installation/terminal-publication/finish/complete/controlAfterSwap"
    case terminalPublicationFinishCompleteControlAfterDirectorySync = "signed-installation/terminal-publication/finish/complete/controlAfterDirectorySync"
    case terminalPublicationFinishCompleteControlAfterPreimageUnlink = "signed-installation/terminal-publication/finish/complete/controlAfterPreimageUnlink"
    case terminalCloseTemporaryStore = "signed-installation/terminal-close/temporaryStore"
    case terminalCloseStagedSlots = "signed-installation/terminal-close/stagedSlots"
    case terminalCloseStagedParents = "signed-installation/terminal-close/stagedParents"
    case terminalCloseBootstrapParents = "signed-installation/terminal-close/bootstrapParents"
    case terminalCloseMetadata = "signed-installation/terminal-close/metadata"
    case terminalCloseAdmission = "signed-installation/terminal-close/admission"
    case terminalCloseState = "signed-installation/terminal-close/state"
    case terminalCloseOperation = "signed-installation/terminal-close/operation"
    case terminalSyncBeforeParentSync = "signed-installation/terminal-sync/beforeParentSync"
    case terminalSyncParentSyncFailure = "signed-installation/terminal-sync/parentSyncFailure"
    case terminalSyncAfterParentSync = "signed-installation/terminal-sync/afterParentSync"
    case terminalSyncBeforeRetirement = "signed-installation/terminal-sync/beforeRetirement"
    case terminalOperationCloseDeadline = "signed-installation/terminal-successful-operation-close-deadline"

    func run(bootstrap: InstallationBootstrap, journal: CustodyCatalogStore.InstallationStagedJournal,
             context: SignedInstallationFixtureContext, service: SignedInstallationFixtureService) throws {
        // The retained state location already carries the exact root; never
        // derive authority by removing arbitrary path substrings.
        let location = context.paths.state
        let ownedRoot = URL(fileURLWithPath: context.paths.home).deletingLastPathComponent().path
        guard ownedRoot + "/home" == context.paths.home else { throw CustodyRecordError.fenced }
        switch self {
        case .startupStop:
            try InstallationStartupFixtures.authenticatedStartupAndStop(journal, root: ownedRoot, location: location)
            try service.requireSuccessfulHostExit(deadline: context.deadline)
        case .stopStore, .stopCompletion, .stopHeldCompletion:
            let cut: InstallationStartupFixtures.StopRetirementCut
            switch self {
            case .stopStore: cut = .store
            case .stopCompletion: cut = .completion
            case .stopHeldCompletion: cut = .heldCompletion
            default: throw CustodyRecordError.fenced
            }
            try InstallationStartupFixtures.authenticatedStopRetirementCut(journal, location: location, cut: cut)
            // The genuine stop frame and session joined; only its original
            // product completion/store outcome remains pending. Host exit is
            // still proved through its original anchor, never inferred.
            try service.requireSuccessfulHostExit(deadline: context.deadline)
        case .cleanupPositive:
            try InstallationCoordinationCleanupFixtures.authenticatedPositive(journal, root: ownedRoot, location: location)
            // This case asserts cleanup, not authenticated stop or finish.
            // The root custodian independently drains its original host anchor.
        case .cleanupEndpointBeforeUnlink:
            try InstallationCoordinationCleanupFixtures.authenticatedEndpointCut(journal, location: location, cut: .beforeUnlink)
        case .cleanupEndpointUnlinkFailure:
            try InstallationCoordinationCleanupFixtures.authenticatedEndpointCut(journal, location: location, cut: .unlinkFailure)
        case .cleanupEndpointAfterUnlink:
            try InstallationCoordinationCleanupFixtures.authenticatedEndpointCut(journal, location: location, cut: .afterUnlink)
        case .cleanupEndpointParentSyncFailure:
            try InstallationCoordinationCleanupFixtures.authenticatedEndpointCut(journal, location: location, cut: .parentSyncFailure)
        case .cleanupEndpointAfterParentSync:
            try InstallationCoordinationCleanupFixtures.authenticatedEndpointCut(journal, location: location, cut: .afterParentSync)
        case .cleanupEndpointBeforeAncestorClose:
            try InstallationCoordinationCleanupFixtures.authenticatedEndpointCut(journal, location: location, cut: .beforeAncestorClose)
        case .cleanupPublicationAfterReceipt:
            try InstallationCoordinationCleanupFixtures.authenticatedCompletionCut(journal, location: location, failure: .afterReceipt)
        case .cleanupPublicationBeforeControl:
            try InstallationCoordinationCleanupFixtures.authenticatedCompletionCut(journal, location: location, failure: .beforeControl)
        case .cleanupPublicationReceiptBeforeSwap:
            try InstallationCoordinationCleanupFixtures.authenticatedCompletionCut(journal, location: location, failure: .receiptBeforeSwap)
        case .cleanupPublicationReceiptAfterSwap:
            try InstallationCoordinationCleanupFixtures.authenticatedCompletionCut(journal, location: location, failure: .receiptAfterSwap)
        case .cleanupPublicationReceiptAfterDirectorySync:
            try InstallationCoordinationCleanupFixtures.authenticatedCompletionCut(journal, location: location, failure: .receiptAfterDirectorySync)
        case .cleanupPublicationControlBeforeSwap:
            try InstallationCoordinationCleanupFixtures.authenticatedCompletionCut(journal, location: location, failure: .controlBeforeSwap)
        case .cleanupPublicationControlAfterSwap:
            try InstallationCoordinationCleanupFixtures.authenticatedCompletionCut(journal, location: location, failure: .controlAfterSwap)
        case .cleanupPublicationControlAfterDirectorySync:
            try InstallationCoordinationCleanupFixtures.authenticatedCompletionCut(journal, location: location, failure: .controlAfterDirectorySync)
        case .cleanupPublicationControlAfterPreimageUnlink:
            try InstallationCoordinationCleanupFixtures.authenticatedCompletionCut(journal, location: location, failure: .controlAfterPreimageUnlink)
        case .cleanupReaderAlias:
            try InstallationCoordinationCleanupFixtures.authenticatedReaderAlias(journal, root: ownedRoot, location: location)
        case .cleanupQueueJoin:
            try InstallationCoordinationCleanupFixtures.authenticatedStalledJoin(journal, root: ownedRoot, location: location)
        case .cleanupControlReplacement:
            try InstallationCoordinationCleanupFixtures.authenticatedControlReplacement(journal, root: ownedRoot, location: location)
        case .cleanupNamedMissing:
            try InstallationCoordinationCleanupFixtures.authenticatedNamedDrift(journal, root: ownedRoot, location: location, drift: .missing)
        case .cleanupNamedSubstituted:
            try InstallationCoordinationCleanupFixtures.authenticatedNamedDrift(journal, root: ownedRoot, location: location, drift: .substituted)
        case .cleanupNamedCutAfterParking:
            try InstallationCoordinationCleanupFixtures.authenticatedNamedDrift(journal, root: ownedRoot, location: location, drift: .substituted, cut: .afterParking)
        case .cleanupNamedCutAfterReplacementOpen:
            try InstallationCoordinationCleanupFixtures.authenticatedNamedDrift(journal, root: ownedRoot, location: location, drift: .substituted, cut: .afterReplacementOpen)
        case .cleanupNamedCutAfterReplacementIdentity:
            try InstallationCoordinationCleanupFixtures.authenticatedNamedDrift(journal, root: ownedRoot, location: location, drift: .substituted, cut: .afterReplacementIdentity)
        case .cleanupNamedCutAfterReplacementClose:
            try InstallationCoordinationCleanupFixtures.authenticatedNamedDrift(journal, root: ownedRoot, location: location, drift: .substituted, cut: .afterReplacementClose)
        case .terminalPublicationCleanupBackupsIntentAfterReceipt:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupBackups, status: .intent, failure: .afterReceipt)
        case .terminalPublicationCleanupBackupsIntentBeforeControl:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupBackups, status: .intent, failure: .beforeControl)
        case .terminalPublicationCleanupBackupsIntentReceiptBeforeSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupBackups, status: .intent, failure: .receiptBeforeSwap)
        case .terminalPublicationCleanupBackupsIntentReceiptAfterSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupBackups, status: .intent, failure: .receiptAfterSwap)
        case .terminalPublicationCleanupBackupsIntentReceiptAfterDirectorySync:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupBackups, status: .intent, failure: .receiptAfterDirectorySync)
        case .terminalPublicationCleanupBackupsIntentControlBeforeSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupBackups, status: .intent, failure: .controlBeforeSwap)
        case .terminalPublicationCleanupBackupsIntentControlAfterSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupBackups, status: .intent, failure: .controlAfterSwap)
        case .terminalPublicationCleanupBackupsIntentControlAfterDirectorySync:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupBackups, status: .intent, failure: .controlAfterDirectorySync)
        case .terminalPublicationCleanupBackupsIntentControlAfterPreimageUnlink:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupBackups, status: .intent, failure: .controlAfterPreimageUnlink)
        case .terminalPublicationCleanupBackupsCompleteAfterReceipt:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupBackups, status: .complete, failure: .afterReceipt)
        case .terminalPublicationCleanupBackupsCompleteBeforeControl:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupBackups, status: .complete, failure: .beforeControl)
        case .terminalPublicationCleanupBackupsCompleteReceiptBeforeSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupBackups, status: .complete, failure: .receiptBeforeSwap)
        case .terminalPublicationCleanupBackupsCompleteReceiptAfterSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupBackups, status: .complete, failure: .receiptAfterSwap)
        case .terminalPublicationCleanupBackupsCompleteReceiptAfterDirectorySync:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupBackups, status: .complete, failure: .receiptAfterDirectorySync)
        case .terminalPublicationCleanupBackupsCompleteControlBeforeSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupBackups, status: .complete, failure: .controlBeforeSwap)
        case .terminalPublicationCleanupBackupsCompleteControlAfterSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupBackups, status: .complete, failure: .controlAfterSwap)
        case .terminalPublicationCleanupBackupsCompleteControlAfterDirectorySync:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupBackups, status: .complete, failure: .controlAfterDirectorySync)
        case .terminalPublicationCleanupBackupsCompleteControlAfterPreimageUnlink:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupBackups, status: .complete, failure: .controlAfterPreimageUnlink)
        case .terminalPublicationCleanupIncomingIntentAfterReceipt:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupIncoming, status: .intent, failure: .afterReceipt)
        case .terminalPublicationCleanupIncomingIntentBeforeControl:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupIncoming, status: .intent, failure: .beforeControl)
        case .terminalPublicationCleanupIncomingIntentReceiptBeforeSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupIncoming, status: .intent, failure: .receiptBeforeSwap)
        case .terminalPublicationCleanupIncomingIntentReceiptAfterSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupIncoming, status: .intent, failure: .receiptAfterSwap)
        case .terminalPublicationCleanupIncomingIntentReceiptAfterDirectorySync:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupIncoming, status: .intent, failure: .receiptAfterDirectorySync)
        case .terminalPublicationCleanupIncomingIntentControlBeforeSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupIncoming, status: .intent, failure: .controlBeforeSwap)
        case .terminalPublicationCleanupIncomingIntentControlAfterSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupIncoming, status: .intent, failure: .controlAfterSwap)
        case .terminalPublicationCleanupIncomingIntentControlAfterDirectorySync:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupIncoming, status: .intent, failure: .controlAfterDirectorySync)
        case .terminalPublicationCleanupIncomingIntentControlAfterPreimageUnlink:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupIncoming, status: .intent, failure: .controlAfterPreimageUnlink)
        case .terminalPublicationCleanupIncomingCompleteAfterReceipt:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupIncoming, status: .complete, failure: .afterReceipt)
        case .terminalPublicationCleanupIncomingCompleteBeforeControl:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupIncoming, status: .complete, failure: .beforeControl)
        case .terminalPublicationCleanupIncomingCompleteReceiptBeforeSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupIncoming, status: .complete, failure: .receiptBeforeSwap)
        case .terminalPublicationCleanupIncomingCompleteReceiptAfterSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupIncoming, status: .complete, failure: .receiptAfterSwap)
        case .terminalPublicationCleanupIncomingCompleteReceiptAfterDirectorySync:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupIncoming, status: .complete, failure: .receiptAfterDirectorySync)
        case .terminalPublicationCleanupIncomingCompleteControlBeforeSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupIncoming, status: .complete, failure: .controlBeforeSwap)
        case .terminalPublicationCleanupIncomingCompleteControlAfterSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupIncoming, status: .complete, failure: .controlAfterSwap)
        case .terminalPublicationCleanupIncomingCompleteControlAfterDirectorySync:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupIncoming, status: .complete, failure: .controlAfterDirectorySync)
        case .terminalPublicationCleanupIncomingCompleteControlAfterPreimageUnlink:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .cleanupIncoming, status: .complete, failure: .controlAfterPreimageUnlink)
        case .terminalPublicationFinishIntentAfterReceipt:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .finish, status: .intent, failure: .afterReceipt)
        case .terminalPublicationFinishIntentBeforeControl:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .finish, status: .intent, failure: .beforeControl)
        case .terminalPublicationFinishIntentReceiptBeforeSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .finish, status: .intent, failure: .receiptBeforeSwap)
        case .terminalPublicationFinishIntentReceiptAfterSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .finish, status: .intent, failure: .receiptAfterSwap)
        case .terminalPublicationFinishIntentReceiptAfterDirectorySync:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .finish, status: .intent, failure: .receiptAfterDirectorySync)
        case .terminalPublicationFinishIntentControlBeforeSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .finish, status: .intent, failure: .controlBeforeSwap)
        case .terminalPublicationFinishIntentControlAfterSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .finish, status: .intent, failure: .controlAfterSwap)
        case .terminalPublicationFinishIntentControlAfterDirectorySync:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .finish, status: .intent, failure: .controlAfterDirectorySync)
        case .terminalPublicationFinishIntentControlAfterPreimageUnlink:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .finish, status: .intent, failure: .controlAfterPreimageUnlink)
        case .terminalPublicationFinishCompleteAfterReceipt:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .finish, status: .complete, failure: .afterReceipt)
        case .terminalPublicationFinishCompleteBeforeControl:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .finish, status: .complete, failure: .beforeControl)
        case .terminalPublicationFinishCompleteReceiptBeforeSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .finish, status: .complete, failure: .receiptBeforeSwap)
        case .terminalPublicationFinishCompleteReceiptAfterSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .finish, status: .complete, failure: .receiptAfterSwap)
        case .terminalPublicationFinishCompleteReceiptAfterDirectorySync:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .finish, status: .complete, failure: .receiptAfterDirectorySync)
        case .terminalPublicationFinishCompleteControlBeforeSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .finish, status: .complete, failure: .controlBeforeSwap)
        case .terminalPublicationFinishCompleteControlAfterSwap:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .finish, status: .complete, failure: .controlAfterSwap)
        case .terminalPublicationFinishCompleteControlAfterDirectorySync:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .finish, status: .complete, failure: .controlAfterDirectorySync)
        case .terminalPublicationFinishCompleteControlAfterPreimageUnlink:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPublicationCut(bootstrap, location: location, action: .finish, status: .complete, failure: .controlAfterPreimageUnlink)
        case .terminalCloseTemporaryStore:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedCloseCut(bootstrap, location: location, resource: .temporaryStore)
        case .terminalCloseStagedSlots:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedCloseCut(bootstrap, location: location, resource: .stagedSlots)
        case .terminalCloseStagedParents:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedCloseCut(bootstrap, location: location, resource: .stagedParents)
        case .terminalCloseBootstrapParents:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedCloseCut(bootstrap, location: location, resource: .bootstrapParents)
        case .terminalCloseMetadata:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedCloseCut(bootstrap, location: location, resource: .metadata)
        case .terminalCloseAdmission:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedCloseCut(bootstrap, location: location, resource: .admission)
        case .terminalCloseState:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedCloseCut(bootstrap, location: location, resource: .state)
        case .terminalCloseOperation:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedCloseCut(bootstrap, location: location, resource: .operation)
        case .terminalSyncBeforeParentSync:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedSyncCut(bootstrap, location: location, cut: .beforeParentSync)
        case .terminalSyncParentSyncFailure:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedSyncCut(bootstrap, location: location, cut: .parentSyncFailure(Int(EIO)))
        case .terminalSyncAfterParentSync:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedSyncCut(bootstrap, location: location, cut: .afterParentSync)
        case .terminalSyncBeforeRetirement:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedSyncCut(bootstrap, location: location, cut: .beforeRetirement)
        case .terminalOperationCloseDeadline:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedSuccessfulOperationCloseDeadline(bootstrap, location: location)
        case .terminalPositive:
            try bootstrap.observeNormalStartup()
            try bootstrap.cleanupReadinessCoordination()
            try InstallationTerminalFixtures.authenticatedPositive(bootstrap, root: ownedRoot, location: location)
        }
    }
}
#endif
