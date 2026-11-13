import CryptoKit
import Darwin
import Foundation

public let shadowSyncRetentionSchema =
    "shadow-sync-retention/v2"

public enum RetentionEntryKind:
    String, Codable, Equatable, Sendable {
    case directory
    case regular
    case symbolicLink
}

public struct RetentionEntry:
    Codable, Equatable, Sendable {
    public let path: String
    public let kind: RetentionEntryKind
    public let mode: UInt16
    public let size: UInt64
    public let symlinkTarget: String?
    public let contentSHA256: String?

    public init(
        path: String,
        kind: RetentionEntryKind,
        mode: UInt16,
        size: UInt64,
        symlinkTarget: String?,
        contentSHA256: String?
    ) throws {
        guard RetentionPath.isSafeRelative(path),
              mode <= 0o7777,
              (kind == .symbolicLink)
                == (symlinkTarget != nil),
              (kind == .regular)
                == (contentSHA256 != nil) else {
            throw GitSafetyError.unsafeRepository(
                "retention manifest entry is invalid"
            )
        }
        self.path = path
        self.kind = kind
        self.mode = mode
        self.size = size
        self.symlinkTarget = symlinkTarget
        self.contentSHA256 = contentSHA256
    }
}

public struct RetentionRestoreProof:
    Codable, Equatable, Sendable {
    public let verifiedAt: String
    public let exactTipOID: String?
    public let bundleVerified: Bool
    public let connectivityVerified: Bool
    public let entryManifestVerified: Bool
    public let indexVerified: Bool
    public let statusDigestVerified: Bool

    public var isComplete: Bool {
        entryManifestVerified
            && indexVerified
            && statusDigestVerified
            && (
                exactTipOID == nil
                    || (bundleVerified && connectivityVerified)
            )
    }
}

public struct RetentionManifest:
    Codable, Equatable, Sendable {
    public let schema: String
    public let artifactID: String
    public let repositoryID: String
    public let cloneID: String
    public let commonDirectoryIdentity:
        RepositoryDirectoryIdentity
    public let worktreeID: String?
    public let worktreeRootIdentity:
        RepositoryDirectoryIdentity?
    public let registrationIdentity:
        RepositoryDirectoryIdentity?
    public let branchRef: String?
    public let tipOID: String?
    public let objectFormat: String
    public let entries: [RetentionEntry]
    public let indexSHA256: String?
    public let sharedIndexFiles: [String: String]
    public let statusSHA256: String?
    public let includedPaths: [String]
    public let excludedPaths: [String]
    public let secretShapedPaths: [String]
    public let possibleSecretsAuthorized: Bool
    public let createdAt: String
    public let componentSHA256: [String: String]
    public let restoreProof: RetentionRestoreProof
    public let restoreInstructions: [String]

    public init(
        artifactID: String,
        repositoryID: String,
        cloneID: String,
        commonDirectoryIdentity:
            RepositoryDirectoryIdentity,
        worktreeID: String?,
        worktreeRootIdentity:
            RepositoryDirectoryIdentity?,
        registrationIdentity:
            RepositoryDirectoryIdentity?,
        branchRef: String?,
        tipOID: String?,
        objectFormat: String,
        entries: [RetentionEntry],
        indexSHA256: String?,
        sharedIndexFiles: [String: String],
        statusSHA256: String?,
        includedPaths: [String],
        excludedPaths: [String],
        secretShapedPaths: [String],
        possibleSecretsAuthorized: Bool,
        createdAt: String,
        componentSHA256: [String: String],
        restoreProof: RetentionRestoreProof,
        restoreInstructions: [String]
    ) throws {
        guard artifactID.range(
            of: #"^[a-z0-9-]{8,80}$"#,
            options: .regularExpression
        ) != nil,
        GitHubIdentity.parse(
            "git@github.com:\(repositoryID).git"
        )?.canonicalName == repositoryID,
        cloneID.hasPrefix("clone:"),
        branchRef == nil
            || GitReferenceSyntax.isValidLocalBranchRef(branchRef!),
        tipOID == nil || RetentionPath.isOID(tipOID!),
        objectFormat == "sha1" || objectFormat == "sha256",
        Set(entries.map(\.path)).count == entries.count,
        entries == entries.sorted(by: { $0.path < $1.path }),
        includedPaths.allSatisfy(RetentionPath.isSafeRelative),
        excludedPaths.allSatisfy(RetentionPath.isSafeRelative),
        secretShapedPaths.allSatisfy(
            RetentionPath.isSafeRelative
        ),
        restoreProof.isComplete,
        possibleSecretsAuthorized,
        !restoreInstructions.isEmpty else {
            throw GitSafetyError.unsafeRepository(
                "retention manifest is incomplete"
            )
        }
        schema = shadowSyncRetentionSchema
        self.artifactID = artifactID
        self.repositoryID = repositoryID
        self.cloneID = cloneID
        self.commonDirectoryIdentity =
            commonDirectoryIdentity
        self.worktreeID = worktreeID
        self.worktreeRootIdentity = worktreeRootIdentity
        self.registrationIdentity = registrationIdentity
        self.branchRef = branchRef
        self.tipOID = tipOID?.lowercased()
        self.objectFormat = objectFormat
        self.entries = entries
        self.indexSHA256 = indexSHA256
        self.sharedIndexFiles = sharedIndexFiles
        self.statusSHA256 = statusSHA256
        self.includedPaths = includedPaths.sorted()
        self.excludedPaths = excludedPaths.sorted()
        self.secretShapedPaths = secretShapedPaths.sorted()
        self.possibleSecretsAuthorized =
            possibleSecretsAuthorized
        self.createdAt = createdAt
        self.componentSHA256 = componentSHA256
        self.restoreProof = restoreProof
        self.restoreInstructions =
            restoreInstructions.map(Redactor.sanitize)
    }
}

public struct RetentionArtifactSummary:
    Codable, Equatable, Sendable {
    public let artifactID: String
    public let repositoryID: String
    public let target: String
    public let tipOID: String?
    public let path: String
    public let restoreProven: Bool
    public let restoreInstructions: [String]

    public init(
        manifest: RetentionManifest,
        path: String
    ) {
        artifactID = manifest.artifactID
        repositoryID = manifest.repositoryID
        target = manifest.worktreeID
            ?? manifest.branchRef
            ?? "history"
        tipOID = manifest.tipOID
        self.path = path
        restoreProven = manifest.restoreProof.isComplete
        restoreInstructions = manifest.restoreInstructions
    }
}

public enum RetentionPreparation:
    Equatable, Sendable {
    case completed(RetentionArtifactSummary)
    case incomplete(
        excludedPaths: [String],
        secretShapedPaths: [String],
        reason: String
    )
    case cancelled
    case cleanupPending
}

