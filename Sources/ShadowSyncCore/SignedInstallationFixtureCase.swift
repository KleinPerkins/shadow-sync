#if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
import Darwin
import Foundation

/// A finite scenario for one original guardian/root/bootstrap. This roster
/// includes only source-connected cases with separately owned fixture teardown.
/// Required pending-cut cases remain explicit unavailable coverage in discovery.
enum SignedInstallationFixtureCase: String, CaseIterable {
    case startAdapterJoinInBudget = "signed-installation/start-adapter-join/in-budget"
    case startAdapterJoinExpiredComplete = "signed-installation/start-adapter-join/expired-complete"
    case startAdapterJoinExpiredPending = "signed-installation/start-adapter-join/expired-pending"
    case startAdapterJoinFaultBeforeBind = "signed-installation/start-adapter-join/fault-before-bind"
    case startAdapterJoinFaultAfterAck = "signed-installation/start-adapter-join/fault-after-ack"
    case startAdapterJoinFaultBeforeJoin = "signed-installation/start-adapter-join/fault-before-join"
    case startAdapterJoinFaultAfterRefusal = "signed-installation/start-adapter-join/fault-after-refusal"
    case startAdapterJoinHExpiry = "signed-installation/start-adapter-join/h-expiry"
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

    case freshDriverPositive = "signed-installation/fresh-driver/positive"
    case freshDriverCancelReady = "signed-installation/fresh-driver/cancel-ready"
    case freshDriverCancelNormal = "signed-installation/fresh-driver/cancel-normal"
    case freshDriverCleanup = "signed-installation/fresh-driver/cleanup-after-unlink"
    case freshDriverCloseTemporaryStore = "signed-installation/fresh-driver/close/temporaryStore"
    case freshDriverCloseStagedSlots = "signed-installation/fresh-driver/close/stagedSlots"
    case freshDriverCloseStagedParents = "signed-installation/fresh-driver/close/stagedParents"
    case freshDriverCloseBootstrapParents = "signed-installation/fresh-driver/close/bootstrapParents"
    case freshDriverCloseMetadata = "signed-installation/fresh-driver/close/metadata"
    case freshDriverCloseAdmission = "signed-installation/fresh-driver/close/admission"
    case freshDriverCloseState = "signed-installation/fresh-driver/close/state"
    case freshDriverCloseOperation = "signed-installation/fresh-driver/close/operation"