public final class RetentionArtifactStore:
    @unchecked Sendable {
    private static let maximumEntries = 10_000
    // Complete preflight is held in anonymous original-descriptor spill files;
    // memory is bounded independently of total payload/metadata node count.
    private static let maximumCleanupDepth = 512
    private static let maximumBytes: UInt64 =
        1_073_741_824
    private let state: SecureStateDirectory
    private let account: EffectiveAccount
    private let runner: ClosedProcessRunner
    private var configurationContext: CommandCustodyContext?
    #if SHADOW_SYNC_TESTING
    struct TestingCustodyHooks: Sendable {
        var beforePrepare: (@Sendable (RetentionArchiveCommandAuthority) throws -> Void)? = nil
        var afterStart: (@Sendable (PreparedCustodyCommand, RetainedCleanupRegistry.Handle, CancellationToken) throws -> Void)? = nil
    }
    var testingCustodyHooks: TestingCustodyHooks? = nil
    struct TestingCleanupHooks {
        var beforeCreate: ((Int32, String) throws -> Void)? = nil
        var afterCreate: ((Int32, String) throws -> Void)? = nil
        var afterOpen: ((Int32, Int32, String) throws -> Void)? = nil
        var afterPreflight: ((Int32, Int32, String) throws -> Void)? = nil
        var beforeDelete: ((Int32, String, Int) throws -> Void)? = nil
        var afterPostflightDurability: ((MonotonicDeadline) throws -> Void)? = nil
        var afterPlanClose: ((MonotonicDeadline) throws -> Void)? = nil
        var afterPublish: (() throws -> Void)? = nil
    }
    var testingCleanupHooks: TestingCleanupHooks? = nil
    private var testingPreparationFailureFamily = 0
    #endif
    // This shelf holds only original live owners, never reconstructed names or PIDs.
    // An unresolved attempt fences every Store for the same state inode until process
    // exit. It is not a retry service; persisted incomplete slots still fail list().
    private final class Attempt: @unchecked Sendable {
        let stateIdentity: FileIdentity
        let stateFlags: UInt32
        let state: SecureStateDirectory
        let name: String
        var parent: OwnedFileDescriptor?, slot: OwnedFileDescriptor?
        var parentIdentity: FileIdentity?, slotIdentity: FileIdentity?
        var parentFlags: UInt32?, slotFlags: UInt32?
        // Only exact accepted archive paths receive their preserved payload modes.
        // Slot, proof root, repository root and generated metadata remain private/safe.
        var payloadEntries: [String: RetentionEntry] = [:]
        var creationUnresolved = false, published = false, cleanupUnresolved = false
        var command: RetainedCleanupRegistry.Handle?
        // Handle.finished describes command retirement; it does not retain the
        // phase leases. Keep these actual original owners while slot cleanup is
        // unresolved, including the interval after command-resource retirement.
        var context: CommandCustodyContext?, admission: RetentionArchiveAdmission?
        var primary: RepositoryHandle?, worktree: RepositoryHandle?, frozen: FrozenGitConfiguration?
        var commandUnresolved = false
        var plan: CleanupPlan?
        #if SHADOW_SYNC_TESTING
        var cleanupDiagnosticStage = 0
        var cleanupDiagnosticElapsed: UInt64 = 0
        var cleanupDiagnosticDeadlinePresent = false, cleanupDiagnosticExpired = false
        // Fixed testing-only aggregates for this actual retireTree invocation.
        // Stage intervals are exclusive composite regions, not syscall profiles.
        var cleanupCostEnabled = false, cleanupCostActive = false, cleanupCostOverflow = false
        var cleanupCostStarted: UInt64 = 0
        var cleanupCostNanoseconds: [UInt64] = [], cleanupCostEntries: [UInt64] = []
        // Exclusive subspans of coarse stage203 only. These fixed aggregates
        // describe composite regions, not syscall attribution or authority.
        var cleanupLocationActive = false
        var cleanupLocationStage = 0
        var cleanupLocationStarted: UInt64 = 0
        var cleanupLocationNanoseconds: [UInt64] = []
        var cleanupLocationEntries: [UInt64] = []
        var cleanupLocationCompleted: [UInt64] = []
        var cleanupLocationIncomplete: [UInt64] = []
        private func addLocationCount(_ values: inout [UInt64], _ stage: Int) -> Bool {
            let sum = values[stage].addingReportingOverflow(1)
            values[stage] = sum.overflow ? UInt64.max : sum.partialValue
            return sum.overflow
        }
        private func flushCleanupLocation(_ now: UInt64) {
            guard cleanupLocationActive else { return }
            guard now >= cleanupLocationStarted,
                  cleanupLocationNanoseconds.indices.contains(cleanupLocationStage) else {
                cleanupCostOverflow = true; return
            }
            let sum = cleanupLocationNanoseconds[cleanupLocationStage].addingReportingOverflow(now - cleanupLocationStarted)
            cleanupLocationNanoseconds[cleanupLocationStage] = sum.overflow ? UInt64.max : sum.partialValue
            cleanupCostOverflow = cleanupCostOverflow || sum.overflow
            cleanupLocationStarted = now
        }
        private func closeCleanupLocation(_ now: UInt64, incomplete: Bool) {
            guard cleanupLocationActive else { return }
            flushCleanupLocation(now)
            let overflow: Bool
            if incomplete { overflow = addLocationCount(&cleanupLocationIncomplete, cleanupLocationStage) }
            else { overflow = addLocationCount(&cleanupLocationCompleted, cleanupLocationStage) }
            cleanupCostOverflow = cleanupCostOverflow || overflow
            cleanupLocationActive = false
        }
        func recordCleanupLocationStage(_ stage: Int) {
            let savedErrno = errno; defer { errno = savedErrno }
            guard cleanupCostActive, cleanupDiagnosticStage == 203, cleanupLocationActive else { return }
            guard (0..<4).contains(stage) else { cleanupCostOverflow = true; return }
            let now = DispatchTime.now().uptimeNanoseconds
            closeCleanupLocation(now, incomplete: false)
            cleanupLocationStage = stage; cleanupLocationStarted = now; cleanupLocationActive = true
            let overflow = addLocationCount(&cleanupLocationEntries, stage)
            cleanupCostOverflow = cleanupCostOverflow || overflow
        }
        func beginCleanupCostObservation() {
            cleanupCostEnabled = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_RETENTION_CLEANUP_COSTS"] == "1"
            cleanupCostActive = cleanupCostEnabled; cleanupCostOverflow = false
            cleanupDiagnosticStage = 0
            if cleanupCostEnabled {
                cleanupCostNanoseconds = [UInt64](repeating: 0, count: 212)
                cleanupCostEntries = [UInt64](repeating: 0, count: 212)
                cleanupCostEntries[0] = 1
                cleanupCostStarted = DispatchTime.now().uptimeNanoseconds
            }
        }
        // Called only after the original cleanup deadline exists. Bulk setup
        // and any retirement of previous fixed storage consume that same budget.
        func beginCleanupLocationObservation() {
            let savedErrno = errno; defer { errno = savedErrno }
            cleanupLocationActive = false; cleanupLocationStage = 0
            guard cleanupCostEnabled else { return }
            cleanupLocationNanoseconds = [UInt64](repeating: 0, count: 4)
            cleanupLocationEntries = [UInt64](repeating: 0, count: 4)
            cleanupLocationCompleted = [UInt64](repeating: 0, count: 4)
            cleanupLocationIncomplete = [UInt64](repeating: 0, count: 4)
        }
        // Spill setup stages share emitted bucket 10. Keep the raw failure stage
        // separate so no setup interval disappears from the fixed output roster.
        private func cleanupCostBucket(_ stage: Int) -> Int {
            (11...17).contains(stage) ? 10 : stage
        }
        private func flushCleanupCost(_ now: UInt64) {
            guard cleanupCostActive else { return }
            let bucket = cleanupCostBucket(cleanupDiagnosticStage)
            guard now >= cleanupCostStarted,
                  cleanupCostNanoseconds.indices.contains(bucket) else {
                cleanupCostOverflow = true; return
            }
            let sum = cleanupCostNanoseconds[bucket].addingReportingOverflow(now - cleanupCostStarted)
            cleanupCostNanoseconds[bucket] = sum.overflow ? UInt64.max : sum.partialValue
            cleanupCostOverflow = cleanupCostOverflow || sum.overflow
            cleanupCostStarted = now
        }
        func recordCleanupStage(_ stage: Int) {
            let savedErrno = errno; defer { errno = savedErrno }
            if cleanupCostActive {
                let now = DispatchTime.now().uptimeNanoseconds
                closeCleanupLocation(now, incomplete: false)
                flushCleanupCost(now)
                if stage == 203 {
                    cleanupLocationStage = 0; cleanupLocationStarted = now; cleanupLocationActive = true
                    let overflow = addLocationCount(&cleanupLocationEntries, 0)
                    cleanupCostOverflow = cleanupCostOverflow || overflow
                }
                let bucket = cleanupCostBucket(stage)
                if cleanupCostEntries.indices.contains(bucket) {
                    let sum = cleanupCostEntries[bucket].addingReportingOverflow(1)
                    cleanupCostEntries[bucket] = sum.overflow ? UInt64.max : sum.partialValue
                    cleanupCostOverflow = cleanupCostOverflow || sum.overflow
                } else { cleanupCostOverflow = true }
            }
            cleanupDiagnosticStage = stage
        }
        func finishCleanupCostObservation() {
            let savedErrno = errno; defer { errno = savedErrno }
            if cleanupCostActive {
                let now = DispatchTime.now().uptimeNanoseconds
                closeCleanupLocation(now, incomplete: true)
                flushCleanupCost(now)
            }
            cleanupCostActive = false
        }
        #endif
        init(state: SecureStateDirectory, identity: FileIdentity, flags: UInt32, name: String) {
            self.state = state; stateIdentity = identity; stateFlags = flags; self.name = name
        }
    }
    private final class AttemptShelf: @unchecked Sendable {
        let lock = NSLock()
        var attempts: [Attempt] = []
        func reserve(_ attempt: Attempt) throws {
            lock.lock(); defer { lock.unlock() }
            guard attempts.count < 16, !attempts.contains(where: {
                $0.stateIdentity.device == attempt.stateIdentity.device
                    && $0.stateIdentity.inode == attempt.stateIdentity.inode
            }) else { throw SelectedRepositoryScopeError.cleanupPending }
            attempts.append(attempt)
        }
        #if SHADOW_SYNC_TESTING
        func original(for identity: FileIdentity) -> Attempt? {
            lock.lock(); defer { lock.unlock() }
            return attempts.first { $0.stateIdentity.matchesStableNode(identity) }
        }
        #endif
        func release(_ attempt: Attempt) {
            lock.lock(); defer { lock.unlock() }
            attempts.removeAll { $0 === attempt }
        }
    }
    private static let attemptShelf = AttemptShelf()
    private var attempt: Attempt?
    private var archiveAdmission: RetentionArchiveAdmission?
    private var archivePrimary: RepositoryHandle?, archiveWorktree: RepositoryHandle?
    private var archiveFrozen: FrozenGitConfiguration?
    private var archiveSlot: OwnedFileDescriptor?
    private var archiveSlotPath: String?, archiveRevision: String?, archiveTip: String?

    public init(
        state: SecureStateDirectory,
        account: EffectiveAccount,
        runner: ClosedProcessRunner = ClosedProcessRunner()
    ) {
        self.state = state
        self.account = account
        self.runner = runner
    }

    convenience init(state: SecureStateDirectory, account: EffectiveAccount,
                     runner: ClosedProcessRunner = ClosedProcessRunner(), configurationContext: CommandCustodyContext?) {
        self.init(state: state, account: account, runner: runner)
        self.configurationContext = configurationContext
    }

    public func prepare(
        selection: RemovalSelection,
        cancellation: CancellationToken
    ) -> RetentionPreparation {
        guard selection.intent == .removeWithRecovery
            || selection.includePossibleSecrets else {
            return .incomplete(
                excludedPaths: boundedOmissions(
                    selection.candidate
                ),
                secretShapedPaths: boundedOmissions(
                    selection.candidate
                ).filter(RetentionPath.isSecretShaped),
                reason:
                    "Possible secrets were not authorized; no payload bytes were archived."
            )
        }
        guard selection.includePossibleSecrets else {
            let omitted = boundedOmissions(
                selection.candidate
            )
            return .incomplete(
                excludedPaths: omitted,
                secretShapedPaths:
                    omitted.filter(RetentionPath.isSecretShaped),
                reason:
                    "Possible secrets were not authorized; no payload bytes were archived."
            )
        }
        let artifactID =
            "ret-\(UUID().uuidString.lowercased())"
        var retentionFD: Int32 = -1
        var slotFD: Int32 = -1
        var owner: Attempt?
        let slotName = ".incomplete-\(artifactID)"
        defer {
            archiveAdmission = nil; archivePrimary = nil; archiveWorktree = nil; archiveFrozen = nil; archiveSlot = nil
            archiveSlotPath = nil; archiveRevision = nil; archiveTip = nil
            attempt = nil
        }
        do {
            if cancellation.isCancelled {
                return .cancelled
            }
            var stateInfo = stat()
            guard fstat(state.descriptor.value, &stateInfo) == 0 else {
                throw SecureStateError.systemCall("inspect retention state", errno)
            }
            let reserved = Attempt(state: state, identity: FileIdentity(stateInfo), flags: stateInfo.st_flags, name: slotName)
            try Self.attemptShelf.reserve(reserved)
            owner = reserved; attempt = reserved; reserved.context = configurationContext
            if let context = configurationContext {
                let admission = try context.retentionAdmission(cancellation: cancellation)
                reserved.admission = admission
                let candidate = selection.candidate, source = candidate.clone.sourceSnapshot
                let slotPath = state.path + "/retention/" + slotName
                var paths = DiscoveryCustodyIntent.repositoryMetadataPaths(repositoryPath: source.path)
                if let worktree = candidate.worktree { paths += [worktree.path, worktree.path + "/.git"] }
                paths += [slotPath, slotPath + "/branch.bundle", slotPath + "/.restore-proof", slotPath + "/.restore-proof/repository"]
                try admission.classify(paths: paths, scratch: state.descriptor.value, cancellation: cancellation,
                    budget: CustodyBudget.make(kind: .retentionArchive, workSeconds: 120))
                guard source.policyAdmissionSHA256 == admission.policy.snapshot.admissionSHA256 else { throw CustodyResourceError.invalidResource }
                archiveAdmission = admission
            } else {
                #if !SHADOW_SYNC_TESTING
                throw PublisherPolicyError.unavailable
                #endif
            }
            retentionFD = try ensureRetentionDirectory()
            reserved.parent = OwnedFileDescriptor(retentionFD)
            let parentSnapshot = try cleanupSnapshot(retentionFD)
            reserved.parentIdentity = FileIdentity(parentSnapshot)
            reserved.parentFlags = parentSnapshot.st_flags
            try validateAttempt(reserved, requireSlot: false)
            guard !(try directoryNames(retentionFD)).contains(where: { $0.hasPrefix(".incomplete-") }) else {
                throw SelectedRepositoryScopeError.cleanupPending
            }
            #if SHADOW_SYNC_TESTING
            try testingCleanupHooks?.beforeCreate?(retentionFD, slotName)
            #endif
            guard mkdirat(
                retentionFD,
                slotName,
                0o700
            ) == 0 else {
                throw SecureStateError.systemCall(
                    "create incomplete retention slot",
                    errno
                )
            }
            // mkdirat returns no inode. The first no-follow observation below is
            // conditional on the private parent and existing single-writer authority;
            // it is not proof against an adversarial same-UID replacement before stat.
            // Any observed replacement or open uncertainty retains responsibility.
            reserved.creationUnresolved = true
            #if SHADOW_SYNC_TESTING
            try testingCleanupHooks?.afterCreate?(retentionFD, slotName)
            #endif
            var created = stat()
            guard fstatat(retentionFD, slotName, &created, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw SecureStateError.systemCall("observe retention slot", errno)
            }
            reserved.slotIdentity = FileIdentity(created)
            reserved.slotFlags = created.st_flags
            slotFD = try openPrivateDirectory(slotName, parent: retentionFD)
            reserved.slot = OwnedFileDescriptor(slotFD)
            try validateAttempt(reserved)
            guard try directoryNames(slotFD).isEmpty else {
                throw GitSafetyError.unsafeRepository("new retention slot is not empty")
            }
            reserved.creationUnresolved = false
            #if SHADOW_SYNC_TESTING
            try testingCleanupHooks?.afterOpen?(retentionFD, slotFD, slotName)
            #endif
            let summary = try buildAndVerify(
                selection: selection,
                artifactID: artifactID,
                retentionFD: retentionFD,
                slotFD: slotFD,
                slotName: slotName,
                cancellation: cancellation
            )
            try archiveAdmission?.revalidate()
            if let archivePrimary, let archiveFrozen {
                try archivePrimary.revalidate()
                try RepositoryHandle.validateFrozenConfiguration(descriptor: archiveFrozen.descriptor,
                    directoryDescriptor: archiveFrozen.directoryDescriptor, snapshot: archiveFrozen.snapshot)
            }
            try validateAttempt(reserved)
            guard !reserved.commandUnresolved, !reserved.cleanupUnresolved else {
                throw SelectedRepositoryScopeError.cleanupPending
            }
            guard renameatx_np(
                retentionFD,
                slotName,
                retentionFD,
                artifactID,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                throw SecureStateError.systemCall(
                    "publish retention artifact",
                    errno
                )
            }
            reserved.published = true
            #if SHADOW_SYNC_TESTING
            try testingCleanupHooks?.afterPublish?()
            #endif
            guard fsync(retentionFD) == 0 else {
                throw SecureStateError.systemCall(
                    "fsync retention directory",
                    errno
                )
            }
            try validateAttempt(reserved, requireSlot: false)
            try validateCleanupDirectory(named: artifactID, parent: retentionFD,
                descriptor: slotFD, identity: reserved.slotIdentity!, flags: reserved.slotFlags!)
            Self.attemptShelf.release(reserved)
            return .completed(summary)
        } catch {
            #if SHADOW_SYNC_TESTING
            switch error {
            case SelectedRepositoryScopeError.cleanupPending: testingPreparationFailureFamily = 1
            case SystemGitConfigurationError.cleanupPending: testingPreparationFailureFamily = 2
            case PolicyHelperError.cleanupPending: testingPreparationFailureFamily = 3
            case GitSafetyError.cancelled: testingPreparationFailureFamily = 4
            case is GitSafetyError: testingPreparationFailureFamily = 5
            case is SecureStateError: testingPreparationFailureFamily = 6
            default: testingPreparationFailureFamily = 7
            }
            #endif
            let pending: Bool
            switch error {
            case SelectedRepositoryScopeError.cleanupPending,
                 SystemGitConfigurationError.cleanupPending,
                 PolicyHelperError.cleanupPending:
                pending = true
            default: pending = configurationContext?.hasCleanupPending == true
            }
            // No flag absence is retirement proof. An actual returned handle must
            // deliver .finished through its original registry before deletion.
            if pending || owner?.creationUnresolved == true || owner?.published == true
                || owner?.commandUnresolved == true || owner?.cleanupUnresolved == true {
                return fence(cancellation)
            }
            if let owner {
                do {
                    if owner.slot != nil { try retireSlot(owner) }
                    Self.attemptShelf.release(owner)
                } catch { owner.cleanupUnresolved = true; return fence(cancellation) }
            }
            if case GitSafetyError.cancelled = error { return .cancelled }
            return .incomplete(
                excludedPaths: boundedOmissions(selection.candidate),
                secretShapedPaths: boundedOmissions(selection.candidate).filter(RetentionPath.isSecretShaped),
                reason: Redactor.sanitize(String(describing: error))
            )
        }
    }

    private func fence(_ cancellation: CancellationToken) -> RetentionPreparation {
        configurationContext?.recordCleanupPending()
        cancellation.closeFutureChildAdmissions()
        return .cleanupPending
    }

    #if SHADOW_SYNC_TESTING
    /// The fixture selects an existing live owner; no owner is manufactured from
    /// a path/identity. Production has no retry/release API for unresolved slots.
    func testingCleanupDirectoryNames(deadline: MonotonicDeadline) throws -> [String] {
        try directoryNames(state.descriptor.value, deadline: deadline)
    }

    /// Failure-only observation for the one accepted maximum-payload fixture.
    /// This does not retire, reopen or manufacture an original owner.
    func testingRecordMaximumPayloadFailure(_ result: RetentionPreparation, metadataObserved: Bool) {
        guard ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_DISCOVERY_DIAGNOSTICS"] == "1" else { return }
        let resultCode: Int
        switch result {
        case .completed: return
        case .incomplete: resultCode = 1
        case .cancelled: resultCode = 2
        case .cleanupPending: resultCode = 3
        }
        guard Self.maximumPayloadDiagnosticOnce.claim() else { return }
        let identity = try? cleanupIdentity(state.descriptor.value)
        let owner = identity.flatMap { Self.attemptShelf.original(for: $0) }
        let plan = owner?.plan
        let line = "RETENTION MAXIMUM PAYLOAD FAILURE result=\(resultCode) error_family=\(testingPreparationFailureFamily) metadata_observed=\(metadataObserved) state_observed=\(identity != nil) owner_present=\(owner != nil) stage=\(owner?.cleanupDiagnosticStage ?? -1) elapsed_ns=\(owner?.cleanupDiagnosticElapsed ?? 0) deadline_present=\(owner?.cleanupDiagnosticDeadlinePresent ?? false) expired=\(owner?.cleanupDiagnosticExpired ?? false) nodes=\(plan?.nodeCount ?? -1) order=\(plan?.orderCount ?? -1) next=\(plan?.nextOrder ?? -1) preflight=\(plan?.preflightComplete ?? false) pending_postflight=\(plan?.pendingPostflight != nil) command_pending=\(owner?.commandUnresolved ?? false) cleanup_pending=\(owner?.cleanupUnresolved ?? false) published=\(owner?.published ?? false)\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let owner, owner.cleanupCostEnabled {
            let stages = [0, 1, 10, 20, 30, 40, 50, 60, 70, 80, 90,
                          101, 102, 103, 104, 105, 106, 107, 108,
                          201, 202, 203, 204, 205, 206, 207, 208, 209, 210, 211]
            let fields = stages.map { stage in
                "s\(stage)_ns=\(owner.cleanupCostNanoseconds[stage]) s\(stage)_entries=\(owner.cleanupCostEntries[stage])"
            }.joined(separator: " ")
            let costs = "RETENTION MAXIMUM CLEANUP COSTS exclusive=true active=\(owner.cleanupCostActive) overflow=\(owner.cleanupCostOverflow) " + fields + "\n"
            FileHandle.standardError.write(Data(costs.utf8))
            // A pre-deadline guard refusal has no current location sample.
            // Never index empty storage or reuse a preceding invocation's values.
            let locationAvailable = owner.cleanupDiagnosticDeadlinePresent
            let locationFields = (0..<4).map { stage in
                guard locationAvailable else {
                    return "l\(stage)_ns=0 l\(stage)_entries=0 l\(stage)_completed=0 l\(stage)_incomplete=0"
                }
                return                 "l\(stage)_ns=\(owner.cleanupLocationNanoseconds[stage]) l\(stage)_entries=\(owner.cleanupLocationEntries[stage]) l\(stage)_completed=\(owner.cleanupLocationCompleted[stage]) l\(stage)_incomplete=\(owner.cleanupLocationIncomplete[stage])"
            }.joined(separator: " ")
            let location = "RETENTION MAXIMUM CLEANUP LOCATION COSTS exclusive=true available=\(locationAvailable) active=\(locationAvailable && owner.cleanupLocationActive) overflow=\(owner.cleanupCostOverflow) coarse203_ns=\(owner.cleanupCostNanoseconds[203]) " + locationFields + "\n"
            FileHandle.standardError.write(Data(location.utf8))
        }
    }

    func testingCleanupPlanObservation() throws -> (nodes: Int64, retired: Int64, anonymousReadOnly: Bool) {
        guard let owner = Self.attemptShelf.original(for: try cleanupIdentity(state.descriptor.value)),
              let plan = owner.plan, plan.preflightComplete else { throw SelectedRepositoryScopeError.cleanupPending }
        try validateCleanupSpill(plan.nodes, requireSealed: true)
        try validateCleanupSpill(plan.order, requireSealed: true)
        return (plan.nodeCount, plan.nextOrder, plan.nodes.anonymous && plan.order.anonymous
            && plan.nodes.writer?.closed == true && plan.order.writer?.closed == true)
    }

    func testingCleanupFinalizationObservation() throws -> (rootRemoved: Bool, pendingPostflight: Bool,
                                                            endpointsClosed: Bool, nodes: Int64, retired: Int64) {
        guard let owner = Self.attemptShelf.original(for: try cleanupIdentity(state.descriptor.value)),
              let plan = owner.plan, plan.preflightComplete else { throw SelectedRepositoryScopeError.cleanupPending }
        return (plan.rootRemoved, plan.pendingPostflight != nil,
            plan.nodes.writer?.closed == true && plan.nodes.reader?.closed == true
                && plan.order.writer?.closed == true && plan.order.reader?.closed == true,
            plan.nodeCount, plan.nextOrder)
    }

    func testingUnsealedCleanupPlanRetained() throws -> Bool {
        guard let owner = Self.attemptShelf.original(for: try cleanupIdentity(state.descriptor.value)),
              let plan = owner.plan, !plan.preflightComplete, plan.nextOrder == 0 else { return false }
        for spill in [plan.nodes, plan.order] {
            try validateCleanupSpill(spill)
            guard let writer = spill.writer, (fcntl(try writer.descriptor(), F_GETFL) & O_ACCMODE) == O_WRONLY else { return false }
        }
        return true
    }

    func testingRetireOriginalAttempt() throws {
        guard let owner = Self.attemptShelf.original(for: try cleanupIdentity(state.descriptor.value)),
              !owner.creationUnresolved else { throw SelectedRepositoryScopeError.cleanupPending }
        if let command = owner.command {
            guard command.snapshot().phase == .finished else { throw SelectedRepositoryScopeError.cleanupPending }
            owner.commandUnresolved = false
        }
        guard !owner.commandUnresolved, let parent = owner.parent, let slot = owner.slot,
              let identity = owner.slotIdentity, let slotFlags = owner.slotFlags else { throw SelectedRepositoryScopeError.cleanupPending }
        if owner.published {
            let publishedName = String(owner.name.dropFirst(".incomplete-".count))
            try validateAttempt(owner, requireSlot: false)
            try validateCleanupDirectory(named: publishedName, parent: parent.value,
                descriptor: slot.value, identity: identity, flags: slotFlags)
            guard fsync(parent.value) == 0 else { throw SelectedRepositoryScopeError.cleanupPending }
        } else {
            let deadline = MonotonicDeadline(seconds: 5)
            var slotRemoved = false
            if let plan = owner.plan {
                if plan.preflightComplete {
                    try deleteCleanup(plan, owner: owner, deadline: deadline)
                    slotRemoved = plan.name == owner.name && plan.rootRemoved
                }
                // A failed preflight deleted no payload. Only this fixture may
                // close its actual anonymous descriptions and take a fresh plan
                // after reversing its own fault. No production retry is exposed.
                try closeCleanupPlan(plan, deadline: deadline)
                guard !deadline.hasExpired else { throw SelectedRepositoryScopeError.cleanupPending }
                owner.plan = nil
            }
            if !slotRemoved {
                try retireTree(named: owner.name, parent: parent.value, descriptor: slot.value,
                    identity: identity, flags: slotFlags, owner: owner)
            }
        }
        Self.attemptShelf.release(owner)
    }
    #endif

    public func list() throws -> [RetentionArtifactSummary] {
        let retentionFD = try ensureRetentionDirectory()
        defer { Darwin.close(retentionFD) }
        let names = try directoryNames(retentionFD)
        guard names.allSatisfy({
            RetentionPath.isArtifactID($0)
                || (
                    $0.hasPrefix(".incomplete-ret-")
                        && RetentionPath.isComponent($0)
                )
        }) else {
            throw GitSafetyError.unsafeRepository(
                "retention directory contains an unknown entry"
            )
        }
        if names.contains(where: {
            $0.hasPrefix(".incomplete-")
        }) {
            throw GitSafetyError.unsafeRepository(
                "retention contains an incomplete transaction slot"
            )
        }
        return try names
            .filter { !$0.hasPrefix(".incomplete-") }
            .compactMap { name in
                guard RetentionPath.isArtifactID(name) else {
                    return nil
                }
                let directory = try openPrivateDirectory(
                    name,
                    parent: retentionFD
                )
                defer { Darwin.close(directory) }
                let data = try readFile(
                    "manifest.json",
                    parent: directory,
                    maximumBytes: 4_194_304,
                    requireProtectedArtifact: true
                )
                guard Self.rawManifestIsSupported(data) else {
                    throw GitSafetyError.unsafeRepository(
                        "published retention artifact schema is incompatible"
                    )
                }
                let manifest = try JSONDecoder().decode(
                    RetentionManifest.self,
                    from: data
                )
                guard manifest.schema
                        == shadowSyncRetentionSchema,
                      manifest.artifactID == name,
                      Self.validPublishedManifest(
                          manifest
                      ) else {
                    throw GitSafetyError.unsafeRepository(
                        "published retention artifact is invalid"
                    )
                }
                let summary = RetentionArtifactSummary(
                    manifest: manifest,
                    path: state.path
                        + "/retention/\(name)"
                )
                guard try verify(summary) else {
                    throw GitSafetyError.unsafeRepository(
                        "published retention artifact failed integrity verification"
                    )
                }
                return summary
            }
            .sorted { $0.artifactID < $1.artifactID }
    }

    public func verify(
        _ summary: RetentionArtifactSummary
    ) throws -> Bool {
        guard RetentionPath.isArtifactID(summary.artifactID),
              summary.path == state.path
                + "/retention/\(summary.artifactID)" else {
            return false
        }
        let retentionFD = try ensureRetentionDirectory()
        defer { Darwin.close(retentionFD) }
        let directory = try openPrivateDirectory(
            summary.artifactID,
            parent: retentionFD
        )
        defer { Darwin.close(directory) }
        let data = try readFile(
            "manifest.json",
            parent: directory,
            maximumBytes: 4_194_304,
            requireProtectedArtifact: true
        )
        guard Self.rawManifestIsSupported(data) else {
            return false
        }
        let manifest = try JSONDecoder().decode(
            RetentionManifest.self,
            from: data
        )
        guard manifest.schema == shadowSyncRetentionSchema,
              manifest.artifactID == summary.artifactID,
              manifest.repositoryID == summary.repositoryID,
              manifest.tipOID == summary.tipOID,
              Self.validPublishedManifest(manifest) else {
            return false
        }
        let expectedTopLevel =
            Set(["manifest.json"])
                .union(manifest.componentSHA256.keys)
        guard Set(try directoryNames(directory))
                == expectedTopLevel else {
            return false
        }
        for (name, expected) in manifest.componentSHA256 {
            if name == "index.snapshot" {
                let snapshot = try openPrivateDirectory(
                    name,
                    parent: directory
                )
                defer { Darwin.close(snapshot) }
                let indexHash = try hashFile(
                    "index",
                    parent: snapshot
                )
                var fields = [indexHash]
                let expectedSnapshotEntries =
                    Set(["index"])
                        .union(
                            manifest.sharedIndexFiles.keys
                        )
                guard Set(try directoryNames(snapshot))
                        == expectedSnapshotEntries else {
                    return false
                }
                for shared in manifest.sharedIndexFiles.keys
                    .sorted() {
                    let observed = try hashFile(
                        shared,
                        parent: snapshot
                    )
                    guard observed
                            == manifest.sharedIndexFiles[shared] else {
                        return false
                    }
                    fields.append("\(shared):\(observed)")
                }
                guard Self.sha256(
                    Data(fields.joined(separator: "\n").utf8)
                ) == expected else {
                    return false
                }
            } else if try hashFile(
                name,
                parent: directory
            ) != expected {
                return false
            }
        }
        return true
    }

    private static func rawManifestIsSupported(
        _ data: Data
    ) -> Bool {
        guard let object =
                try? JSONSerialization.jsonObject(
                    with: data
                ) as? [String: Any] else {
            return false
        }
        let required = Set([
            "schema", "artifactID", "repositoryID", "cloneID",
            "commonDirectoryIdentity", "objectFormat", "entries",
            "sharedIndexFiles", "includedPaths", "excludedPaths",
            "secretShapedPaths", "possibleSecretsAuthorized",
            "createdAt", "componentSHA256", "restoreProof",
            "restoreInstructions",
        ])
        let optional = Set([
            "worktreeID", "worktreeRootIdentity",
            "registrationIdentity", "branchRef", "tipOID",
            "indexSHA256", "statusSHA256",
        ])
        let keys = Set(object.keys)
        guard required.isSubset(of: keys),
              keys.isSubset(of: required.union(optional)),
              let common =
                object["commonDirectoryIdentity"]
                    as? [String: Any],
              rawIdentityIsSupported(common),
              let entries =
                object["entries"] as? [[String: Any]],
              entries.allSatisfy(rawEntryIsSupported),
              let proof =
                object["restoreProof"] as? [String: Any],
              rawProofIsSupported(proof) else {
            return false
        }
        for name in [
            "worktreeRootIdentity",
            "registrationIdentity",
        ] {
            if let value = object[name],
               !(value is NSNull) {
                guard let identity =
                        value as? [String: Any],
                      rawIdentityIsSupported(identity) else {
                    return false
                }
            }
        }
        return true
    }

    private static func rawIdentityIsSupported(
        _ value: [String: Any]
    ) -> Bool {
        Set(value.keys) == Set(["device", "inode"])
    }

    private static func rawEntryIsSupported(
        _ value: [String: Any]
    ) -> Bool {
        let required = Set(["path", "kind", "mode", "size"])
        let optional = Set(["symlinkTarget", "contentSHA256"])
        let keys = Set(value.keys)
        return required.isSubset(of: keys)
            && keys.isSubset(of: required.union(optional))
    }

    private static func rawProofIsSupported(
        _ value: [String: Any]
    ) -> Bool {
        let required = Set([
            "verifiedAt", "bundleVerified",
            "connectivityVerified", "entryManifestVerified",
            "indexVerified", "statusDigestVerified",
        ])
        let optional = Set(["exactTipOID"])
        let keys = Set(value.keys)
        return required.isSubset(of: keys)
            && keys.isSubset(of: required.union(optional))
    }

    private static func validPublishedManifest(
        _ manifest: RetentionManifest
    ) -> Bool {
        guard RetentionPath.isArtifactID(
            manifest.artifactID
        ),
        GitHubIdentity.parse(
            "git@github.com:\(manifest.repositoryID).git"
        )?.canonicalName == manifest.repositoryID,
        manifest.cloneID.hasPrefix("clone:"),
        manifest.branchRef == nil
            || GitReferenceSyntax.isValidLocalBranchRef(
                manifest.branchRef!
            ),
        manifest.tipOID == nil
            || RetentionPath.isOID(manifest.tipOID!),
        manifest.objectFormat == "sha1"
            || manifest.objectFormat == "sha256",
        manifest.entries
            == manifest.entries.sorted(by: {
                $0.path < $1.path
            }),
        Set(manifest.entries.map(\.path)).count
            == manifest.entries.count,
        manifest.entries.allSatisfy({
            RetentionPath.isSafeRelative($0.path)
                && $0.mode <= 0o7777
                && (($0.kind == .symbolicLink)
                    == ($0.symlinkTarget != nil))
                && (($0.kind == .regular)
                    == ($0.contentSHA256 != nil))
                && ($0.contentSHA256 == nil
                    || validSHA256($0.contentSHA256!))
        }),
        manifest.includedPaths.allSatisfy(
            RetentionPath.isSafeRelative
        ),
        manifest.includedPaths
            == Array(Set(manifest.includedPaths))
                .sorted(),
        manifest.excludedPaths.allSatisfy(
            RetentionPath.isSafeRelative
        ),
        manifest.excludedPaths
            == Array(Set(manifest.excludedPaths))
                .sorted(),
        manifest.secretShapedPaths.allSatisfy(
            RetentionPath.isSafeRelative
        ),
        manifest.secretShapedPaths
            == Array(Set(manifest.secretShapedPaths))
                .sorted(),
        manifest.possibleSecretsAuthorized,
        manifest.restoreProof.isComplete,
        manifest.restoreProof.exactTipOID
            == manifest.tipOID,
        !manifest.restoreInstructions.isEmpty,
        manifest.componentSHA256.values
            .allSatisfy(validSHA256),
        manifest.sharedIndexFiles.values
            .allSatisfy(validSHA256),
        manifest.sharedIndexFiles.keys.allSatisfy({
            $0.range(
                of: #"^sharedindex\.(?:[0-9a-f]{40}|[0-9a-f]{64})$"#,
                options: .regularExpression
            ) != nil
        }) else {
            return false
        }
        let components =
            Set(manifest.componentSHA256.keys)
        guard components.isSubset(of: [
            "branch.bundle",
            "worktree.tar",
            "index.snapshot",
        ]),
        manifest.excludedPaths.isEmpty,
        Set(manifest.secretShapedPaths)
            == Set(
                manifest.includedPaths.filter(
                    RetentionPath.isSecretShaped
                )
            ) else {
            return false
        }
        if manifest.tipOID != nil,
           !components.contains("branch.bundle") {
            return false
        }
        if manifest.worktreeID != nil {
            return manifest.worktreeRootIdentity != nil
                && manifest.registrationIdentity != nil
                && components.contains("worktree.tar")
                && components.contains("index.snapshot")
                && manifest.indexSHA256.map(validSHA256)
                    == true
                && manifest.statusSHA256.map(validSHA256)
                    == true
                && Set(manifest.entries.map(\.path))
                    == Set(manifest.includedPaths)
        }
        return manifest.branchRef != nil
            && !components.contains("worktree.tar")
            && !components.contains("index.snapshot")
            && manifest.entries.isEmpty
            && manifest.indexSHA256 == nil
            && manifest.statusSHA256 == nil
            && manifest.sharedIndexFiles.isEmpty
    }

    private static func validSHA256(
        _ value: String
    ) -> Bool {
        value.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil
    }

    private func buildAndVerify(
        selection: RemovalSelection,
        artifactID: String,
        retentionFD: Int32,
        slotFD: Int32,
        slotName: String,
        cancellation: CancellationToken
    ) throws -> RetentionArtifactSummary {
        let candidate = selection.candidate
        guard candidate.canSelect,
              candidate.hardExclusion == nil,
              candidate.expectedOID.map(
                RetentionPath.isOID
              ) == true else {
            throw GitSafetyError.unsafeRepository(
                "retention candidate identity is incomplete"
            )
        }
        if let worktree = candidate.worktree {
            guard worktree.verification == .verified,
                  worktree.rootIdentity != nil,
                  worktree.registrationIdentity != nil,
                  worktree.contentEvidenceDigest != nil,
                  worktree.fileState?.operationState
                    == .clear else {
                throw GitSafetyError.unsafeRepository(
                    "incomplete or active worktree state cannot produce complete recovery"
                )
            }
        }
        let source = candidate.clone.sourceSnapshot
        let primary = try RepositoryHandle.open(source)
        let target: RepositoryHandle
        if let worktree = candidate.worktree {
            target = try RepositoryHandle.open(
                source,
                targetWorktree: worktree
            )
        } else {
            target = primary
        }
        let frozen: FrozenGitConfiguration
        if let configurationContext {
            frozen = try primary.freezeConfiguration(account: account,
                retainedConfigurationProbe: SystemGitConfigurationProbe(context: configurationContext, cancellation: cancellation),
                admitConfiguration: { [self] preflight, budget in
                    guard let archiveAdmission else { throw PublisherPolicyError.unavailable }
                    try archiveAdmission.classify(paths: preflight.admissionPaths(account: account),
                        scratch: state.descriptor.value, cancellation: cancellation, budget: budget)
                })
        } else {
            frozen = try primary.freezeConfiguration(account: account)
        }
        if let archiveAdmission {
            try archiveAdmission.revalidate()
            archivePrimary = primary; archiveWorktree = target; archiveFrozen = frozen
            archiveSlot = OwnedFileDescriptor(try RetentionArchiveCommandAuthority.copy(slotFD))
            archiveSlotPath = state.path + "/retention/" + slotName
            archiveTip = candidate.expectedOID
            archiveRevision = candidate.branch?.fullRef ?? candidate.worktree?.attachedBranchRef ?? candidate.expectedOID
        }
        attempt?.primary = primary; attempt?.worktree = target; attempt?.frozen = frozen
        let environment = ClosedProcessRunner.environment(
            account: account,
            frozenConfigPath: frozen.snapshot.frozenPath
        )
        var entries: [RetentionEntry] = []
        var components: [String: String] = [:]
        var includedPaths: [String] = []
        var indexSnapshot: IndexSnapshot?
        var statusData: Data?
        let slotPath = state.path
            + "/retention/\(slotName)"

        if let worktree = candidate.worktree {
            try checkCancellation(cancellation)
            let tarFD = try createArtifactFile(
                "worktree.tar",
                parent: slotFD
            )
            do {
                var writer = TarWriter(descriptor: tarFD)
                entries = try enumerateWorktree(
                    descriptor: target.worktreeDescriptor,
                    relativeParent: "",
                    writer: &writer,
                    count: &includedPaths,
                    totalBytes: 0,
                    cancellation: cancellation
                ).entries
                try writer.finish()
                try finishArtifactFile(tarFD)
            } catch {
                Darwin.close(tarFD)
                throw error
            }
            components["worktree.tar"] = try hashFile(
                "worktree.tar",
                parent: slotFD
            )
            let archived = try TarReader.read(
                readFile(
                    "worktree.tar",
                    parent: slotFD,
                    maximumBytes: Int(Self.maximumBytes)
                )
            ).map(\.entry)
            guard archived == entries else {
                throw GitSafetyError.unsafeRepository(
                    "worktree archive manifest is incomplete"
                )
            }
            includedPaths = entries.map(\.path)
            attempt?.payloadEntries = Dictionary(uniqueKeysWithValues: entries.map {
                (".restore-proof/repository/" + $0.path, $0)
            })
            let location = try indexLocation(
                handle: target,
                worktree: worktree
            )
            indexSnapshot = try captureIndex(
                location: location,
                objectIDBytes:
                    (candidate.expectedOID?.count ?? 40) / 2,
                destination: slotFD
            )
            if let indexSnapshot {
                components["index.snapshot"] =
                    indexSnapshot.componentSHA256
            }
            statusData = try runGit(
                [
                    "-C", target.worktreePath,
                    "status", "--porcelain=v2", "-z",
                    "--untracked-files=all",
                    "--ignored=matching",
                ],
                cwd: target.worktreeDescriptor,
                environment: environment,
                cancellation: cancellation,
                operation: "capture source status"
            ).stdout
        }

        var bundleCreated = false
        if let tip = candidate.expectedOID {
            try checkCancellation(cancellation)
            let revision = candidate.branch?.fullRef
                ?? candidate.worktree?.attachedBranchRef
                ?? tip
            let bundlePath = slotPath + "/branch.bundle"
            _ = try runGit(
                [
                    "--git-dir",
                    primary.identity.commonDirectoryPath,
                    "bundle", "create", bundlePath,
                    revision,
                ],
                cwd: primary.worktreeDescriptor,
                environment: environment,
                cancellation: cancellation,
                operation: "create branch bundle"
            )
            try protectAndSync(
                "branch.bundle",
                parent: slotFD
            )
            components["branch.bundle"] = try hashFile(
                "branch.bundle",
                parent: slotFD
            )
            bundleCreated = true
        }

        let proofName = ".restore-proof"
        guard mkdirat(slotFD, proofName, 0o700) == 0 else {
            throw SecureStateError.systemCall(
                "create restore proof directory",
                errno
            )
        }
        let proofFD = try openPrivateDirectory(
            proofName,
            parent: slotFD
        )
        let proofPath = slotPath + "/\(proofName)"
        defer { Darwin.close(proofFD) }
        let proofSnapshot = try cleanupSnapshot(proofFD)
        let proofIdentity = FileIdentity(proofSnapshot)
        let restorePath = proofPath + "/repository"
        var bundleVerified = false
        var connectivityVerified = false
        if bundleCreated, let tip = candidate.expectedOID {
            _ = try runGit(
                [
                    "--git-dir",
                    primary.identity.commonDirectoryPath,
                    "bundle", "verify",
                    slotPath + "/branch.bundle",
                ],
                cwd: primary.worktreeDescriptor,
                environment: environment,
                cancellation: cancellation,
                operation: "verify branch bundle"
            )
            bundleVerified = true
            _ = try runGit(
                [
                    "clone", "--no-hardlinks",
                    slotPath + "/branch.bundle",
                    restorePath,
                ],
                cwd: proofFD,
                environment: environment,
                cancellation: cancellation,
                operation: "restore branch bundle"
            )
            let restoreFD = Darwin.open(
                restorePath,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard restoreFD >= 0 else {
                throw SecureStateError.systemCall(
                    "open restored repository",
                    errno
                )
            }
            defer { Darwin.close(restoreFD) }
            _ = try runGit(
                [
                    "-C", restorePath,
                    "checkout", "--detach", tip,
                ],
                cwd: restoreFD,
                environment: environment,
                cancellation: cancellation,
                operation:
                    "checkout exact restored tip"
            )
            let observed = try runGit(
                [
                    "-C", restorePath,
                    "rev-parse", "--verify",
                    "\(tip)^{commit}",
                ],
                cwd: restoreFD,
                environment: environment,
                cancellation: cancellation,
                operation: "verify restored tip"
            )
            guard String(
                data: observed.stdout,
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == tip.lowercased() else {
                throw GitSafetyError.unsafeRepository(
                    "restored branch tip differs"
                )
            }
            _ = try runGit(
                [
                    "-C", restorePath,
                    "fsck", "--connectivity-only",
                    "--no-dangling",
                ],
                cwd: restoreFD,
                environment: environment,
                cancellation: cancellation,
                operation: "verify restored connectivity"
            )
            connectivityVerified = true
            if candidate.worktree != nil {
                try clearRestoreWorktree(restoreFD)
                try extractTar(
                    sourceName: "worktree.tar",
                    sourceParent: slotFD,
                    destination: restoreFD
                )
                if let indexSnapshot {
                    try restoreIndex(
                        indexSnapshot,
                        sourceParent: slotFD,
                        restoreRoot: restoreFD
                    )
                }
                let restoredEntries = try manifestEntries(
                    descriptor: restoreFD,
                    relativeParent: "",
                    cancellation: cancellation
                )
                guard restoredEntries == entries else {
                    #if SHADOW_SYNC_TESTING
                    let mismatch = zip(
                        entries,
                        restoredEntries
                    ).first {
                        $0.0 != $0.1
                    }.map {
                        "\($0.0.path):\($0.0.kind.rawValue):\($0.0.mode):\($0.0.size) != \($0.1.path):\($0.1.kind.rawValue):\($0.1.mode):\($0.1.size)"
                    } ?? "count \(entries.count) != \(restoredEntries.count)"
                    throw GitSafetyError.unsafeRepository(
                        "restored worktree manifest differs: \(mismatch)"
                    )
                    #else
                    throw GitSafetyError.unsafeRepository(
                        "restored worktree manifest differs"
                    )
                    #endif
                }
                let restoredStatus = try runGit(
                    [
                        "-C", restorePath,
                        "status", "--porcelain=v2", "-z",
                        "--untracked-files=all",
                        "--ignored=matching",
                    ],
                    cwd: restoreFD,
                    environment: environment,
                    cancellation: cancellation,
                    operation: "verify restored status"
                ).stdout
                guard restoredStatus == statusData else {
                    #if SHADOW_SYNC_TESTING
                    let expectedStatus = String(
                        decoding: statusData ?? Data(),
                        as: UTF8.self
                    ).replacingOccurrences(
                        of: "\0",
                        with: "|"
                    )
                    let observedStatus = String(
                        decoding: restoredStatus,
                        as: UTF8.self
                    ).replacingOccurrences(
                        of: "\0",
                        with: "|"
                    )
                    throw GitSafetyError.unsafeRepository(
                        "restored porcelain-v2 status differs: expected \(expectedStatus) observed \(observedStatus)"
                    )
                    #else
                    throw GitSafetyError.unsafeRepository(
                        "restored porcelain-v2 status differs"
                    )
                    #endif
                }
            }
        } else if candidate.worktree != nil {
            throw GitSafetyError.unsafeRepository(
                "worktree recovery lacks exact restorable history"
            )
        }

        if let worktree = candidate.worktree {
            let finalEntries = try manifestEntries(
                descriptor: target.worktreeDescriptor,
                relativeParent: "",
                cancellation: cancellation
            )
            guard finalEntries == entries else {
                throw GitSafetyError.unsafeRepository(
                    "worktree changed while recovery was being proven"
                )
            }
            guard let indexSnapshot else {
                throw GitSafetyError.unsafeRepository(
                    "worktree index snapshot is unavailable"
                )
            }
            try validateCurrentIndex(
                location: try indexLocation(
                    handle: target,
                    worktree: worktree
                ),
                expected: indexSnapshot,
                objectIDBytes:
                    (candidate.expectedOID?.count ?? 40) / 2
            )
            let finalStatus = try runGit(
                [
                    "-C", target.worktreePath,
                    "status", "--porcelain=v2", "-z",
                    "--untracked-files=all",
                    "--ignored=matching",
                ],
                cwd: target.worktreeDescriptor,
                environment: environment,
                cancellation: cancellation,
                operation: "recheck source status"
            ).stdout
            guard finalStatus == statusData else {
                throw GitSafetyError.unsafeRepository(
                    "worktree status changed while recovery was being proven"
                )
            }
        }
        try primary.revalidate()
        try target.revalidate()
        try checkCancellation(cancellation)
        let proof = RetentionRestoreProof(
            verifiedAt: WallClock.timestamp(),
            exactTipOID: candidate.expectedOID,
            bundleVerified: bundleVerified,
            connectivityVerified: connectivityVerified,
            entryManifestVerified:
                candidate.worktree == nil
                    || !entries.isEmpty
                    || components["worktree.tar"] != nil,
            indexVerified:
                candidate.worktree == nil
                    || indexSnapshot != nil,
            statusDigestVerified:
                candidate.worktree == nil
                    || statusData != nil
        )
        let instructions = restoreInstructions(
            artifactID: artifactID,
            candidate: candidate
        )
        let manifest = try RetentionManifest(
            artifactID: artifactID,
            repositoryID: candidate.repository.id,
            cloneID: candidate.clone.id,
            commonDirectoryIdentity:
                candidate.clone.commonDirectoryIdentity,
            worktreeID: candidate.worktree?.id,
            worktreeRootIdentity:
                candidate.worktree?.rootIdentity,
            registrationIdentity:
                candidate.worktree?.registrationIdentity,
            branchRef: candidate.branch?.fullRef
                ?? candidate.worktree?.attachedBranchRef,
            tipOID: candidate.expectedOID,
            objectFormat:
                candidate.expectedOID?.count == 64
                    ? "sha256" : "sha1",
            entries: entries,
            indexSHA256: indexSnapshot?.indexSHA256,
            sharedIndexFiles:
                indexSnapshot?.sharedFiles ?? [:],
            statusSHA256: statusData.map(Self.sha256),
            includedPaths: includedPaths,
            excludedPaths: [],
            secretShapedPaths:
                includedPaths.filter(RetentionPath.isSecretShaped),
            possibleSecretsAuthorized: true,
            createdAt: WallClock.timestamp(),
            componentSHA256: components,
            restoreProof: proof,
            restoreInstructions: instructions
        )
        let encoded = try JSONEncoder.retention.encode(manifest)
        let manifestFD = try createArtifactFile(
            "manifest.json",
            parent: slotFD
        )
        do {
            try writeAll(encoded, to: manifestFD)
            try finishArtifactFile(manifestFD)
        } catch {
            Darwin.close(manifestFD)
            throw error
        }
        guard fsync(slotFD) == 0 else {
            throw SecureStateError.systemCall(
                "fsync retention artifact",
                errno
            )
        }
        guard let attempt else { throw SelectedRepositoryScopeError.cleanupPending }
        do {
            try retireTree(named: proofName, parent: slotFD, descriptor: proofFD,
                identity: proofIdentity, flags: proofSnapshot.st_flags, owner: attempt)
        } catch {
            attempt.cleanupUnresolved = true
            throw error
        }
        return RetentionArtifactSummary(
            manifest: manifest,
            path: state.path
                + "/retention/\(artifactID)"
        )
    }

    private struct EnumerationResult {
        let entries: [RetentionEntry]
        let totalBytes: UInt64
    }

    private func enumerateWorktree(
        descriptor: Int32,
        relativeParent: String,
        writer: inout TarWriter,
        count: inout [String],
        totalBytes: UInt64,
        cancellation: CancellationToken
    ) throws -> EnumerationResult {
        var directoryBefore = stat()
        guard fstat(descriptor, &directoryBefore) == 0,
              FileIdentity(directoryBefore).isDirectory,
              directoryBefore.st_uid == account.uid else {
            throw GitSafetyError.unsafeRepository(
                "retained directory is unreadable or unowned"
            )
        }
        var entries: [RetentionEntry] = []
        var accumulated = totalBytes
        for name in try directoryNames(descriptor) {
            try checkCancellation(cancellation)
            if relativeParent.isEmpty && name == ".git" {
                continue
            }
            let relative = relativeParent.isEmpty
                ? name : relativeParent + "/" + name
            guard RetentionPath.isSafeRelative(relative),
                  count.count < Self.maximumEntries else {
                throw GitSafetyError.unsafeRepository(
                    "retention entry bound exceeded"
                )
            }
            var before = stat()
            guard fstatat(
                descriptor,
                name,
                &before,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            before.st_uid == account.uid else {
                throw GitSafetyError.unsafeRepository(
                    "retention entry is unreadable or unowned"
                )
            }
            let kind = before.st_mode & S_IFMT
            if kind == S_IFDIR {
                let child = openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard child >= 0 else {
                    throw SecureStateError.systemCall(
                        "open retained directory",
                        errno
                    )
                }
                let entry = try RetentionEntry(
                    path: relative,
                    kind: .directory,
                    mode: UInt16(before.st_mode & 0o7777),
                    size: 0,
                    symlinkTarget: nil,
                    contentSHA256: nil
                )
                try writer.appendDirectory(entry)
                entries.append(entry)
                count.append(relative)
                let nested: EnumerationResult
                do {
                    nested = try enumerateWorktree(
                        descriptor: child,
                        relativeParent: relative,
                        writer: &writer,
                        count: &count,
                        totalBytes: accumulated,
                        cancellation: cancellation
                    )
                } catch {
                    Darwin.close(child)
                    throw error
                }
                Darwin.close(child)
                entries.append(contentsOf: nested.entries)
                accumulated = nested.totalBytes
            } else if kind == S_IFREG {
                guard before.st_nlink == 1,
                      before.st_size >= 0 else {
                    throw GitSafetyError.unsafeRepository(
                        "hard-linked retained files are unsupported"
                    )
                }
                accumulated += UInt64(before.st_size)
                guard accumulated <= Self.maximumBytes else {
                    throw GitSafetyError.unsafeRepository(
                        "retention byte bound exceeded"
                    )
                }
                let file = openat(
                    descriptor,
                    name,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                )
                guard file >= 0 else {
                    throw SecureStateError.systemCall(
                        "open retained file",
                        errno
                    )
                }
                let data: Data
                do {
                    data = try readDescriptor(
                        file,
                        maximumBytes: Int(before.st_size)
                    )
                } catch {
                    Darwin.close(file)
                    throw error
                }
                var after = stat()
                let stable = fstat(file, &after) == 0
                    && Self.sameSnapshot(before, after)
                Darwin.close(file)
                var pathAfter = stat()
                guard stable,
                      fstatat(
                        descriptor,
                        name,
                        &pathAfter,
                        AT_SYMLINK_NOFOLLOW
                      ) == 0,
                      Self.sameSnapshot(before, pathAfter) else {
                    throw GitSafetyError.unsafeRepository(
                        "retained file changed during capture"
                    )
                }
                let entry = try RetentionEntry(
                    path: relative,
                    kind: .regular,
                    mode: UInt16(before.st_mode & 0o7777),
                    size: UInt64(data.count),
                    symlinkTarget: nil,
                    contentSHA256: Self.sha256(data)
                )
                try writer.appendFile(entry, data: data)
                entries.append(entry)
                count.append(relative)
            } else if kind == S_IFLNK {
                guard let target = try readLink(
                    name,
                    parent: descriptor
                ),
                RetentionPath.symlinkIsContained(
                    path: relative,
                    target: target
                ) else {
                    throw GitSafetyError.unsafeRepository(
                        "escaping retained symlink is unsupported"
                    )
                }
                var pathAfter = stat()
                guard fstatat(
                    descriptor,
                    name,
                    &pathAfter,
                    AT_SYMLINK_NOFOLLOW
                ) == 0,
                Self.sameSnapshot(before, pathAfter) else {
                    throw GitSafetyError.unsafeRepository(
                        "retained symlink changed during capture"
                    )
                }
                let entry = try RetentionEntry(
                    path: relative,
                    kind: .symbolicLink,
                    mode: UInt16(before.st_mode & 0o7777),
                    size: 0,
                    symlinkTarget: target,
                    contentSHA256: nil
                )
                try writer.appendSymlink(entry)
                entries.append(entry)
                count.append(relative)
            } else {
                throw GitSafetyError.unsafeRepository(
                    "special retained file is unsupported"
                )
            }
        }
        var directoryAfter = stat()
        guard fstat(descriptor, &directoryAfter) == 0,
              Self.sameSnapshot(
                directoryBefore,
                directoryAfter
              ) else {
            throw GitSafetyError.unsafeRepository(
                "retained directory changed during capture"
            )
        }
        return EnumerationResult(
            entries: entries.sorted { $0.path < $1.path },
            totalBytes: accumulated
        )
    }

    private struct IndexLocation {
        let directoryFD: Int32
        let commonDirectoryFD: Int32
    }

    private struct IndexSnapshot {
        let indexSHA256: String
        let sharedFiles: [String: String]
        let componentSHA256: String
    }

    private func indexLocation(
        handle: RepositoryHandle,
        worktree: Worktree
    ) throws -> IndexLocation {
        _ = worktree
        let directory =
            try handle.duplicateIndexDirectoryDescriptor()
        do {
            return IndexLocation(
                directoryFD: directory,
                commonDirectoryFD:
                    try handle
                        .duplicateCommonDirectoryDescriptor()
            )
        } catch {
            Darwin.close(directory)
            throw error
        }
    }

    private func captureIndex(
        location: IndexLocation,
        objectIDBytes: Int,
        destination: Int32
    ) throws -> IndexSnapshot {
        defer { Darwin.close(location.directoryFD) }
        defer { Darwin.close(location.commonDirectoryFD) }
        let index = try readFile(
            "index",
            parent: location.directoryFD,
            maximumBytes: 67_108_864
        )
        let shared = try GitIndexValidator.validate(
            index,
            objectIDBytes: objectIDBytes
        )
        guard mkdirat(
            destination,
            "index.snapshot",
            0o700
        ) == 0 else {
            throw SecureStateError.systemCall(
                "create index snapshot",
                errno
            )
        }
        let snapshot = try openPrivateDirectory(
            "index.snapshot",
            parent: destination
        )
        defer { Darwin.close(snapshot) }
        let indexFD = try createArtifactFile(
            "index",
            parent: snapshot
        )
        do {
            try writeAll(index, to: indexFD)
            try finishArtifactFile(indexFD)
        } catch {
            Darwin.close(indexFD)
            throw error
        }
        var sharedFiles: [String: String] = [:]
        for hash in shared {
            let name = "sharedindex.\(hash)"
            let source: Int32
            do {
                source = try openSharedIndex(
                    named: name,
                    location: location
                )
            } catch {
                throw error
            }
            let data: Data
            do {
                data = try readDescriptor(
                    source,
                    maximumBytes: 67_108_864
                )
            } catch {
                Darwin.close(source)
                throw error
            }
            Darwin.close(source)
            let nestedDependencies =
                try GitIndexValidator.validate(
                data,
                objectIDBytes: objectIDBytes
            )
            guard nestedDependencies.isEmpty else {
                throw GitSafetyError.unsafeRepository(
                    "nested shared index dependencies are unsupported"
                )
            }
            let file = try createArtifactFile(
                name,
                parent: snapshot
            )
            do {
                try writeAll(data, to: file)
                try finishArtifactFile(file)
            } catch {
                Darwin.close(file)
                throw error
            }
            sharedFiles[name] = Self.sha256(data)
        }
        guard fsync(snapshot) == 0 else {
            throw SecureStateError.systemCall(
                "fsync index snapshot",
                errno
            )
        }
        let indexHash = Self.sha256(index)
        let component = Self.sha256(
            Data(
                (
                    [indexHash]
                        + sharedFiles.keys.sorted().map {
                            "\($0):\(sharedFiles[$0]!)"
                        }
                ).joined(separator: "\n").utf8
            )
        )
        return IndexSnapshot(
            indexSHA256: indexHash,
            sharedFiles: sharedFiles,
            componentSHA256: component
        )
    }

    private func validateCurrentIndex(
        location: IndexLocation,
        expected: IndexSnapshot,
        objectIDBytes: Int
    ) throws {
        defer { Darwin.close(location.directoryFD) }
        defer { Darwin.close(location.commonDirectoryFD) }
        let index = try readFile(
            "index",
            parent: location.directoryFD,
            maximumBytes: 67_108_864
        )
        let shared = try GitIndexValidator.validate(
            index,
            objectIDBytes: objectIDBytes
        ).map { "sharedindex.\($0)" }
        guard Self.sha256(index) == expected.indexSHA256,
              Set(shared) == Set(expected.sharedFiles.keys) else {
            throw GitSafetyError.unsafeRepository(
                "index changed while recovery was being proven"
            )
        }
        for name in shared {
            let descriptor = try openSharedIndex(
                named: name,
                location: location
            )
            let data: Data
            do {
                data = try readDescriptor(
                    descriptor,
                    maximumBytes: 67_108_864
                )
                Darwin.close(descriptor)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            guard Self.sha256(data)
                    == expected.sharedFiles[name],
                  try GitIndexValidator.validate(
                      data,
                      objectIDBytes: objectIDBytes
                  ).isEmpty else {
                throw GitSafetyError.unsafeRepository(
                    "shared index changed or has unsupported dependencies"
                )
            }
        }
    }

    private func openSharedIndex(
        named name: String,
        location: IndexLocation
    ) throws -> Int32 {
        let local = openat(
            location.directoryFD,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if local >= 0 { return local }
        let file = openat(
            location.commonDirectoryFD,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard file >= 0 else {
            throw SecureStateError.systemCall(
                "open required shared index",
                errno
            )
        }
        return file
    }

    private func runGit(
        _ arguments: [String],
        cwd: Int32,
        environment: [String: String],
        cancellation: CancellationToken,
        operation: String
    ) throws -> ProcessResult {
        try RetentionGitCommandPolicy.validate(arguments)
        let result: ProcessResult
        if let admission = archiveAdmission, let primary = archivePrimary, let worktree = archiveWorktree,
           let frozen = archiveFrozen, let slot = archiveSlot, let slotPath = archiveSlotPath,
           let revision = archiveRevision, let tip = archiveTip {
            let budget = try CustodyBudget.make(kind: .retentionArchive, workSeconds: 120)
            let authority = try RetentionArchiveCommandAuthority(admission: admission, primary: primary, worktree: worktree,
                frozen: frozen, destination: slot.value, slotPath: slotPath, cwd: cwd, arguments: arguments,
                revision: revision, tip: tip, statePath: state.path)
            #if SHADOW_SYNC_TESTING
            try testingCustodyHooks?.beforePrepare?(authority)
            #endif
            let command = try admission.context.prepareRetention(authority, budget: budget, cancellation: cancellation)
            try runner.recordRetainedArchive(arguments: arguments, environment: command.resources.request.environment)
            guard let attempt else { throw SelectedRepositoryScopeError.cleanupPending }
            let retained = try RetainedCleanupRegistry.shared.start(command)
            attempt.command = retained; attempt.commandUnresolved = true
            #if SHADOW_SYNC_TESTING
            do { try testingCustodyHooks?.afterStart?(command, retained, cancellation) }
            catch {
                // The hook may throw before the ordinary wait. Keep the actual
                // returned handle, ask its original owner to stop and join only
                // through the existing bounded contract. Never adopt a PID.
                retained.cancel()
                let retired = retained.wait()
                if retired.phase == .finished { attempt.commandUnresolved = false }
                else { admission.context.recordCleanupPending(); cancellation.closeFutureChildAdmissions() }
                throw error
            }
            #endif
            let observer = cancellation.observeCustodyCancellation(retained)
            defer { cancellation.removeCustodyCancellation(observer) }
            let output = retained.wait()
            if output.phase == .finished { attempt.commandUnresolved = false }
            if output.phase == .cleanupPending {
                admission.context.recordCleanupPending(); cancellation.closeFutureChildAdmissions()
                throw SelectedRepositoryScopeError.cleanupPending
            }
            guard output.phase == .finished, let journal = output.journal, journal.phase == .terminal,
                  journal.kind == .retentionArchive, let reason = journal.reason,
                  [CustodyReason.none, .cancelled, .timeout, .outputLimit].contains(reason), let raw = journal.waitStatus else {
                throw GitSafetyError.commandFailed(operation, 125, "Recovery command did not complete under retained custody; incomplete artifacts were preserved.")
            }
            if reason == .cancelled { throw GitSafetyError.cancelled }
            try admission.context.validatePhaseAdmission()
            result = ProcessResult(status: raw & 0x7f == 0 ? Int32((raw >> 8) & 0xff) : 128 + Int32(raw & 0x7f),
                stdout: output.stdout, stderr: output.stderr, stdoutTruncated: reason == .outputLimit,
                stderrTruncated: reason == .outputLimit, outputByteLimit: 16_777_216,
                timedOut: reason == .timeout, cancelled: reason == .cancelled, terminationRequested: reason != .none,
                processID: pid_t(journal.target?.pid ?? 0))
        } else {
            #if SHADOW_SYNC_TESTING
            guard let attempt else { throw SelectedRepositoryScopeError.cleanupPending }
            attempt.commandUnresolved = true
            // This exact testing fallback has an explicit original-anchor contract:
            // pre-spawn throws admit no child; post-spawn throws occur only after
            // sole reap plus all stream EOF. Do not generalize to arbitrary runners.
            defer { attempt.commandUnresolved = false }
            result = try runner.run(command: ClosedProcessCommand(executable: "/usr/bin/git", arguments: arguments),
                environment: environment, workingDirectoryDescriptor: cwd, account: account, timeout: 120, cancellation: cancellation)
            #else
            throw PublisherPolicyError.unavailable
            #endif
        }
        guard result.succeeded,
              !result.stdoutTruncated,
              !result.stderrTruncated else {
            if result.cancelled {
                throw GitSafetyError.cancelled
            }
            throw GitSafetyError.commandFailed(
                operation,
                result.status,
                result.diagnostic
            )
        }
        return result
    }

    private func restoreInstructions(
        artifactID: String,
        candidate: RemovalCandidate
    ) -> [String] {
        var result = [
            "Keep retention/\(artifactID) intact.",
        ]
        if candidate.expectedOID != nil {
            result.append(
                "Clone branch.bundle into a new private directory and verify the recorded exact tip before use."
            )
        }
        if candidate.worktree != nil {
            result.append(
                "Extract worktree.tar into that private clone, then restore index.snapshot/index and every recorded sharedindex file into its Git directory."
            )
            result.append(
                "Verify manifest hashes, modes, symlink targets, index digest, and porcelain-v2 status before resuming work."
            )
        }
        return result
    }

    private func boundedOmissions(
        _ candidate: RemovalCandidate
    ) -> [String] {
        var result: [String] = []
        if candidate.expectedOID != nil {
            result.append("branch.bundle")
        }
        if candidate.worktree != nil {
            result.append("worktree.tar")
            result.append("index.snapshot")
            if let paths = try? omissionPaths(
                candidate
            ) {
                result.append(contentsOf: paths)
            }
        }
        return Array(Set(result)).sorted().prefix(100)
            .map { $0 }
    }

    private func omissionPaths(
        _ candidate: RemovalCandidate
    ) throws -> [String] {
        guard let worktree = candidate.worktree,
              worktree.verification == .verified,
              let expected = worktree.rootIdentity else {
            return []
        }
        let root = Darwin.open(
            worktree.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard root >= 0 else {
            throw SecureStateError.systemCall(
                "open omitted worktree",
                errno
            )
        }
        defer { Darwin.close(root) }
        var info = stat()
        guard fstat(root, &info) == 0,
              RepositoryDirectoryIdentity(
                FileIdentity(info)
              ) == expected else {
            throw GitSafetyError.unsafeRepository(
                "omission inventory identity changed"
            )
        }
        var result: [String] = []
        try collectOmissionPaths(
            descriptor: root,
            prefix: "",
            result: &result
        )
        return result.sorted()
    }

    private func collectOmissionPaths(
        descriptor: Int32,
        prefix: String,
        result: inout [String]
    ) throws {
        guard result.count <= Self.maximumEntries else {
            throw GitSafetyError.unsafeRepository(
                "omission inventory is too large"
            )
        }
        let duplicate = openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard duplicate >= 0,
              let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw SecureStateError.systemCall(
                "enumerate omitted worktree",
                errno
            )
        }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            let name = withUnsafePointer(
                to: &entry.pointee.d_name
            ) {
                $0.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".."
                || (prefix.isEmpty && name == ".git") {
                continue
            }
            let path = prefix.isEmpty
                ? name : prefix + "/" + name
            guard RetentionPath.isSafeRelative(path) else {
                throw GitSafetyError.unsafeRepository(
                    "unsafe omission path"
                )
            }
            var info = stat()
            guard fstatat(
                descriptor,
                name,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw SecureStateError.systemCall(
                    "inspect omitted worktree entry",
                    errno
                )
            }
            result.append(path)
            if (info.st_mode & S_IFMT) == S_IFDIR {
                let child = openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY
                        | O_NOFOLLOW | O_CLOEXEC
                )
                guard child >= 0 else {
                    throw SecureStateError.systemCall(
                        "open omitted worktree directory",
                        errno
                    )
                }
                do {
                    try collectOmissionPaths(
                        descriptor: child,
                        prefix: path,
                        result: &result
                    )
                    Darwin.close(child)
                } catch {
                    Darwin.close(child)
                    throw error
                }
            }
        }
    }

    private func ensureRetentionDirectory() throws -> Int32 {
        if mkdirat(
            state.descriptor.value,
            "retention",
            0o700
        ) != 0, errno != EEXIST {
            throw SecureStateError.systemCall(
                "create retention directory",
                errno
            )
        }
        return try openPrivateDirectory(
            "retention",
            parent: state.descriptor.value
        )
    }

    private func openPrivateDirectory(
        _ name: String,
        parent: Int32,
        requireExactMode: Bool = true
    ) throws -> Int32 {
        guard RetentionPath.isComponent(name) else {
            throw SecureStateError.unsafePath(name)
        }
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SecureStateError.systemCall(
                "open private retention directory",
                errno
            )
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              FileIdentity(info).isDirectory,
              info.st_uid == account.uid,
              (
                requireExactMode
                    ? (info.st_mode & 0o777)
                        == 0o700
                    : (info.st_mode & 0o077) == 0
              ) else {
            Darwin.close(descriptor)
            throw SecureStateError.unsafePath(name)
        }
        return descriptor
    }

    private func createArtifactFile(
        _ name: String,
        parent: Int32
    ) throws -> Int32 {
        guard RetentionPath.isComponent(name) else {
            throw SecureStateError.unsafePath(name)
        }
        let descriptor = openat(
            parent,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o400
        )
        guard descriptor >= 0 else {
            throw SecureStateError.systemCall(
                "create retention component",
                errno
            )
        }
        return descriptor
    }

    private func finishArtifactFile(_ descriptor: Int32) throws {
        guard fchmod(descriptor, 0o400) == 0,
              fsync(descriptor) == 0 else {
            throw SecureStateError.systemCall(
                "finish retention component",
                errno
            )
        }
        Darwin.close(descriptor)
    }

    private func protectAndSync(
        _ name: String,
        parent: Int32
    ) throws {
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SecureStateError.systemCall(
                "open retention component",
                errno
            )
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              FileIdentity(info).isRegular,
              info.st_uid == account.uid,
              info.st_nlink == 1,
              fchmod(descriptor, 0o400) == 0,
              fsync(descriptor) == 0 else {
            throw GitSafetyError.unsafeRepository(
                "retention component is unsafe"
            )
        }
    }

    private func hashFile(
        _ name: String,
        parent: Int32
    ) throws -> String {
        Self.sha256(
            try readFile(
                name,
                parent: parent,
                maximumBytes: Int(Self.maximumBytes),
                requireProtectedArtifact: true
            )
        )
    }

    private func readFile(
        _ name: String,
        parent: Int32,
        maximumBytes: Int,
        requireProtectedArtifact: Bool = false
    ) throws -> Data {
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SecureStateError.systemCall(
                "open retained component",
                errno
            )
        }
        defer { Darwin.close(descriptor) }
        return try readDescriptor(
            descriptor,
            maximumBytes: maximumBytes,
            requireProtectedArtifact:
                requireProtectedArtifact
        )
    }

    private func readDescriptor(
        _ descriptor: Int32,
        maximumBytes: Int,
        requireProtectedArtifact: Bool = false
    ) throws -> Data {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              FileIdentity(info).isRegular,
              info.st_uid == account.uid,
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= maximumBytes,
              !requireProtectedArtifact
                || (
                    (info.st_mode & 0o777)
                            == 0o400
                ) else {
            throw GitSafetyError.unsafeRepository(
                "retained file exceeds its bound"
            )
        }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(
                descriptor,
                &bytes,
                bytes.count
            )
            if count > 0 {
                data.append(contentsOf: bytes.prefix(count))
                guard data.count <= maximumBytes else {
                    throw GitSafetyError.unsafeRepository(
                        "retained file exceeds its bound"
                    )
                }
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw SecureStateError.systemCall(
                "read retained file",
                errno
            )
        }
        var finalInfo = stat()
        guard fstat(descriptor, &finalInfo) == 0,
              Self.sameSnapshot(info, finalInfo) else {
            throw GitSafetyError.unsafeRepository(
                "retained file changed while read"
            )
        }
        return data
    }

    private func writeAll(
        _ data: Data,
        to descriptor: Int32
    ) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    raw.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw SecureStateError.systemCall(
                        "write retention component",
                        errno
                    )
                }
            }
        }
    }

    private func directoryNames(
        _ descriptor: Int32, deadline: MonotonicDeadline? = nil
    ) throws -> [String] {
        let duplicate = openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard duplicate >= 0,
              let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw GitSafetyError.unsafeRepository(
                "retention directory cannot be enumerated"
            )
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            if let deadline, deadline.hasExpired { throw SelectedRepositoryScopeError.cleanupPending }
            errno = 0
            let next = readdir(directory)
            let readError = errno
            if let deadline, deadline.hasExpired { throw SelectedRepositoryScopeError.cleanupPending }
            guard let entry = next else {
                guard readError == 0 else {
                    throw GitSafetyError.unsafeRepository("retention directory enumeration failed")
                }
                break
            }
            let name = withUnsafePointer(
                to: &entry.pointee.d_name
            ) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(cString: $0) }
            }
            if name != ".", name != ".." {
                guard names.count < Self.maximumEntries else {
                    throw GitSafetyError.unsafeRepository("retention directory enumeration bound exceeded")
                }
                names.append(name)
            }
            errno = 0
        }
        guard names.count <= Self.maximumEntries else {
            throw GitSafetyError.unsafeRepository(
                "retention directory enumeration failed"
            )
        }
        if let deadline, deadline.hasExpired { throw SelectedRepositoryScopeError.cleanupPending }
        let sorted = names.sorted()
        if let deadline, deadline.hasExpired { throw SelectedRepositoryScopeError.cleanupPending }
        return sorted
    }

    private func readLink(
        _ name: String,
        parent: Int32
    ) throws -> String? {
        var bytes = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let count = readlinkat(
            parent,
            name,
            &bytes,
            bytes.count
        )
        guard count >= 0, count < bytes.count,
              let value = String(
                bytes: bytes.prefix(count),
                encoding: .utf8
              ),
              !value.contains("\0") else {
            throw GitSafetyError.unsafeRepository(
                "retained symlink target is malformed"
            )
        }
        return value
    }

    // Process-local native records: no persisted schema, pathname reopening or
    // reconstruction API. Only this Attempt owns the original descriptions.
    private struct CleanupNode {
        let name: String, before: stat
        let parentIndex: Int64, depth: Int
    }
    private final class CleanupEndpoint {
        enum State { case open(Int32), closed, ambiguous }
        private(set) var state: State
        init(_ fd: Int32) { state = .open(fd) }
        func descriptor() throws -> Int32 {
            guard case let .open(fd) = state else { throw SelectedRepositoryScopeError.cleanupPending }
            return fd
        }
        var closed: Bool { if case .closed = state { return true }; return false }
        func closeOnce() throws {
            guard case let .open(fd) = state else {
                if closed { return }
                throw SelectedRepositoryScopeError.cleanupPending
            }
            // Transition before close. An ambiguous result must never retry,
            // deinit-close, inspect, signal or adopt this numeric descriptor.
            state = .ambiguous
            guard Darwin.close(fd) == 0 else { throw SelectedRepositoryScopeError.cleanupPending }
            state = .closed
        }
        // Deliberately no deinit close. Failure retains this endpoint in Attempt.
    }
    private final class CleanupSpill {
        var writer: CleanupEndpoint?, reader: CleanupEndpoint?
        var original: stat?, sealed: stat?
        var anonymous = false
        var bytes: Int64 = 0
    }
    #if SHADOW_SYNC_TESTING
    private final class CleanupDiagnosticOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var emitted = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !emitted else { return false }
            emitted = true
            return true
        }
    }
    // One opt-in, failure-only T12 observation. Values are closed booleans,
    // masked modes/flags and fixed codes; no names, identities or owners escape.
    // This collector never participates in cleanup admission or retry.
    private final class MixedCleanupObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var active = false, emitted = false
        private var preflight: String?
        func begin() {
            lock.lock(); defer { lock.unlock() }
            active = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_DISCOVERY_DIAGNOSTICS"] == "1"
            preflight = nil
        }
        func end() {
            lock.lock(); defer { lock.unlock() }
            active = false; preflight = nil
        }
        func record(_ value: String) {
            lock.lock(); defer { lock.unlock() }
            guard active, !emitted, preflight == nil else { return }
            preflight = value
        }
        func failure(_ outcomes: [Bool]) {
            lock.lock(); defer { lock.unlock() }
            guard active, !emitted, outcomes.count == 13 else { return }
            emitted = true
            let labels = ["confirmation", "cancelled", "terminal", "source_present", "clean_present",
                          "one_artifact", "restore_proven", "no_incomplete", "no_awa_log", "no_host_socket",
                          "recovered_plan", "recovered_report", "requires_review"]
            let result = zip(labels, outcomes).map { "\($0.0)=\($0.1)" }.joined(separator: " ")
            let line = "BODY3 MIXED RECOVERY FAILURE preflight_observed=\(preflight != nil) \(preflight ?? "") outcome_observation=post_assertion \(result)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
    private static let mixedCleanupObservation = MixedCleanupObservation()
    static func testingBeginMixedCleanupObservation() { mixedCleanupObservation.begin() }
    static func testingEndMixedCleanupObservation() { mixedCleanupObservation.end() }
    static func testingEmitMixedCleanupFailure(_ outcomes: [Bool]) { mixedCleanupObservation.failure(outcomes) }

    private static let cleanupDiagnosticOnce = CleanupDiagnosticOnce()
    private static let maximumPayloadDiagnosticOnce = CleanupDiagnosticOnce()
    private func emitCleanupDiagnostic(_ owner: Attempt, deadline: MonotonicDeadline?, started: UInt64) {
        guard ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_DISCOVERY_DIAGNOSTICS"] == "1" else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        owner.cleanupDiagnosticElapsed = now >= started ? now - started : 0
        owner.cleanupDiagnosticDeadlinePresent = deadline != nil
        owner.cleanupDiagnosticExpired = deadline?.hasExpired ?? false
        guard Self.cleanupDiagnosticOnce.claim() else { return }
        let plan = owner.plan
        let line = "RETENTION CLEANUP FAILURE stage=\(owner.cleanupDiagnosticStage) elapsed_ns=\(now >= started ? now - started : 0) deadline_present=\(deadline != nil) expired=\(deadline?.hasExpired ?? false) nodes=\(plan?.nodeCount ?? -1) order=\(plan?.orderCount ?? -1) next=\(plan?.nextOrder ?? -1) preflight=\(plan?.preflightComplete ?? false) root_removed=\(plan?.rootRemoved ?? false) pending_postflight=\(plan?.pendingPostflight != nil) nodes_anonymous=\(plan?.nodes.anonymous ?? false) order_anonymous=\(plan?.order.anonymous ?? false) nodes_sealed=\(plan?.nodes.writer?.closed ?? false) order_sealed=\(plan?.order.writer?.closed ?? false) command_pending=\(owner.commandUnresolved)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
    #endif
    private final class CleanupPlan {
        let name: String, root: OwnedFileDescriptor
        let nodes = CleanupSpill(), order = CleanupSpill()
        var nodeCount: Int64 = 0, orderCount: Int64 = 0, nextOrder: Int64 = 0
        var preflightComplete = false, rootRemoved = false
        var pendingPostflight: Int64?
        init(name: String, root: OwnedFileDescriptor) { self.name = name; self.root = root }
    }
    private struct CleanupAncestor {
        let node: CleanupNode, descriptor: OwnedFileDescriptor, parent: Int32
    }
    // Lexical observations only, never admission or restart/recovery state.
    // This stack is confined to one deleteCleanup call and one original plan.
    private struct CleanupRetainedAncestor {
        let index: Int64, ancestor: CleanupAncestor
    }
    // One name, one native stat and a checked parent index per record. At most
    // one <=10,000-name roster is live; it is spilled and released BEFORE
    // recursion. Traversal retains at most maximumCleanupDepth ancestors.
    private static let cleanupRecordBytes = 16 + MemoryLayout<stat>.size + Int(MAXNAMLEN) + 1

    private func cleanupSnapshot(_ descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw SecureStateError.systemCall("inspect owned retention descriptor", errno)
        }
        return info
    }
    private func cleanupIdentity(_ descriptor: Int32) throws -> FileIdentity {
        FileIdentity(try cleanupSnapshot(descriptor))
    }
    private static func cleanupFlagsAllowed(_ flags: UInt32) -> Bool {
        flags & ~(UInt32(UF_NODUMP) | UInt32(UF_HIDDEN)) == 0
    }
    private func validateAttempt(_ owner: Attempt, requireSlot: Bool = true) throws {
        _ = try PolicyAuthorityFile.privateStateACLObservation(owner.state.descriptor.value) { observed in
            guard let stateNow = observed else {
                throw SecureStateError.systemCall("inspect owned retention descriptor", errno)
            }
            guard owner.parent != nil, owner.parentIdentity != nil, owner.parentFlags != nil,
                  FileIdentity(stateNow).matchesStableNode(owner.stateIdentity),
                  stateNow.st_flags == owner.stateFlags, Self.cleanupFlagsAllowed(stateNow.st_flags),
                  (stateNow.st_mode & 0o7777) == 0o700 else { throw SelectedRepositoryScopeError.cleanupPending }
        }
        guard let parent = owner.parent, let expected = owner.parentIdentity, let parentFlags = owner.parentFlags else {
            throw SelectedRepositoryScopeError.cleanupPending
        }
        try validateCleanupDirectory(named: "retention", parent: owner.state.descriptor.value,
            descriptor: parent.value, identity: expected, flags: parentFlags)
        if requireSlot {
            guard let slot = owner.slot, let identity = owner.slotIdentity, let flags = owner.slotFlags,
                  !owner.published else { throw SelectedRepositoryScopeError.cleanupPending }
            try validateCleanupDirectory(named: owner.name, parent: parent.value,
                descriptor: slot.value, identity: identity, flags: flags)
        }
    }
    private func validateCleanupDirectory(named name: String, parent: Int32,
                                          descriptor: Int32, identity: FileIdentity, flags: UInt32) throws {
        _ = try PolicyAuthorityFile.privateStateACLObservation(descriptor) { observed in
            var named = stat()
            guard let held = observed,
                  fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  identity.matchesStableNode(FileIdentity(held)), identity.matchesStableNode(FileIdentity(named)),
                  held.st_uid == account.uid, (held.st_mode & S_IFMT) == S_IFDIR,
                  (held.st_mode & 0o7777) == 0o700,
                  held.st_flags == flags, named.st_flags == flags, Self.cleanupFlagsAllowed(flags) else {
                throw GitSafetyError.unsafeRepository("retention cleanup directory identity changed")
            }
        }
    }
    private func validateCleanupNode(_ node: CleanupNode, descriptor: Int32, parent: Int32) throws {
        _ = try PolicyAuthorityFile.privateStateACLObservation(descriptor) { observed in
            var named = stat()
            let before = node.before, kind = before.st_mode & S_IFMT
            guard let held = observed,
                  fstatat(parent, node.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  FileIdentity(before).matchesStableNode(FileIdentity(held)),
                  FileIdentity(before).matchesStableNode(FileIdentity(named)),
                  held.st_flags == before.st_flags, named.st_flags == before.st_flags,
                  Self.cleanupFlagsAllowed(before.st_flags),
                  kind == S_IFDIR || (held.st_nlink == 1 && named.st_nlink == 1
                    && Self.sameSnapshot(before, held) && Self.sameSnapshot(before, named)) else {
                throw GitSafetyError.unsafeRepository("retention cleanup named and held nodes differ")
            }
        }
    }
    private static func sameCleanupFile(_ lhs: stat, _ rhs: stat) -> Bool {
        sameSnapshot(lhs, rhs) && lhs.st_uid == rhs.st_uid && lhs.st_gid == rhs.st_gid
            && lhs.st_nlink == rhs.st_nlink && lhs.st_flags == rhs.st_flags
    }

    private func createCleanupSpill(_ spill: CleanupSpill, owner: Attempt) throws {
        guard let slot = owner.slot else { throw SelectedRepositoryScopeError.cleanupPending }
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(11)
        #endif
        try validateAttempt(owner)
        let name = ".cleanup-plan-" + UUID().uuidString.lowercased()
        // createArtifactFile gives this caller the actual exclusive writer.
        spill.writer = CleanupEndpoint(try createArtifactFile(name, parent: slot.value))
        let writer = try spill.writer!.descriptor()
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(12)
        #endif
        let read = openat(slot.value, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard read >= 0 else { throw SecureStateError.systemCall("open original cleanup plan reader", errno) }
        spill.reader = CleanupEndpoint(read)
        let original = try cleanupSnapshot(writer)
        var named = stat()
        let held = try cleanupSnapshot(read)
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(13)
        #endif
        guard fstatat(slot.value, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              original.st_uid == account.uid, (original.st_mode & (S_IFMT | 0o7777)) == S_IFREG | 0o400,
              original.st_nlink == 1, original.st_size == 0, original.st_flags == 0,
              Self.sameCleanupFile(original, held), Self.sameCleanupFile(original, named),
              held.st_flags == original.st_flags, named.st_flags == original.st_flags,
              (fcntl(writer, F_GETFL) & O_ACCMODE) == O_WRONLY,
              (fcntl(read, F_GETFL) & O_ACCMODE) == O_RDONLY,
              fcntl(writer, F_GETFD) == FD_CLOEXEC, fcntl(read, F_GETFD) == FD_CLOEXEC else {
            throw SelectedRepositoryScopeError.cleanupPending
        }
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(14)
        #endif
        spill.original = original
        _ = try PolicyAuthorityFile.privateStateACL(writer)
        _ = try PolicyAuthorityFile.privateStateACL(read)
        try validateAttempt(owner)
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(15)
        #endif
        let finalWriter = try cleanupSnapshot(writer), finalReader = try cleanupSnapshot(read)
        guard fstatat(slot.value, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              Self.sameCleanupFile(original, finalWriter), Self.sameCleanupFile(original, finalReader),
              Self.sameCleanupFile(original, named), named.st_flags == 0,
              finalWriter.st_flags == 0, finalReader.st_flags == 0,
              unlinkat(slot.value, name, 0) == 0 else { throw SelectedRepositoryScopeError.cleanupPending }
        spill.anonymous = true
        // Only the freshly created plan name is retired here. No payload tree
        // node may be unlinked before complete preflight and writer retirement.
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(16)
        #endif
        try validateCleanupSpill(spill)
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(17)
        #endif
        guard fstatat(slot.value, name, &named, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
              fsync(slot.value) == 0 else { throw SelectedRepositoryScopeError.cleanupPending }
    }
    private func validateCleanupSpill(_ spill: CleanupSpill, requireSealed: Bool = false) throws {
        guard spill.anonymous, let original = spill.original, let reader = spill.reader else {
            throw SelectedRepositoryScopeError.cleanupPending
        }
        let fd = try reader.descriptor()
        let now = try PolicyAuthorityFile.privateStateACLObservation(fd) { observed in
            guard let now = observed else {
                throw SecureStateError.systemCall("inspect owned retention descriptor", errno)
            }
            guard FileIdentity(original).matchesStableNode(FileIdentity(now)), now.st_nlink == 0,
                  now.st_flags == original.st_flags, now.st_size == spill.bytes,
                  (fcntl(fd, F_GETFL) & O_ACCMODE) == O_RDONLY,
                  fcntl(fd, F_GETFD) == FD_CLOEXEC else { throw SelectedRepositoryScopeError.cleanupPending }
        }
        if requireSealed {
            guard spill.writer?.closed == true, let sealed = spill.sealed,
                  Self.sameSnapshot(sealed, now), sealed.st_flags == now.st_flags else {
                throw SelectedRepositoryScopeError.cleanupPending
            }
        }
    }
    private func appendCleanupBytes(_ data: Data, to spill: CleanupSpill, deadline: MonotonicDeadline) throws {
        guard !data.isEmpty, data.count <= Self.cleanupRecordBytes, !deadline.hasExpired,
              let writer = spill.writer else { throw SelectedRepositoryScopeError.cleanupPending }
        let end = spill.bytes.addingReportingOverflow(Int64(data.count))
        guard !end.overflow, end.partialValue >= spill.bytes else { throw SelectedRepositoryScopeError.cleanupPending }
        try validateCleanupSpill(spill)
        let fd = try writer.descriptor()
        let before = try cleanupSnapshot(fd)
        guard let original = spill.original, FileIdentity(original).matchesStableNode(FileIdentity(before)),
              before.st_nlink == 0, before.st_flags == original.st_flags,
              before.st_size == spill.bytes, (fcntl(fd, F_GETFL) & O_ACCMODE) == O_WRONLY,
              fcntl(fd, F_GETFD) == FD_CLOEXEC else { throw SelectedRepositoryScopeError.cleanupPending }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                guard !deadline.hasExpired else { throw SelectedRepositoryScopeError.cleanupPending }
                let written = pwrite(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, off_t(spill.bytes + Int64(offset)))
                if written > 0 { offset += written }
                else if written < 0 && errno == EINTR { continue }
                else { throw SecureStateError.systemCall("write original cleanup plan", errno) }
            }
        }
        spill.bytes = end.partialValue
        try validateCleanupSpill(spill)
    }
    private func readCleanupBytes(_ spill: CleanupSpill, offset: Int64, count: Int,
                                  deadline: MonotonicDeadline, sealed: Bool = false) throws -> Data {
        let end = offset.addingReportingOverflow(Int64(count))
        guard offset >= 0, count > 0, count <= Self.cleanupRecordBytes, !end.overflow,
              end.partialValue <= spill.bytes, !deadline.hasExpired, let reader = spill.reader else {
            throw SelectedRepositoryScopeError.cleanupPending
        }
        try validateCleanupSpill(spill, requireSealed: sealed)
        let fd = try reader.descriptor()
        var bytes = Data(count: count)
        try bytes.withUnsafeMutableBytes { raw in
            var done = 0
            while done < raw.count {
                guard !deadline.hasExpired else { throw SelectedRepositoryScopeError.cleanupPending }
                let n = pread(fd, raw.baseAddress!.advanced(by: done), raw.count - done, off_t(offset + Int64(done)))
                if n > 0 { done += n }
                else if n < 0 && errno == EINTR { continue }
                else { throw SelectedRepositoryScopeError.cleanupPending }
            }
        }
        try validateCleanupSpill(spill, requireSealed: sealed)
        return bytes
    }
    private func sealCleanupSpill(_ spill: CleanupSpill, deadline: MonotonicDeadline) throws {
        guard !deadline.hasExpired, let writer = spill.writer else { throw SelectedRepositoryScopeError.cleanupPending }
        try validateCleanupSpill(spill)
        let fd = try writer.descriptor()
        guard fsync(fd) == 0 else { throw SelectedRepositoryScopeError.cleanupPending }
        try validateCleanupSpill(spill)
        try writer.closeOnce()
        guard writer.closed, let reader = spill.reader else { throw SelectedRepositoryScopeError.cleanupPending }
        spill.sealed = try cleanupSnapshot(reader.descriptor())
        try validateCleanupSpill(spill, requireSealed: true)
    }
    private func closeCleanupPlan(_ plan: CleanupPlan, deadline: MonotonicDeadline) throws {
        // No cancellation, retry or deinitializer can turn an ambiguous close
        // into retirement proof. Retain all remaining descriptions on failure.
        for spill in [plan.nodes, plan.order] {
            if let writer = spill.writer {
                guard !deadline.hasExpired else { throw SelectedRepositoryScopeError.cleanupPending }
                try writer.closeOnce()
                guard !deadline.hasExpired else { throw SelectedRepositoryScopeError.cleanupPending }
            }
            if let reader = spill.reader {
                guard !deadline.hasExpired else { throw SelectedRepositoryScopeError.cleanupPending }
                try reader.closeOnce()
                guard !deadline.hasExpired else { throw SelectedRepositoryScopeError.cleanupPending }
            }
        }
    }
    private func cleanupRecordOffset(_ index: Int64) throws -> Int64 {
        let value = index.multipliedReportingOverflow(by: Int64(Self.cleanupRecordBytes))
        guard index >= 0, !value.overflow else { throw SelectedRepositoryScopeError.cleanupPending }
        return value.partialValue
    }
    private func appendCleanupNode(_ node: CleanupNode, plan: CleanupPlan, deadline: MonotonicDeadline) throws -> Int64 {
        let name = Data(node.name.utf8)
        guard RetentionPath.isComponent(node.name), !name.isEmpty, name.count <= Int(MAXNAMLEN),
              node.depth >= 0, node.depth < Self.maximumCleanupDepth,
              (plan.nodeCount == 0 ? node.parentIndex == -1 && node.depth == 0 : node.parentIndex >= 0 && node.parentIndex < plan.nodeCount),
              plan.nodeCount < Int64.max else { throw SelectedRepositoryScopeError.cleanupPending }
        let index = plan.nodeCount
        guard try cleanupRecordOffset(index) == plan.nodes.bytes else { throw SelectedRepositoryScopeError.cleanupPending }
        var parent = node.parentIndex, depth = UInt32(node.depth), length = UInt32(name.count), before = node.before
        var record = Data()
        withUnsafeBytes(of: &parent) { record.append(contentsOf: $0) }
        withUnsafeBytes(of: &depth) { record.append(contentsOf: $0) }
        withUnsafeBytes(of: &length) { record.append(contentsOf: $0) }
        withUnsafeBytes(of: &before) { record.append(contentsOf: $0) }
        record.append(name)
        record.append(Data(count: Self.cleanupRecordBytes - record.count))
        try appendCleanupBytes(record, to: plan.nodes, deadline: deadline)
        plan.nodeCount += 1
        return index
    }
    private func readCleanupNode(_ index: Int64, plan: CleanupPlan, deadline: MonotonicDeadline) throws -> CleanupNode {
        guard index >= 0, index < plan.nodeCount else { throw SelectedRepositoryScopeError.cleanupPending }
        let spill = plan.nodes, offset = try cleanupRecordOffset(index), count = Self.cleanupRecordBytes
        let sealed = plan.preflightComplete
        let end = offset.addingReportingOverflow(Int64(count))
        guard offset >= 0, count > 0, count <= Self.cleanupRecordBytes, !end.overflow,
              end.partialValue <= spill.bytes, !deadline.hasExpired, let reader = spill.reader else {
            throw SelectedRepositoryScopeError.cleanupPending
        }
        try validateCleanupSpill(spill, requireSealed: sealed)
        let fd = try reader.descriptor()
        // Every byte is filled before decoding; a partial read or failed fresh
        // spill check throws inside this scope without exposing the buffer.
        return try withUnsafeTemporaryAllocation(byteCount: count, alignment: MemoryLayout<stat>.alignment) { raw in
            var done = 0
            while done < raw.count {
                guard !deadline.hasExpired else { throw SelectedRepositoryScopeError.cleanupPending }
                let n = pread(fd, raw.baseAddress!.advanced(by: done), raw.count - done, off_t(offset + Int64(done)))
                if n > 0 { done += n }
                else if n < 0 && errno == EINTR { continue }
                else { throw SelectedRepositoryScopeError.cleanupPending }
            }
            try validateCleanupSpill(spill, requireSealed: sealed)
            return try Self.decodeCleanupNode(index, bytes: UnsafeRawBufferPointer(raw))
        }
    }
    private static func decodeCleanupNode(_ index: Int64, bytes raw: UnsafeRawBufferPointer) throws -> CleanupNode {
        // Header loads support unaligned borrowed storage. Strict UTF-8 decoding
        // returns an owned String; the stat and scalar fields are copied values.
        // No decoded value outlives or substitutes for a later live spill check.
        guard index >= 0, raw.count == cleanupRecordBytes else {
            throw SelectedRepositoryScopeError.cleanupPending
        }
        let parent = raw.loadUnaligned(fromByteOffset: 0, as: Int64.self)
        let depth = raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
        let length = raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        let start = 16 + MemoryLayout<stat>.size
        guard length > 0, length <= UInt32(MAXNAMLEN), depth < UInt32(maximumCleanupDepth),
              (index == 0 ? parent == -1 && depth == 0 : parent >= 0 && parent < index && depth > 0),
              let name = String(bytes: raw[start..<(start + Int(length))], encoding: .utf8),
              RetentionPath.isComponent(name) else { throw SelectedRepositoryScopeError.cleanupPending }
        let before = raw.loadUnaligned(fromByteOffset: 16, as: stat.self)
        return CleanupNode(name: name, before: before, parentIndex: parent, depth: Int(depth))
    }
    #if SHADOW_SYNC_TESTING
    static func testingDecodeCleanupRecord(_ bytes: Data, index: Int64)
        throws -> (name: String, before: stat, parent: Int64, depth: Int) {
        let node = try bytes.withUnsafeBytes { raw in
            try decodeCleanupNode(index, bytes: raw)
        }
        return (node.name, node.before, node.parentIndex, node.depth)
    }
    #endif
    private func appendCleanupOrder(_ index: Int64, plan: CleanupPlan, deadline: MonotonicDeadline) throws {
        guard plan.orderCount < Int64.max / 8 else { throw SelectedRepositoryScopeError.cleanupPending }
        var value = index
        let bytes = withUnsafeBytes(of: &value) { Data($0) }
        try appendCleanupBytes(bytes, to: plan.order, deadline: deadline)
        plan.orderCount += 1
    }
    private func cleanupChildRoster(_ node: CleanupNode, index: Int64, descriptor: Int32,
                                    plan: CleanupPlan, deadline: MonotonicDeadline) throws -> Range<Int64> {
        // This helper's bounded array dies before any recursive call is made.
        let names = try directoryNames(descriptor, deadline: deadline)
        let start = plan.nodeCount
        for name in names {
            guard !deadline.hasExpired else { throw SelectedRepositoryScopeError.cleanupPending }
            var before = stat()
            guard fstatat(descriptor, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw SecureStateError.systemCall("inspect cleanup roster node", errno)
            }
            _ = try appendCleanupNode(CleanupNode(name: name, before: before, parentIndex: index, depth: node.depth + 1),
                plan: plan, deadline: deadline)
        }
        return start..<plan.nodeCount
    }
    private func validateCleanupRoster(_ range: Range<Int64>, descriptor: Int32,
                                       plan: CleanupPlan, deadline: MonotonicDeadline) throws {
        let names = try directoryNames(descriptor, deadline: deadline)
        guard Int64(names.count) == range.upperBound - range.lowerBound else { throw SelectedRepositoryScopeError.cleanupPending }
        for (offset, name) in names.enumerated() {
            guard try readCleanupNode(range.lowerBound + Int64(offset), plan: plan, deadline: deadline).name == name else {
                throw SelectedRepositoryScopeError.cleanupPending
            }
        }
    }
    private func preflightCleanup(_ index: Int64, parent: Int32, held: Int32? = nil,
                                  relativePath: String, plan: CleanupPlan, owner: Attempt,
                                  deadline: MonotonicDeadline) throws {
        guard !deadline.hasExpired else { throw SelectedRepositoryScopeError.cleanupPending }
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(101)
        #endif
        let node = try readCleanupNode(index, plan: plan, deadline: deadline)
        let before = node.before, kind = before.st_mode & S_IFMT
        let acceptedPayloadMode = owner.payloadEntries[relativePath].map { entry in
            let matchesKind = (entry.kind == .directory && kind == S_IFDIR)
                || (entry.kind == .regular && kind == S_IFREG) || (entry.kind == .symbolicLink && kind == S_IFLNK)
            return matchesKind && entry.mode == UInt16(before.st_mode & 0o7777)
        } == true
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(102)
        #endif
        #if SHADOW_SYNC_TESTING
        // device: 0=not reached, 1=match, 2=mismatch, 3=lookup threw.
        var observedDevice = 0
        func observedParentDeviceMatches() throws -> Bool {
            do {
                let matches = UInt64(before.st_dev) == (try cleanupIdentity(parent)).device
                observedDevice = matches ? 1 : 2
                return matches
            } catch {
                observedDevice = 3
                throw error
            }
        }
        do {
            guard before.st_uid == account.uid, try observedParentDeviceMatches(),
                  kind == S_IFDIR || kind == S_IFREG || kind == S_IFLNK,
                  kind == S_IFDIR || before.st_nlink == 1,
                  acceptedPayloadMode || ((kind == S_IFLNK || (before.st_mode & 0o022) == 0) && (before.st_mode & 0o7000) == 0),
                  Self.cleanupFlagsAllowed(before.st_flags) else {
                throw GitSafetyError.unsafeRepository("retention cleanup type, links, flags or mode is unsafe")
            }
        } catch {
            let entry = owner.payloadEntries[relativePath]
            let entryKindMatches = entry.map {
                ($0.kind == .directory && kind == S_IFDIR)
                    || ($0.kind == .regular && kind == S_IFREG)
                    || ($0.kind == .symbolicLink && kind == S_IFLNK)
            } ?? false
            let kindCode = kind == S_IFDIR ? 1 : (kind == S_IFREG ? 2 : (kind == S_IFLNK ? 3 : 0))
            // component: 0=other, 1=slot root, 2=worktree archive, 3=index,
            // 4=bundle, 5=proof root, 6=proof repository, 7=accepted payload.
            let component: Int
            switch relativePath {
            case "": component = 1
            case "worktree.tar": component = 2
            case "index.snapshot": component = 3
            case "branch.bundle": component = 4
            case ".restore-proof": component = 5
            case ".restore-proof/repository": component = 6
            default: component = entry == nil ? 0 : 7
            }
            let observation = "uid_match=\(before.st_uid == account.uid) device=\(observedDevice) kind=\(kindCode) links_safe=\(kind == S_IFDIR || before.st_nlink == 1) mode=\(UInt16(before.st_mode & 0o7777)) group_other_write_clear=\((before.st_mode & 0o022) == 0) special_mode_clear=\((before.st_mode & 0o7000) == 0) accepted_payload=\(acceptedPayloadMode) entry_present=\(entry != nil) entry_kind_match=\(entryKindMatches) entry_mode=\(entry.map { Int($0.mode) } ?? -1) flags=\(before.st_flags) flags_safe=\(Self.cleanupFlagsAllowed(before.st_flags)) component=\(component)"
            Self.mixedCleanupObservation.record(observation)
            throw error
        }
        #else
        guard before.st_uid == account.uid, UInt64(before.st_dev) == (try cleanupIdentity(parent)).device,
              kind == S_IFDIR || kind == S_IFREG || kind == S_IFLNK,
              kind == S_IFDIR || before.st_nlink == 1,
              acceptedPayloadMode || ((kind == S_IFLNK || (before.st_mode & 0o022) == 0) && (before.st_mode & 0o7000) == 0),
              Self.cleanupFlagsAllowed(before.st_flags) else {
            throw GitSafetyError.unsafeRepository("retention cleanup type, links, flags or mode is unsafe")
        }
        #endif
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(103)
        #endif
        let fd = try held.map { try RetentionArchiveCommandAuthority.copy($0) }
            ?? openat(parent, node.name, O_RDONLY | O_CLOEXEC | O_NONBLOCK
                | (kind == S_IFLNK ? O_SYMLINK : O_NOFOLLOW) | (kind == S_IFDIR ? O_DIRECTORY : 0))
        guard fd >= 0 else { throw SecureStateError.systemCall("open retention cleanup node", errno) }
        let descriptor = OwnedFileDescriptor(fd)
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(104)
        #endif
        try validateCleanupNode(node, descriptor: descriptor.value, parent: parent)
        if kind == S_IFDIR {
            #if SHADOW_SYNC_TESTING
            owner.recordCleanupStage(105)
            #endif
            let range = try cleanupChildRoster(node, index: index, descriptor: fd, plan: plan, deadline: deadline)
            for child in range {
                let name = try readCleanupNode(child, plan: plan, deadline: deadline).name
                try preflightCleanup(child, parent: fd, relativePath: relativePath.isEmpty ? name : relativePath + "/" + name,
                    plan: plan, owner: owner, deadline: deadline)
            }
            #if SHADOW_SYNC_TESTING
            owner.recordCleanupStage(106)
            #endif
            try validateCleanupRoster(range, descriptor: fd, plan: plan, deadline: deadline)
            #if SHADOW_SYNC_TESTING
            owner.recordCleanupStage(107)
            #endif
            try validateCleanupNode(node, descriptor: fd, parent: parent)
        }
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(108)
        #endif
        try appendCleanupOrder(index, plan: plan, deadline: deadline)
    }
    private func retireSlot(_ owner: Attempt) throws {
        guard !owner.creationUnresolved, !owner.published, !owner.commandUnresolved,
              !owner.cleanupUnresolved, let parent = owner.parent, let slot = owner.slot,
              let identity = owner.slotIdentity, let flags = owner.slotFlags else { throw SelectedRepositoryScopeError.cleanupPending }
        try retireTree(named: owner.name, parent: parent.value, descriptor: slot.value, identity: identity, flags: flags, owner: owner)
    }
    private func retireTree(named name: String, parent: Int32, descriptor: Int32,
                            identity: FileIdentity, flags: UInt32, owner: Attempt) throws {
        #if SHADOW_SYNC_TESTING
        let diagnosticStarted = DispatchTime.now().uptimeNanoseconds
        var diagnosticCompleted = false
        var diagnosticDeadline: MonotonicDeadline?
        owner.beginCleanupCostObservation()
        defer {
            owner.finishCleanupCostObservation()
            if !diagnosticCompleted { emitCleanupDiagnostic(owner, deadline: diagnosticDeadline, started: diagnosticStarted) }
        }
        #endif
        guard !owner.commandUnresolved, !owner.published, owner.plan == nil else { throw SelectedRepositoryScopeError.cleanupPending }
        let deadline = MonotonicDeadline(seconds: 5)
        #if SHADOW_SYNC_TESTING
        diagnosticDeadline = deadline
        owner.beginCleanupLocationObservation()
        owner.recordCleanupStage(1)
        #endif
        try validateAttempt(owner)
        let before = try cleanupSnapshot(descriptor)
        guard identity.matchesStableNode(FileIdentity(before)), before.st_flags == flags else { throw SelectedRepositoryScopeError.cleanupPending }
        let plan = CleanupPlan(name: name, root: OwnedFileDescriptor(try RetentionArchiveCommandAuthority.copy(descriptor)))
        owner.plan = plan
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(10)
        #endif
        try createCleanupSpill(plan.nodes, owner: owner)
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(20)
        #endif
        try createCleanupSpill(plan.order, owner: owner)
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(30)
        #endif
        _ = try appendCleanupNode(CleanupNode(name: name, before: before, parentIndex: -1, depth: 0), plan: plan, deadline: deadline)
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(40)
        #endif
        try preflightCleanup(0, parent: parent, held: descriptor, relativePath: name == owner.name ? "" : name,
            plan: plan, owner: owner, deadline: deadline)
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(50)
        #endif
        guard plan.nodeCount == plan.orderCount else { throw SelectedRepositoryScopeError.cleanupPending }
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(60)
        #endif
        try sealCleanupSpill(plan.nodes, deadline: deadline)
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(70)
        #endif
        try sealCleanupSpill(plan.order, deadline: deadline)
        plan.preflightComplete = true
        #if SHADOW_SYNC_TESTING
        try testingCleanupHooks?.afterPreflight?(parent, descriptor, name)
        #endif
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(80)
        #endif
        try deleteCleanup(plan, owner: owner, deadline: deadline)
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(90)
        #endif
        guard !deadline.hasExpired else { throw SelectedRepositoryScopeError.cleanupPending }
        try closeCleanupPlan(plan, deadline: deadline)
        #if SHADOW_SYNC_TESTING
        try testingCleanupHooks?.afterPlanClose?(deadline)
        #endif
        guard !deadline.hasExpired else { throw SelectedRepositoryScopeError.cleanupPending }
        owner.plan = nil
        #if SHADOW_SYNC_TESTING
        diagnosticCompleted = true
        #endif
    }
    private func cleanupLocation(_ index: Int64, plan: CleanupPlan, owner: Attempt, includeNode: Bool,
                                 deadline: MonotonicDeadline) throws -> (CleanupNode, Int32, OwnedFileDescriptor?, [CleanupAncestor]) {
        var records: [CleanupNode] = [], cursor = index
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupLocationStage(1)
        #endif
        while cursor >= 0 {
            guard records.count < Self.maximumCleanupDepth else { throw SelectedRepositoryScopeError.cleanupPending }
            let node = try readCleanupNode(cursor, plan: plan, deadline: deadline)
            records.append(node); cursor = node.parentIndex
        }
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupLocationStage(0)
        #endif
        records.reverse()
        guard let node = records.last, records.first?.name == plan.name,
              records.count == node.depth + 1, let slot = owner.slot, let retention = owner.parent else {
            throw SelectedRepositoryScopeError.cleanupPending
        }
        var parent = plan.name == owner.name ? retention.value : slot.value
        var ancestors: [CleanupAncestor] = []
        for (depth, current) in records.enumerated() {
            guard current.depth == depth else { throw SelectedRepositoryScopeError.cleanupPending }
            if depth == records.count - 1 && !includeNode { break }
            let kind = current.before.st_mode & S_IFMT
            #if SHADOW_SYNC_TESTING
            owner.recordCleanupLocationStage(2)
            #endif
            let fd = depth == 0 ? try plan.root.duplicate()
                : openat(parent, current.name, O_RDONLY | O_CLOEXEC | O_NONBLOCK
                    | (kind == S_IFLNK ? O_SYMLINK : O_NOFOLLOW) | (kind == S_IFDIR ? O_DIRECTORY : 0))
            guard fd >= 0 else { throw SelectedRepositoryScopeError.cleanupPending }
            let held = OwnedFileDescriptor(fd)
            #if SHADOW_SYNC_TESTING
            owner.recordCleanupLocationStage(3)
            #endif
            try validateCleanupNode(current, descriptor: fd, parent: parent)
            #if SHADOW_SYNC_TESTING
            owner.recordCleanupLocationStage(0)
            #endif
            if depth == records.count - 1 { return (node, parent, held, ancestors) }
            guard kind == S_IFDIR else { throw SelectedRepositoryScopeError.cleanupPending }
            ancestors.append(CleanupAncestor(node: current, descriptor: held, parent: parent)); parent = fd
        }
        return (node, parent, nil, ancestors)
    }
    private func retainedCleanupLocation(_ index: Int64, plan: CleanupPlan, owner: Attempt,
        reuse: inout [CleanupRetainedAncestor], deadline: MonotonicDeadline)
        throws -> (CleanupNode, Int32, OwnedFileDescriptor, [CleanupAncestor]) {
        // Node values were decoded from this private plan after its sole writer
        // was checked closed. Reuse does not replace either fresh spill identity
        // observation or any live tree check. No kernel immutability is claimed.
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupLocationStage(1)
        #endif
        // The current postorder leaf always comes from a fresh sealed read,
        // including a directory that was retained as the preceding ancestor.
        let leaf = try readCleanupNode(index, plan: plan, deadline: deadline)
        var reverse: [(Int64, CleanupNode)] = [(index, leaf)], cursor = leaf.parentIndex
        while cursor >= 0 {
            guard !deadline.hasExpired, reverse.count < Self.maximumCleanupDepth else {
                throw SelectedRepositoryScopeError.cleanupPending
            }
            if let position = reuse.firstIndex(where: { $0.index == cursor }) {
                guard reverse.count + position + 1 <= Self.maximumCleanupDepth else {
                    throw SelectedRepositoryScopeError.cleanupPending
                }
                try validateCleanupSpill(plan.nodes, requireSealed: true)
                for entry in reuse[...position].reversed() {
                    guard !deadline.hasExpired else { throw SelectedRepositoryScopeError.cleanupPending }
                    reverse.append((entry.index, entry.ancestor.node))
                }
                try validateCleanupSpill(plan.nodes, requireSealed: true)
                guard !deadline.hasExpired else { throw SelectedRepositoryScopeError.cleanupPending }
                cursor = -1
            } else {
                let node = try readCleanupNode(cursor, plan: plan, deadline: deadline)
                reverse.append((cursor, node)); cursor = node.parentIndex
            }
        }
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupLocationStage(0)
        #endif
        let records = reverse.reversed()
        guard let last = reverse.first, reverse.last?.0 == 0,
              reverse.last?.1.name == plan.name, reverse.count == last.1.depth + 1,
              let slot = owner.slot, let retention = owner.parent else {
            throw SelectedRepositoryScopeError.cleanupPending
        }
        var parent = plan.name == owner.name ? retention.value : slot.value
        var ancestors: [CleanupAncestor] = []
        var expectedParent: Int64 = -1
        for (depth, entry) in records.enumerated() {
            let (nodeIndex, current) = entry
            guard !deadline.hasExpired, current.depth == depth,
                  current.parentIndex == expectedParent else { throw SelectedRepositoryScopeError.cleanupPending }
            let kind = current.before.st_mode & S_IFMT
            #if SHADOW_SYNC_TESTING
            owner.recordCleanupLocationStage(2)
            #endif
            let held: OwnedFileDescriptor
            if depth < reuse.count, reuse[depth].index == nodeIndex {
                guard reuse[depth].ancestor.parent == parent else { throw SelectedRepositoryScopeError.cleanupPending }
                held = reuse[depth].ancestor.descriptor
            } else {
                // Drop a departed sibling suffix before opening the new one.
                // Prior iteration owners already survived its full postflight.
                if depth < reuse.count { reuse.removeSubrange(depth...) }
                if depth == 0 { held = plan.root }
                else {
                    let fd = openat(parent, current.name, O_RDONLY | O_CLOEXEC | O_NONBLOCK
                        | (kind == S_IFLNK ? O_SYMLINK : O_NOFOLLOW) | (kind == S_IFDIR ? O_DIRECTORY : 0))
                    guard fd >= 0 else { throw SelectedRepositoryScopeError.cleanupPending }
                    held = OwnedFileDescriptor(fd)
                }
            }
            #if SHADOW_SYNC_TESTING
            owner.recordCleanupLocationStage(3)
            #endif
            try validateCleanupNode(current, descriptor: held.value, parent: parent)
            #if SHADOW_SYNC_TESTING
            owner.recordCleanupLocationStage(0)
            #endif
            if depth == reverse.count - 1 {
                // A formerly retained directory may now be the postorder leaf.
                // Its returned owner stays alive through unlink and postflight.
                if depth < reuse.count { reuse.removeSubrange(depth...) }
                return (current, parent, held, ancestors)
            }
            guard kind == S_IFDIR else { throw SelectedRepositoryScopeError.cleanupPending }
            let ancestor = CleanupAncestor(node: current, descriptor: held, parent: parent)
            if depth == reuse.count { reuse.append(CleanupRetainedAncestor(index: nodeIndex, ancestor: ancestor)) }
            guard reuse.count < Self.maximumCleanupDepth else { throw SelectedRepositoryScopeError.cleanupPending }
            ancestors.append(ancestor); parent = held.value; expectedParent = nodeIndex
        }
        throw SelectedRepositoryScopeError.cleanupPending
    }
    private func validateCleanupAncestors(_ ancestors: [CleanupAncestor], plan: CleanupPlan, owner: Attempt) throws {
        try validateAttempt(owner, requireSlot: !(plan.name == owner.name && plan.rootRemoved))
        for ancestor in ancestors {
            try validateCleanupNode(ancestor.node, descriptor: ancestor.descriptor.value, parent: ancestor.parent)
        }
    }
    private func finishCleanupPostflight(_ plan: CleanupPlan, owner: Attempt, deadline: MonotonicDeadline) throws {
        guard let index = plan.pendingPostflight else { return }
        let (node, parent, _, ancestors) = try cleanupLocation(index, plan: plan, owner: owner, includeNode: false, deadline: deadline)
        try completeCleanupPostflight(plan, owner: owner, deadline: deadline,
            index: index, node: node, parent: parent, ancestors: ancestors)
    }
    private func completeCleanupPostflight(_ plan: CleanupPlan, owner: Attempt, deadline: MonotonicDeadline,
                                           index: Int64, node: CleanupNode, parent: Int32,
                                           ancestors: [CleanupAncestor]) throws {
        // The immediate path borrows the actual owners retained for this unlink.
        // A resumed pending postflight still reconstructs them above. Neither
        // path substitutes a prior validation for these live checks.
        defer { withExtendedLifetime(ancestors) {} }
        guard plan.pendingPostflight == index, !deadline.hasExpired else {
            throw SelectedRepositoryScopeError.cleanupPending
        }
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(209)
        #endif
        try validateCleanupAncestors(ancestors, plan: plan, owner: owner)
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(210)
        #endif
        var absent = stat()
        guard !deadline.hasExpired,
              fstatat(parent, node.name, &absent, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
              fsync(parent) == 0 else { throw SelectedRepositoryScopeError.cleanupPending }
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(211)
        try testingCleanupHooks?.afterPostflightDurability?(deadline)
        #endif
        guard !deadline.hasExpired else { throw SelectedRepositoryScopeError.cleanupPending }
        try validateCleanupAncestors(ancestors, plan: plan, owner: owner)
        guard !deadline.hasExpired else { throw SelectedRepositoryScopeError.cleanupPending }
        plan.pendingPostflight = nil
    }
    private func deleteCleanup(_ plan: CleanupPlan, owner: Attempt, deadline: MonotonicDeadline) throws {
        guard plan.preflightComplete, plan.nodes.writer?.closed == true, plan.order.writer?.closed == true,
              !owner.commandUnresolved, !owner.published else { throw SelectedRepositoryScopeError.cleanupPending }
        #if SHADOW_SYNC_TESTING
        owner.recordCleanupStage(201)
        #endif
        try finishCleanupPostflight(plan, owner: owner, deadline: deadline)
        // On any throw these read-only observation owners retire lexically.
        // Attempt retains the original plan/root/spills/leases/pending fence;
        // a resumed call reconstructs pending postflight and starts empty.
        var reusedAncestors: [CleanupRetainedAncestor] = []
        while plan.nextOrder < plan.orderCount {
            guard !deadline.hasExpired else { throw SelectedRepositoryScopeError.cleanupPending }
            let offset = plan.nextOrder.multipliedReportingOverflow(by: 8)
            guard !offset.overflow else { throw SelectedRepositoryScopeError.cleanupPending }
            #if SHADOW_SYNC_TESTING
            owner.recordCleanupStage(202)
            #endif
            let bytes = try readCleanupBytes(plan.order, offset: offset.partialValue, count: 8, deadline: deadline, sealed: true)
            var index: Int64 = 0
            withUnsafeMutableBytes(of: &index) { $0.copyBytes(from: bytes) }
            #if SHADOW_SYNC_TESTING
            owner.recordCleanupStage(203)
            #endif
            let (node, parent, held, ancestors) = try retainedCleanupLocation(index, plan: plan, owner: owner,
                reuse: &reusedAncestors, deadline: deadline)
            // The raw parent descriptor is borrowed from ancestors. Keep those
            // actual owners and the leaf alive through unlink and postflight,
            // including every throwing exit from this iteration.
            defer { withExtendedLifetime((held, ancestors)) {} }
            #if SHADOW_SYNC_TESTING
            guard let deleted = Int(exactly: plan.nextOrder) else { throw SelectedRepositoryScopeError.cleanupPending }
            try testingCleanupHooks?.beforeDelete?(parent, node.name, deleted)
            #endif
            #if SHADOW_SYNC_TESTING
            owner.recordCleanupStage(204)
            #endif
            try validateCleanupAncestors(ancestors, plan: plan, owner: owner)
            #if SHADOW_SYNC_TESTING
            owner.recordCleanupStage(205)
            #endif
            try validateCleanupNode(node, descriptor: held.value, parent: parent)
            let isDirectory = (node.before.st_mode & S_IFMT) == S_IFDIR
            #if SHADOW_SYNC_TESTING
            owner.recordCleanupStage(206)
            #endif
            if isDirectory, !(try directoryNames(held.value, deadline: deadline)).isEmpty {
                throw GitSafetyError.unsafeRepository("retention cleanup directory gained entries")
            }
            #if SHADOW_SYNC_TESTING
            owner.recordCleanupStage(207)
            #endif
            guard !deadline.hasExpired, unlinkat(parent, node.name, isDirectory ? AT_REMOVEDIR : 0) == 0 else {
                throw SelectedRepositoryScopeError.cleanupPending
            }
            // This is an actual original unlink receipt, never inferred absence.
            plan.pendingPostflight = index
            plan.nextOrder += 1
            if index == 0 { plan.rootRemoved = true }
            #if SHADOW_SYNC_TESTING
            owner.recordCleanupStage(208)
            #endif
            try completeCleanupPostflight(plan, owner: owner, deadline: deadline,
                index: index, node: node, parent: parent, ancestors: ancestors)
        }
        guard !deadline.hasExpired, plan.rootRemoved, plan.pendingPostflight == nil else {
            throw SelectedRepositoryScopeError.cleanupPending
        }
    }

    private func removeAnyOwnedDirectory(
        named name: String,
        parent: Int32
    ) throws {
        let directory = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else {
            throw SecureStateError.systemCall(
                "open owned scratch directory",
                errno
            )
        }
        for child in try directoryNames(directory) {
            var info = stat()
            guard fstatat(
                directory,
                child,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            info.st_uid == account.uid else {
                Darwin.close(directory)
                throw SecureStateError.unsafePath(child)
            }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                try removeAnyOwnedDirectory(
                    named: child,
                    parent: directory
                )
            } else {
                guard unlinkat(directory, child, 0) == 0 else {
                    Darwin.close(directory)
                    throw SecureStateError.systemCall(
                        "remove owned scratch entry",
                        errno
                    )
                }
            }
        }
        Darwin.close(directory)
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
            throw SecureStateError.systemCall(
                "remove owned scratch directory",
                errno
            )
        }
    }

    private func clearRestoreWorktree(_ root: Int32) throws {
        for name in try directoryNames(root) where name != ".git" {
            var info = stat()
            guard fstatat(
                root,
                name,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw SecureStateError.systemCall(
                    "inspect restore worktree",
                    errno
                )
            }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                try removeAnyOwnedDirectory(
                    named: name,
                    parent: root
                )
            } else {
                guard unlinkat(root, name, 0) == 0 else {
                    throw SecureStateError.systemCall(
                        "clear restore worktree",
                        errno
                    )
                }
            }
        }
    }

    private func extractTar(
        sourceName: String,
        sourceParent: Int32,
        destination: Int32
    ) throws {
        let data = try readFile(
            sourceName,
            parent: sourceParent,
            maximumBytes: Int(Self.maximumBytes),
            requireProtectedArtifact: true
        )
        for record in try TarReader.read(data) {
            try createParents(
                for: record.entry.path,
                root: destination
            )
            let parts = record.entry.path.split(
                separator: "/"
            ).map(String.init)
            let parent = try openRelativeDirectory(
                Array(parts.dropLast()),
                root: destination
            )
            let name = parts.last!
            do {
                switch record.entry.kind {
                case .directory:
                    if mkdirat(
                        parent,
                        name,
                        mode_t(record.entry.mode)
                    ) != 0, errno != EEXIST {
                        throw SecureStateError.systemCall(
                            "restore retained directory",
                            errno
                        )
                    }
                    let restoredDirectory = openat(
                        parent,
                        name,
                        O_RDONLY | O_DIRECTORY
                            | O_NOFOLLOW | O_CLOEXEC
                    )
                    guard restoredDirectory >= 0 else {
                        throw SecureStateError.systemCall(
                            "open restored directory",
                            errno
                        )
                    }
                    guard fchmod(
                        restoredDirectory,
                        mode_t(record.entry.mode)
                    ) == 0 else {
                        let code = errno
                        Darwin.close(restoredDirectory)
                        throw SecureStateError.systemCall(
                            "restore retained directory mode",
                            code
                        )
                    }
                    Darwin.close(restoredDirectory)
                case .regular:
                    let file = openat(
                        parent,
                        name,
                        O_WRONLY | O_CREAT | O_EXCL
                            | O_NOFOLLOW | O_CLOEXEC,
                        mode_t(record.entry.mode)
                    )
                    guard file >= 0 else {
                        throw SecureStateError.systemCall(
                            "restore retained file",
                            errno
                        )
                    }
                    do {
                        try writeAll(record.data, to: file)
                        guard fchmod(
                            file,
                            mode_t(record.entry.mode)
                        ) == 0 else {
                            throw SecureStateError.systemCall(
                                "restore retained mode",
                                errno
                            )
                        }
                        Darwin.close(file)
                    } catch {
                        Darwin.close(file)
                        throw error
                    }
                case .symbolicLink:
                    guard let target =
                            record.entry.symlinkTarget,
                          symlinkat(
                            target,
                            parent,
                            name
                          ) == 0 else {
                        throw SecureStateError.systemCall(
                            "restore retained symlink",
                            errno
                        )
                    }
                }
            } catch {
                Darwin.close(parent)
                throw error
            }
            Darwin.close(parent)
        }
    }

    private func createParents(
        for path: String,
        root: Int32
    ) throws {
        let components = path.split(separator: "/")
            .dropLast().map(String.init)
        var current = dup(root)
        guard current >= 0 else {
            throw SecureStateError.systemCall(
                "retain restore root",
                errno
            )
        }
        defer { Darwin.close(current) }
        for component in components {
            if mkdirat(current, component, 0o700) != 0,
               errno != EEXIST {
                throw SecureStateError.systemCall(
                    "create restore parent",
                    errno
                )
            }
            let next = openat(
                current,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard next >= 0 else {
                throw SecureStateError.systemCall(
                    "open restore parent",
                    errno
                )
            }
            Darwin.close(current)
            current = next
        }
    }

    private func openRelativeDirectory(
        _ components: [String],
        root: Int32
    ) throws -> Int32 {
        var current = dup(root)
        guard current >= 0 else {
            throw SecureStateError.systemCall(
                "retain relative root",
                errno
            )
        }
        for component in components {
            let next = openat(
                current,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard next >= 0 else {
                Darwin.close(current)
                throw SecureStateError.systemCall(
                    "open relative directory",
                    errno
                )
            }
            Darwin.close(current)
            current = next
        }
        return current
    }

    private func restoreIndex(
        _ snapshot: IndexSnapshot,
        sourceParent: Int32,
        restoreRoot: Int32
    ) throws {
        let source = try openPrivateDirectory(
            "index.snapshot",
            parent: sourceParent
        )
        defer { Darwin.close(source) }
        let git = try openPrivateDirectory(
            ".git",
            parent: restoreRoot,
            requireExactMode: false
        )
        defer { Darwin.close(git) }
        let names = ["index"]
            + snapshot.sharedFiles.keys.sorted()
        for name in names {
            let data = try readFile(
                name,
                parent: source,
                maximumBytes: 67_108_864,
                requireProtectedArtifact: true
            )
            _ = unlinkat(git, name, 0)
            let output = openat(
                git,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
            guard output >= 0 else {
                throw SecureStateError.systemCall(
                    "restore index snapshot",
                    errno
                )
            }
            do {
                try writeAll(data, to: output)
                Darwin.close(output)
            } catch {
                Darwin.close(output)
                throw error
            }
        }
    }

    private func manifestEntries(
        descriptor: Int32,
        relativeParent: String,
        cancellation: CancellationToken
    ) throws -> [RetentionEntry] {
        var entries: [RetentionEntry] = []
        for name in try directoryNames(descriptor) {
            try checkCancellation(cancellation)
            if relativeParent.isEmpty && name == ".git" {
                continue
            }
            let relative = relativeParent.isEmpty
                ? name : relativeParent + "/" + name
            var info = stat()
            guard fstatat(
                descriptor,
                name,
                &info,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw SecureStateError.systemCall(
                    "inspect restored entry",
                    errno
                )
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                let child = openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard child >= 0 else {
                    throw SecureStateError.systemCall(
                        "open restored directory",
                        errno
                    )
                }
                entries.append(try RetentionEntry(
                    path: relative,
                    kind: .directory,
                    mode: UInt16(info.st_mode & 0o7777),
                    size: 0,
                    symlinkTarget: nil,
                    contentSHA256: nil
                ))
                entries.append(
                    contentsOf: try manifestEntries(
                        descriptor: child,
                        relativeParent: relative,
                        cancellation: cancellation
                    )
                )
                Darwin.close(child)
            case S_IFREG:
                let data = try readFile(
                    name,
                    parent: descriptor,
                    maximumBytes: Int(Self.maximumBytes)
                )
                entries.append(try RetentionEntry(
                    path: relative,
                    kind: .regular,
                    mode: UInt16(info.st_mode & 0o7777),
                    size: UInt64(data.count),
                    symlinkTarget: nil,
                    contentSHA256: Self.sha256(data)
                ))
            case S_IFLNK:
                entries.append(try RetentionEntry(
                    path: relative,
                    kind: .symbolicLink,
                    mode: UInt16(info.st_mode & 0o7777),
                    size: 0,
                    symlinkTarget: try readLink(
                        name,
                        parent: descriptor
                    ),
                    contentSHA256: nil
                ))
            default:
                throw GitSafetyError.unsafeRepository(
                    "restored special file is invalid"
                )
            }
        }
        return entries.sorted { $0.path < $1.path }
    }

    private func checkCancellation(
        _ cancellation: CancellationToken
    ) throws {
        if cancellation.isCancelled {
            throw GitSafetyError.cancelled
        }
    }

    private static func sameSnapshot(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec
                == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec
                == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec
                == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec
                == rhs.st_ctimespec.tv_nsec
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

enum RetentionPath {
    static func isComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\0")
    }

    static func isSafeRelative(_ value: String) -> Bool {
        !value.isEmpty
            && !value.hasPrefix("/")
            && !value.contains("\0")
            && value.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    static func isOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy {
                $0.isNumber
                    || ("a"..."f").contains($0.lowercased())
            }
    }

    static func isArtifactID(_ value: String) -> Bool {
        value.hasPrefix("ret-")
            && value.count <= 80
            && value.allSatisfy {
                $0.isLowercase || $0.isNumber || $0 == "-"
            }
    }

    static func isSecretShaped(_ path: String) -> Bool {
        let value = path.lowercased()
        let leaf = value.split(separator: "/").last.map(String.init)
            ?? value
        return leaf == ".env"
            || leaf.hasPrefix(".env.")
            || value.contains("credential")
            || value.contains("secret")
            || value.contains("token")
            || value.contains("private-key")
            || value.contains("id_rsa")
            || value.contains("id_ed25519")
            || [".pem", ".p12", ".pfx", ".key"].contains {
                leaf.hasSuffix($0)
            }
    }

    static func symlinkIsContained(
        path: String,
        target: String
    ) -> Bool {
        guard !target.hasPrefix("/"),
              !target.contains("\0") else {
            return false
        }
        var components = path.split(separator: "/")
            .dropLast().map(String.init)
        for component in target.split(
            separator: "/",
            omittingEmptySubsequences: false
        ) {
            if component.isEmpty || component == "." {
                continue
            }
            if component == ".." {
                guard !components.isEmpty else { return false }
                components.removeLast()
            } else {
                components.append(String(component))
            }
        }
        return true
    }
}

enum RetentionGitCommandPolicy {
    static func validate(_ arguments: [String]) throws {
        guard !arguments.isEmpty,
              !arguments.contains(where: {
                  $0.contains("\0")
                    || $0.contains("\n")
                    || $0.contains("\r")
              }) else {
            throw GitSafetyError.unsafeRepository(
                "retention Git arguments are invalid"
            )
        }
        let valid =
            (
                arguments.count == 6
                    && arguments[0] == "--git-dir"
                    && isAbsolutePath(arguments[1])
                    && arguments[2] == "bundle"
                    && arguments[3] == "create"
                    && isBundlePath(arguments[4])
                    && (
                        GitReferenceSyntax
                            .isValidLocalBranchRef(
                                arguments[5]
                            )
                            || RetentionPath.isOID(
                                arguments[5]
                            )
                    )
            )
            || (
                arguments.count == 5
                    && arguments[0] == "--git-dir"
                    && isAbsolutePath(arguments[1])
                    && arguments[2] == "bundle"
                    && arguments[3] == "verify"
                    && isBundlePath(arguments[4])
            )
            || (
                arguments.count == 4
                    && arguments[0] == "clone"
                    && arguments[1] == "--no-hardlinks"
                    && isBundlePath(arguments[2])
                    && isAbsolutePath(arguments[3])
                    && arguments[3].hasSuffix(
                        "/.restore-proof/repository"
                    )
            )
            || (
                arguments.count == 5
                    && arguments[0] == "-C"
                    && isAbsolutePath(arguments[1])
                    && arguments[2] == "rev-parse"
                    && arguments[3] == "--verify"
                    && arguments[4].hasSuffix(
                        "^{commit}"
                    )
                    && RetentionPath.isOID(
                        String(
                            arguments[4].dropLast(
                                "^{commit}".count
                            )
                        )
                    )
            )
            || (
                arguments.count == 5
                    && arguments[0] == "-C"
                    && isAbsolutePath(arguments[1])
                    && arguments[2] == "checkout"
                    && arguments[3] == "--detach"
                    && RetentionPath.isOID(arguments[4])
            )
            || (
                arguments.count == 5
                    && arguments[0] == "-C"
                    && isAbsolutePath(arguments[1])
                    && arguments[2] == "fsck"
                    && arguments[3] == "--connectivity-only"
                    && arguments[4] == "--no-dangling"
            )
            || (
                arguments.count == 7
                    && arguments[0] == "-C"
                    && isAbsolutePath(arguments[1])
                    && arguments[2] == "status"
                    && arguments[3] == "--porcelain=v2"
                    && arguments[4] == "-z"
                    && arguments[5] == "--untracked-files=all"
                    && arguments[6] == "--ignored=matching"
            )
        guard valid,
              !arguments.contains("--force"),
              !arguments.contains("-D"),
              !arguments.contains("push") else {
            throw GitSafetyError.unsafeRepository(
                "retention Git command is outside the closed grammar"
            )
        }
    }

    private static func isBundlePath(
        _ value: String
    ) -> Bool {
        isAbsolutePath(value)
            && value.hasSuffix("/branch.bundle")
            && value.contains(
                "/retention/.incomplete-ret-"
            )
    }

    private static func isAbsolutePath(
        _ value: String
    ) -> Bool {
        value.hasPrefix("/")
            && !value.contains("/../")
            && !value.hasSuffix("/..")
            && !value.contains("/./")
            && !value.hasSuffix("/.")
    }
}

enum GitIndexValidator {
    private struct Inspection {
        let shared: [String]
        let hasHiddenEntries: Bool
    }

    static func validate(
        _ data: Data,
        objectIDBytes: Int
    ) throws -> [String] {
        try inspect(
            data,
            objectIDBytes: objectIDBytes
        ).shared
    }

    static func hiddenEntryState(
        _ data: Data,
        objectIDBytes: Int
    ) throws -> Bool? {
        let inspection = try inspect(
            data,
            objectIDBytes: objectIDBytes
        )
        guard inspection.shared.isEmpty else {
            return nil
        }
        return inspection.hasHiddenEntries
    }

    private static func inspect(
        _ data: Data,
        objectIDBytes: Int
    ) throws -> Inspection {
        guard [20, 32].contains(objectIDBytes),
              data.count >= 12 + objectIDBytes,
              String(data: data.prefix(4), encoding: .ascii)
                == "DIRC" else {
            throw GitSafetyError.unsafeRepository(
                "index snapshot header is invalid"
            )
        }
        let version = integer(data, offset: 4)
        guard version == 2 || version == 3 else {
            throw GitSafetyError.unsafeRepository(
                "unknown index format is unsupported"
            )
        }
        let count = Int(integer(data, offset: 8))
        guard count <= 1_000_000 else {
            throw GitSafetyError.unsafeRepository(
                "index entry bound exceeded"
            )
        }
        var offset = 12
        var hasHiddenEntries = false
        let checksumStart = data.count - objectIDBytes
        let payload = data.prefix(checksumStart)
        let expectedChecksum = data.suffix(objectIDBytes)
        let observedChecksum: Data
        if objectIDBytes == 20 {
            observedChecksum = Data(
                Insecure.SHA1.hash(data: payload)
            )
        } else {
            observedChecksum = Data(
                SHA256.hash(data: payload)
            )
        }
        guard observedChecksum == expectedChecksum else {
            throw GitSafetyError.unsafeRepository(
                "index checksum is invalid"
            )
        }
        for _ in 0..<count {
            let start = offset
            let fixed = 40 + objectIDBytes + 2
            guard offset + fixed <= checksumStart else {
                throw GitSafetyError.unsafeRepository(
                    "index entry is truncated"
                )
            }
            let flags = UInt16(data[offset + fixed - 2]) << 8
                | UInt16(data[offset + fixed - 1])
            if (flags & 0x8000) != 0 {
                hasHiddenEntries = true
            }
            offset += fixed
            if (flags & 0x4000) != 0 {
                guard version >= 3,
                      offset + 2 <= checksumStart else {
                    throw GitSafetyError.unsafeRepository(
                        "extended index entry is truncated"
                    )
                }
                let extendedFlags =
                    UInt16(data[offset]) << 8
                    | UInt16(data[offset + 1])
                if (extendedFlags & 0x4000) != 0 {
                    hasHiddenEntries = true
                }
                offset += 2
            }
            guard let terminator = data[
                offset..<checksumStart
            ].firstIndex(of: 0) else {
                throw GitSafetyError.unsafeRepository(
                    "index pathname is unterminated"
                )
            }
            offset = terminator + 1
            let length = offset - start
            offset += (8 - (length % 8)) % 8
            guard offset <= checksumStart else {
                throw GitSafetyError.unsafeRepository(
                    "index entry padding is invalid"
                )
            }
        }
        let known = Set([
            "TREE", "REUC", "UNTR", "FSMN",
            "EOIE", "IEOT", "link", "sdir",
        ])
        var shared: [String] = []
        while offset < checksumStart {
            guard offset + 8 <= checksumStart,
                  let signature = String(
                    data: data[offset..<(offset + 4)],
                    encoding: .ascii
                  ) else {
                throw GitSafetyError.unsafeRepository(
                    "index extension is malformed"
                )
            }
            let size = Int(integer(data, offset: offset + 4))
            offset += 8
            guard known.contains(signature),
                  size >= 0,
                  offset + size <= checksumStart else {
                throw GitSafetyError.unsafeRepository(
                    "unknown index extension is unsupported"
                )
            }
            if signature == "link" {
                guard size >= objectIDBytes else {
                    throw GitSafetyError.unsafeRepository(
                        "shared index extension is truncated"
                    )
                }
                shared.append(
                    data[offset..<(offset + objectIDBytes)]
                        .map { String(format: "%02x", $0) }
                        .joined()
                )
            }
            offset += size
        }
        guard offset == checksumStart else {
            throw GitSafetyError.unsafeRepository(
                "index extension boundary is invalid"
            )
        }
        return Inspection(
            shared: shared,
            hasHiddenEntries: hasHiddenEntries
        )
    }

    private static func integer(
        _ data: Data,
        offset: Int
    ) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }
}

#if SHADOW_SYNC_TESTING
public enum RetentionArtifactTesting {
    public static func validateIndex(
        _ data: Data,
        objectIDBytes: Int
    ) throws -> [String] {
        try GitIndexValidator.validate(
            data,
            objectIDBytes: objectIDBytes
        )
    }
}
#endif

private struct TarWriter {
    let descriptor: Int32

    mutating func appendDirectory(
        _ entry: RetentionEntry
    ) throws {
        try appendHeader(entry, type: UInt8(ascii: "5"), size: 0)
    }

    mutating func appendSymlink(
        _ entry: RetentionEntry
    ) throws {
        try appendHeader(entry, type: UInt8(ascii: "2"), size: 0)
    }

    mutating func appendFile(
        _ entry: RetentionEntry,
        data: Data
    ) throws {
        try appendHeader(
            entry,
            type: UInt8(ascii: "0"),
            size: data.count
        )
        try write(data)
        let padding = (512 - (data.count % 512)) % 512
        if padding > 0 {
            try write(Data(repeating: 0, count: padding))
        }
    }

    mutating func finish() throws {
        try write(Data(repeating: 0, count: 1_024))
    }

    private mutating func appendHeader(
        _ entry: RetentionEntry,
        type: UInt8,
        size: Int
    ) throws {
        let split = try TarPath.split(entry.path)
        var header = Data(repeating: 0, count: 512)
        put(split.name, into: &header, offset: 0, length: 100)
        putOctal(
            UInt64(entry.mode),
            into: &header,
            offset: 100,
            length: 8
        )
        putOctal(0, into: &header, offset: 108, length: 8)
        putOctal(0, into: &header, offset: 116, length: 8)
        putOctal(
            UInt64(size),
            into: &header,
            offset: 124,
            length: 12
        )
        putOctal(0, into: &header, offset: 136, length: 12)
        for index in 148..<156 { header[index] = 0x20 }
        header[156] = type
        if let target = entry.symlinkTarget {
            put(target, into: &header, offset: 157, length: 100)
        }
        put("ustar\u{0}", into: &header, offset: 257, length: 6)
        put("00", into: &header, offset: 263, length: 2)
        if let prefix = split.prefix {
            put(prefix, into: &header, offset: 345, length: 155)
        }
        let checksum = header.reduce(UInt64(0)) {
            $0 + UInt64($1)
        }
        putOctal(
            checksum,
            into: &header,
            offset: 148,
            length: 8,
            terminator: 0x20
        )
        try write(header)
    }

    private func put(
        _ value: String,
        into data: inout Data,
        offset: Int,
        length: Int
    ) {
        let bytes = Array(value.utf8.prefix(length))
        data.replaceSubrange(
            offset..<(offset + bytes.count),
            with: bytes
        )
    }

    private func putOctal(
        _ value: UInt64,
        into data: inout Data,
        offset: Int,
        length: Int,
        terminator: UInt8 = 0
    ) {
        let text = String(value, radix: 8)
        let padded = String(
            repeating: "0",
            count: max(0, length - text.count - 1)
        ) + text
        put(
            padded,
            into: &data,
            offset: offset,
            length: length - 1
        )
        data[offset + length - 1] = terminator
    }

    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    raw.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw SecureStateError.systemCall(
                        "write worktree tar",
                        errno
                    )
                }
            }
        }
    }
}

private enum TarPath {
    static func split(
        _ path: String
    ) throws -> (name: String, prefix: String?) {
        guard path.utf8.count <= 255 else {
            throw GitSafetyError.unsafeRepository(
                "retained path exceeds ustar bounds"
            )
        }
        if path.utf8.count <= 100 {
            return (path, nil)
        }
        let components = path.split(separator: "/")
        for split in stride(
            from: components.count - 1,
            through: 1,
            by: -1
        ) {
            let prefix = components[..<split]
                .joined(separator: "/")
            let name = components[split...]
                .joined(separator: "/")
            if prefix.utf8.count <= 155,
               name.utf8.count <= 100 {
                return (name, prefix)
            }
        }
        throw GitSafetyError.unsafeRepository(
            "retained path cannot be represented in ustar"
        )
    }
}

private struct TarRecord {
    let entry: RetentionEntry
    let data: Data
}

private enum TarReader {
    static func read(_ data: Data) throws -> [TarRecord] {
        var offset = 0
        var result: [TarRecord] = []
        while offset + 512 <= data.count {
            let header = data[offset..<(offset + 512)]
            if header.allSatisfy({ $0 == 0 }) {
                break
            }
            let expected = try octal(header, offset: 148, length: 8)
            var checksumHeader = Data(header)
            for index in 148..<156 { checksumHeader[index] = 0x20 }
            guard checksumHeader.reduce(UInt64(0), {
                $0 + UInt64($1)
            }) == expected else {
                throw GitSafetyError.unsafeRepository(
                    "worktree tar checksum is invalid"
                )
            }
            let name = text(header, offset: 0, length: 100)
            let prefix = text(header, offset: 345, length: 155)
            let path = prefix.isEmpty
                ? name : prefix + "/" + name
            let mode = try octal(header, offset: 100, length: 8)
            let size = Int(
                try octal(header, offset: 124, length: 12)
            )
            let target = text(header, offset: 157, length: 100)
            let type = header[header.startIndex + 156]
            offset += 512
            guard size >= 0, offset + size <= data.count else {
                throw GitSafetyError.unsafeRepository(
                    "worktree tar entry is truncated"
                )
            }
            let payload = Data(data[offset..<(offset + size)])
            offset += size
            offset += (512 - (size % 512)) % 512
            let kind: RetentionEntryKind
            switch type {
            case UInt8(ascii: "0"), 0: kind = .regular
            case UInt8(ascii: "5"): kind = .directory
            case UInt8(ascii: "2"): kind = .symbolicLink
            default:
                throw GitSafetyError.unsafeRepository(
                    "worktree tar entry type is unsupported"
                )
            }
            let entry = try RetentionEntry(
                path: path,
                kind: kind,
                mode: UInt16(mode),
                size: UInt64(size),
                symlinkTarget:
                    kind == .symbolicLink ? target : nil,
                contentSHA256:
                    kind == .regular
                        ? SHA256.hash(data: payload).map {
                            String(format: "%02x", $0)
                        }.joined()
                        : nil
            )
            result.append(TarRecord(entry: entry, data: payload))
        }
        return result
    }

    private static func text(
        _ data: Data.SubSequence,
        offset: Int,
        length: Int
    ) -> String {
        let start = data.startIndex + offset
        let bytes = data[start..<(start + length)]
            .prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func octal(
        _ data: Data.SubSequence,
        offset: Int,
        length: Int
    ) throws -> UInt64 {
        let value = text(data, offset: offset, length: length)
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .trimmingCharacters(in: CharacterSet(
                charactersIn: "\0"
            ))
        guard value.isEmpty
                || value.allSatisfy({ ("0"..."7").contains($0) }),
              let parsed = UInt64(value.isEmpty ? "0" : value, radix: 8)
        else {
            throw GitSafetyError.unsafeRepository(
                "worktree tar numeric field is invalid"
            )
        }
        return parsed
    }
}

private extension JSONEncoder {
    static var retention: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }
}