    case freshDriverReadyClaimed = "signed-installation/fresh-driver/ready/claimed"
    case freshDriverReadyIntentRetained = "signed-installation/fresh-driver/ready/intentRetained"
    case freshDriverReadyContextRetained = "signed-installation/fresh-driver/ready/contextRetained"
    case freshDriverReadyCommandRetained = "signed-installation/fresh-driver/ready/commandRetained"
    case freshDriverReadySubmitted = "signed-installation/fresh-driver/ready/submitted"
    case freshDriverReadyRetirementReceived = "signed-installation/fresh-driver/ready/retirementReceived"
    case freshDriverReadyAliasesReleased = "signed-installation/fresh-driver/ready/aliasesReleased"
    case freshDriverReadyRetired = "signed-installation/fresh-driver/ready/retired"
    case freshDriverReadyCompleted = "signed-installation/fresh-driver/ready/completed"
    case freshDriverCommitClaimed = "signed-installation/fresh-driver/commit/claimed"
    case freshDriverCommitPublished = "signed-installation/fresh-driver/commit/published"
    case freshDriverCommitDelivered = "signed-installation/fresh-driver/commit/delivered"
    case freshDriverPublicationCandidateIntentAfterReceipt = "signed-installation/fresh-driver/publication/candidateIntent/afterReceipt"
    case freshDriverPublicationCandidateIntentBeforeControl = "signed-installation/fresh-driver/publication/candidateIntent/beforeControl"
    case freshDriverPublicationCandidateIntentReceiptBeforeSwap = "signed-installation/fresh-driver/publication/candidateIntent/receiptBeforeSwap"
    case freshDriverPublicationCandidateIntentReceiptAfterSwap = "signed-installation/fresh-driver/publication/candidateIntent/receiptAfterSwap"
    case freshDriverPublicationCandidateIntentReceiptAfterDirectorySync = "signed-installation/fresh-driver/publication/candidateIntent/receiptAfterDirectorySync"
    case freshDriverPublicationCandidateIntentControlBeforeSwap = "signed-installation/fresh-driver/publication/candidateIntent/controlBeforeSwap"
    case freshDriverPublicationCandidateIntentControlAfterSwap = "signed-installation/fresh-driver/publication/candidateIntent/controlAfterSwap"
    case freshDriverPublicationCandidateIntentControlAfterDirectorySync = "signed-installation/fresh-driver/publication/candidateIntent/controlAfterDirectorySync"
    case freshDriverPublicationCandidateIntentControlAfterPreimageUnlink = "signed-installation/fresh-driver/publication/candidateIntent/controlAfterPreimageUnlink"
    case freshDriverPublicationCandidateCompleteAfterReceipt = "signed-installation/fresh-driver/publication/candidateComplete/afterReceipt"
    case freshDriverPublicationCandidateCompleteBeforeControl = "signed-installation/fresh-driver/publication/candidateComplete/beforeControl"
    case freshDriverPublicationCandidateCompleteReceiptBeforeSwap = "signed-installation/fresh-driver/publication/candidateComplete/receiptBeforeSwap"
    case freshDriverPublicationCandidateCompleteReceiptAfterSwap = "signed-installation/fresh-driver/publication/candidateComplete/receiptAfterSwap"
    case freshDriverPublicationCandidateCompleteReceiptAfterDirectorySync = "signed-installation/fresh-driver/publication/candidateComplete/receiptAfterDirectorySync"
    case freshDriverPublicationCandidateCompleteControlBeforeSwap = "signed-installation/fresh-driver/publication/candidateComplete/controlBeforeSwap"
    case freshDriverPublicationCandidateCompleteControlAfterSwap = "signed-installation/fresh-driver/publication/candidateComplete/controlAfterSwap"
    case freshDriverPublicationCandidateCompleteControlAfterDirectorySync = "signed-installation/fresh-driver/publication/candidateComplete/controlAfterDirectorySync"
    case freshDriverPublicationCandidateCompleteControlAfterPreimageUnlink = "signed-installation/fresh-driver/publication/candidateComplete/controlAfterPreimageUnlink"
    case freshDriverPublicationCommitIntentAfterReceipt = "signed-installation/fresh-driver/publication/commitIntent/afterReceipt"
    case freshDriverPublicationCommitIntentBeforeControl = "signed-installation/fresh-driver/publication/commitIntent/beforeControl"
    case freshDriverPublicationCommitIntentReceiptBeforeSwap = "signed-installation/fresh-driver/publication/commitIntent/receiptBeforeSwap"
    case freshDriverPublicationCommitIntentReceiptAfterSwap = "signed-installation/fresh-driver/publication/commitIntent/receiptAfterSwap"
    case freshDriverPublicationCommitIntentReceiptAfterDirectorySync = "signed-installation/fresh-driver/publication/commitIntent/receiptAfterDirectorySync"
    case freshDriverPublicationCommitIntentControlBeforeSwap = "signed-installation/fresh-driver/publication/commitIntent/controlBeforeSwap"
    case freshDriverPublicationCommitIntentControlAfterSwap = "signed-installation/fresh-driver/publication/commitIntent/controlAfterSwap"
    case freshDriverPublicationCommitIntentControlAfterDirectorySync = "signed-installation/fresh-driver/publication/commitIntent/controlAfterDirectorySync"
    case freshDriverPublicationCommitIntentControlAfterPreimageUnlink = "signed-installation/fresh-driver/publication/commitIntent/controlAfterPreimageUnlink"
    case freshDriverPublicationCommitCompleteAfterReceipt = "signed-installation/fresh-driver/publication/commitComplete/afterReceipt"
    case freshDriverPublicationCommitCompleteBeforeControl = "signed-installation/fresh-driver/publication/commitComplete/beforeControl"
    case freshDriverPublicationCommitCompleteReceiptBeforeSwap = "signed-installation/fresh-driver/publication/commitComplete/receiptBeforeSwap"
    case freshDriverPublicationCommitCompleteReceiptAfterSwap = "signed-installation/fresh-driver/publication/commitComplete/receiptAfterSwap"
    case freshDriverPublicationCommitCompleteReceiptAfterDirectorySync = "signed-installation/fresh-driver/publication/commitComplete/receiptAfterDirectorySync"
    case freshDriverPublicationCommitCompleteControlBeforeSwap = "signed-installation/fresh-driver/publication/commitComplete/controlBeforeSwap"
    case freshDriverPublicationCommitCompleteControlAfterSwap = "signed-installation/fresh-driver/publication/commitComplete/controlAfterSwap"
    case freshDriverPublicationCommitCompleteControlAfterDirectorySync = "signed-installation/fresh-driver/publication/commitComplete/controlAfterDirectorySync"
    case freshDriverPublicationCommitCompleteControlAfterPreimageUnlink = "signed-installation/fresh-driver/publication/commitComplete/controlAfterPreimageUnlink"
    case freshDriverDeliveryAfterReadback = "signed-installation/fresh-driver/delivery/afterReadback"
    case freshDriverDeliveryAfterSendReservation = "signed-installation/fresh-driver/delivery/afterSendReservation"
    case freshDriverLostNormal = "signed-installation/fresh-driver/lost-normal-started"
    case freshDriverLateNormal = "signed-installation/fresh-driver/late-normal-started"

    var freshUncertainty: SignedFreshInstallationDriverFixture.Uncertainty? {
        switch self {
        case .freshDriverReadyClaimed: return .ready(.claimed)
        case .freshDriverReadyIntentRetained: return .ready(.intentRetained)
        case .freshDriverReadyContextRetained: return .ready(.contextRetained)
        case .freshDriverReadyCommandRetained: return .ready(.commandRetained)
        case .freshDriverReadySubmitted: return .ready(.submitted)
        case .freshDriverReadyRetirementReceived: return .ready(.retirementReceived)
        case .freshDriverReadyAliasesReleased: return .ready(.aliasesReleased)
        case .freshDriverReadyRetired: return .ready(.retired)
        case .freshDriverReadyCompleted: return .ready(.completed)
        case .freshDriverCommitClaimed: return .commit(.claimed)
        case .freshDriverCommitPublished: return .commit(.published)
        case .freshDriverCommitDelivered: return .commit(.delivered)
        case .freshDriverPublicationCandidateIntentAfterReceipt: return .publication(.candidateIntent, .afterReceipt)
        case .freshDriverPublicationCandidateIntentBeforeControl: return .publication(.candidateIntent, .beforeControl)
        case .freshDriverPublicationCandidateIntentReceiptBeforeSwap: return .publication(.candidateIntent, .receiptBeforeSwap)
        case .freshDriverPublicationCandidateIntentReceiptAfterSwap: return .publication(.candidateIntent, .receiptAfterSwap)
        case .freshDriverPublicationCandidateIntentReceiptAfterDirectorySync: return .publication(.candidateIntent, .receiptAfterDirectorySync)
        case .freshDriverPublicationCandidateIntentControlBeforeSwap: return .publication(.candidateIntent, .controlBeforeSwap)
        case .freshDriverPublicationCandidateIntentControlAfterSwap: return .publication(.candidateIntent, .controlAfterSwap)
        case .freshDriverPublicationCandidateIntentControlAfterDirectorySync: return .publication(.candidateIntent, .controlAfterDirectorySync)
        case .freshDriverPublicationCandidateIntentControlAfterPreimageUnlink: return .publication(.candidateIntent, .controlAfterPreimageUnlink)
        case .freshDriverPublicationCandidateCompleteAfterReceipt: return .publication(.candidateComplete, .afterReceipt)
        case .freshDriverPublicationCandidateCompleteBeforeControl: return .publication(.candidateComplete, .beforeControl)
        case .freshDriverPublicationCandidateCompleteReceiptBeforeSwap: return .publication(.candidateComplete, .receiptBeforeSwap)
        case .freshDriverPublicationCandidateCompleteReceiptAfterSwap: return .publication(.candidateComplete, .receiptAfterSwap)
        case .freshDriverPublicationCandidateCompleteReceiptAfterDirectorySync: return .publication(.candidateComplete, .receiptAfterDirectorySync)
        case .freshDriverPublicationCandidateCompleteControlBeforeSwap: return .publication(.candidateComplete, .controlBeforeSwap)
        case .freshDriverPublicationCandidateCompleteControlAfterSwap: return .publication(.candidateComplete, .controlAfterSwap)
        case .freshDriverPublicationCandidateCompleteControlAfterDirectorySync: return .publication(.candidateComplete, .controlAfterDirectorySync)
        case .freshDriverPublicationCandidateCompleteControlAfterPreimageUnlink: return .publication(.candidateComplete, .controlAfterPreimageUnlink)
        case .freshDriverPublicationCommitIntentAfterReceipt: return .publication(.commitIntent, .afterReceipt)
        case .freshDriverPublicationCommitIntentBeforeControl: return .publication(.commitIntent, .beforeControl)
        case .freshDriverPublicationCommitIntentReceiptBeforeSwap: return .publication(.commitIntent, .receiptBeforeSwap)
        case .freshDriverPublicationCommitIntentReceiptAfterSwap: return .publication(.commitIntent, .receiptAfterSwap)
        case .freshDriverPublicationCommitIntentReceiptAfterDirectorySync: return .publication(.commitIntent, .receiptAfterDirectorySync)
        case .freshDriverPublicationCommitIntentControlBeforeSwap: return .publication(.commitIntent, .controlBeforeSwap)
        case .freshDriverPublicationCommitIntentControlAfterSwap: return .publication(.commitIntent, .controlAfterSwap)
        case .freshDriverPublicationCommitIntentControlAfterDirectorySync: return .publication(.commitIntent, .controlAfterDirectorySync)
        case .freshDriverPublicationCommitIntentControlAfterPreimageUnlink: return .publication(.commitIntent, .controlAfterPreimageUnlink)
        case .freshDriverPublicationCommitCompleteAfterReceipt: return .publication(.commitComplete, .afterReceipt)
        case .freshDriverPublicationCommitCompleteBeforeControl: return .publication(.commitComplete, .beforeControl)
        case .freshDriverPublicationCommitCompleteReceiptBeforeSwap: return .publication(.commitComplete, .receiptBeforeSwap)
        case .freshDriverPublicationCommitCompleteReceiptAfterSwap: return .publication(.commitComplete, .receiptAfterSwap)
        case .freshDriverPublicationCommitCompleteReceiptAfterDirectorySync: return .publication(.commitComplete, .receiptAfterDirectorySync)
        case .freshDriverPublicationCommitCompleteControlBeforeSwap: return .publication(.commitComplete, .controlBeforeSwap)
        case .freshDriverPublicationCommitCompleteControlAfterSwap: return .publication(.commitComplete, .controlAfterSwap)
        case .freshDriverPublicationCommitCompleteControlAfterDirectorySync: return .publication(.commitComplete, .controlAfterDirectorySync)
        case .freshDriverPublicationCommitCompleteControlAfterPreimageUnlink: return .publication(.commitComplete, .controlAfterPreimageUnlink)
        case .freshDriverDeliveryAfterReadback: return .delivery(.afterReadback)
        case .freshDriverDeliveryAfterSendReservation: return .delivery(.afterSendReservation)
        case .freshDriverLostNormal: return .lostNormal
        case .freshDriverLateNormal: return .lateNormal
        default: return nil
        }
    }

    var isStartAdapterJoinControl: Bool {
        switch self {
        case .startAdapterJoinFaultBeforeBind, .startAdapterJoinFaultAfterAck,
             .startAdapterJoinFaultBeforeJoin, .startAdapterJoinFaultAfterRefusal, .startAdapterJoinHExpiry: return true
        default: return false
        }
    }
    var isStartAdapterJoin: Bool {
        switch self {
        case .startAdapterJoinInBudget, .startAdapterJoinExpiredComplete, .startAdapterJoinExpiredPending: return true
        default: return false
        }
    }
    func run(bootstrap: InstallationBootstrap, journal: CustodyCatalogStore.InstallationStagedJournal,
             context: SignedInstallationFixtureContext, service: SignedInstallationFixtureService) throws {
        // The retained state location already carries the exact root; never
        // derive authority by removing arbitrary path substrings.
        let location = context.paths.state
        let ownedRoot = URL(fileURLWithPath: context.paths.home).deletingLastPathComponent().path
        guard ownedRoot + "/home" == context.paths.home else { throw CustodyRecordError.fenced }
        switch self {
        case .freshDriverReadyClaimed, .freshDriverReadyIntentRetained, .freshDriverReadyContextRetained, .freshDriverReadyCommandRetained, .freshDriverReadySubmitted, .freshDriverReadyRetirementReceived, .freshDriverReadyAliasesReleased, .freshDriverReadyRetired, .freshDriverReadyCompleted, .freshDriverCommitClaimed, .freshDriverCommitPublished, .freshDriverCommitDelivered, .freshDriverPublicationCandidateIntentAfterReceipt, .freshDriverPublicationCandidateIntentBeforeControl, .freshDriverPublicationCandidateIntentReceiptBeforeSwap, .freshDriverPublicationCandidateIntentReceiptAfterSwap, .freshDriverPublicationCandidateIntentReceiptAfterDirectorySync, .freshDriverPublicationCandidateIntentControlBeforeSwap, .freshDriverPublicationCandidateIntentControlAfterSwap, .freshDriverPublicationCandidateIntentControlAfterDirectorySync, .freshDriverPublicationCandidateIntentControlAfterPreimageUnlink, .freshDriverPublicationCandidateCompleteAfterReceipt, .freshDriverPublicationCandidateCompleteBeforeControl, .freshDriverPublicationCandidateCompleteReceiptBeforeSwap, .freshDriverPublicationCandidateCompleteReceiptAfterSwap, .freshDriverPublicationCandidateCompleteReceiptAfterDirectorySync, .freshDriverPublicationCandidateCompleteControlBeforeSwap, .freshDriverPublicationCandidateCompleteControlAfterSwap, .freshDriverPublicationCandidateCompleteControlAfterDirectorySync, .freshDriverPublicationCandidateCompleteControlAfterPreimageUnlink, .freshDriverPublicationCommitIntentAfterReceipt, .freshDriverPublicationCommitIntentBeforeControl, .freshDriverPublicationCommitIntentReceiptBeforeSwap, .freshDriverPublicationCommitIntentReceiptAfterSwap, .freshDriverPublicationCommitIntentReceiptAfterDirectorySync, .freshDriverPublicationCommitIntentControlBeforeSwap, .freshDriverPublicationCommitIntentControlAfterSwap, .freshDriverPublicationCommitIntentControlAfterDirectorySync, .freshDriverPublicationCommitIntentControlAfterPreimageUnlink, .freshDriverPublicationCommitCompleteAfterReceipt, .freshDriverPublicationCommitCompleteBeforeControl, .freshDriverPublicationCommitCompleteReceiptBeforeSwap, .freshDriverPublicationCommitCompleteReceiptAfterSwap, .freshDriverPublicationCommitCompleteReceiptAfterDirectorySync, .freshDriverPublicationCommitCompleteControlBeforeSwap, .freshDriverPublicationCommitCompleteControlAfterSwap, .freshDriverPublicationCommitCompleteControlAfterDirectorySync, .freshDriverPublicationCommitCompleteControlAfterPreimageUnlink, .freshDriverDeliveryAfterReadback, .freshDriverDeliveryAfterSendReservation, .freshDriverLostNormal, .freshDriverLateNormal:
            throw CustodyRecordError.fenced // actual-driver uncertainty dispatch only
        case .freshDriverPositive, .freshDriverCancelReady, .freshDriverCancelNormal, .freshDriverCleanup, .freshDriverCloseTemporaryStore, .freshDriverCloseStagedSlots, .freshDriverCloseStagedParents, .freshDriverCloseBootstrapParents, .freshDriverCloseMetadata, .freshDriverCloseAdmission, .freshDriverCloseState, .freshDriverCloseOperation:
            throw CustodyRecordError.fenced // driver cases enter before manual phase dispatch
        case .startAdapterJoinFaultBeforeBind, .startAdapterJoinFaultAfterAck,
             .startAdapterJoinFaultBeforeJoin, .startAdapterJoinFaultAfterRefusal, .startAdapterJoinHExpiry,
             .startAdapterJoinInBudget, .startAdapterJoinExpiredComplete, .startAdapterJoinExpiredPending:
            throw CustodyRecordError.fenced // These require the separate pre-start driver.
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
