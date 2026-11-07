import CryptoKit
import Foundation

// Observations only. Decoding, constructing or validating any value in this file
// grants no descriptor, process, installation, command or recovery authority.
// CustodyCatalogStore must separately validate its typed writer, live state and
// exact old bytes under catalog.lock, and publish/fsync receipt BEFORE control.
enum InstallationRecordError: Error { case invalidRecord, invalidTransition, limit }

enum InstallationPhase: String { case initial, active, committed, recovery }
enum InstallationTransactionIntent: String { case install, repair, migrate, remove }
enum InstallationStepStatus: String { case intent, complete }
enum InstallationRecoveryReason: String {
    case interrupted, persistence
    case commandPending = "command-pending", identityConflict = "identity-conflict"
    case readinessFailed = "readiness-failed", cleanupFailed = "cleanup-failed"
    case startupUncertain = "startup-uncertain", restoredStopped = "restored-stopped"
}
enum InstallationAction: String, CaseIterable {
    case reserve, finish
    case drainPrior = "drain-prior", stageApplication = "stage-application", stagePlist = "stage-plist"
    case retireApplication = "retire-application", retirePlist = "retire-plist"
    case retireCoordination = "retire-coordination", translateState = "translate-state"
    case moveStateForward = "move-state-forward", promoteApplication = "promote-application"
    case promotePlist = "promote-plist", openStagedAdmission = "open-staged-admission"
    case bootstrapCandidate = "bootstrap-candidate", kickstartCandidate = "kickstart-candidate"
    case candidateReady = "candidate-ready", readinessCommit = "readiness-commit"
    case cleanupCoordination = "cleanup-coordination", cleanupBackups = "cleanup-backups"
    case cleanupIncoming = "cleanup-incoming", candidateStop = "candidate-stop"
    case moveStateBack = "move-state-back", restoreApplication = "restore-application"
    case restorePlist = "restore-plist", restoreCoordination = "restore-coordination"
    case removeInstallation = "remove-installation"
}

// Logical names, never paths. Only the installer resolves these through its
// pinned InstallationPaths/layout; incomplete suffixes derive from transaction id.
enum InstallationSlot: String, CaseIterable {
    case application, predecessorApplication, applicationIncoming, applicationIncomplete
    case applicationPrevious, predecessorPrevious, launchPlist, plistIncoming, plistIncomplete, plistPrevious
    case stateSource, stateDestination, hostOwner, hostSocket, hostOwnerPrevious, hostSocketPrevious
    case installationSocket = "installation.sock"
    var isBundle: Bool {
        [.application, .predecessorApplication, .applicationIncoming, .applicationIncomplete,
         .applicationPrevious, .predecessorPrevious].contains(self)
    }
    var isNamespace: Bool { self == .stateSource || self == .stateDestination }
    var isSocket: Bool { [.hostSocket, .hostSocketPrevious, .installationSocket].contains(self) }
}
enum InstallationDocument: String, CaseIterable {
    case latestLog = "latest.log", authorities = "repository-authorities.json"
    case selection = "selection-preferences.json", selectionRecovery = "selection-preferences.recovery"
}
enum InstallationNodeType: String { case directory, regular, socket }

struct InstallationNodeIdentity: Equatable {
    let device: UInt64, inode: UInt64
    let type: InstallationNodeType
    let uid: UInt32, mode: UInt32
    let links: UInt64
    let aclDigest: String
    func validate() throws {
        let typeBits: UInt32 = type == .directory ? 0o040000 : type == .regular ? 0o100000 : 0o140000
        guard device > 0, inode > 0, mode & 0o170000 == typeBits,
              mode & ~UInt32(0o177777) == 0, mode & 0o7022 == 0,
              type == .directory ? links > 0 : links == 1,
              CustodyWire.hex(aclDigest, bytes: 32) else { throw InstallationRecordError.invalidRecord }
    }
    var wire: PolicyWireValue { .object([
        "device": .unsigned(device), "inode": .unsigned(inode), "type": .string(type.rawValue),
        "uid": .unsigned(UInt64(uid)), "mode": .unsigned(UInt64(mode)), "links": .unsigned(links),
        "aclDigest": .string(aclDigest),
    ]) }
}
extension InstallationNodeIdentity {
    init(wire: PolicyWireValue) throws {
        let v = try wire.object(keys: ["device", "inode", "type", "uid", "mode", "links", "aclDigest"])
        device = try CustodyWire.uint(v["device"]); inode = try CustodyWire.uint(v["inode"])
        type = try InstallationWire.enumeration(v["type"])
        uid = try InstallationWire.uint32(v["uid"]); mode = try InstallationWire.uint32(v["mode"])
        links = try CustodyWire.uint(v["links"]); aclDigest = try CustodyWire.text(v["aclDigest"])
        try validate()
    }
}

struct InstallationStateBinding: Equatable {
    let directory: InstallationNodeIdentity
    let namespace: InstallationNodeIdentity
    let lifecycle: InstallationNodeIdentity
    let operation: InstallationNodeIdentity
    let run: InstallationNodeIdentity
    let launcher: InstallationNodeIdentity
    let catalogGuard: InstallationNodeIdentity
    func validate() throws {
        try directory.validate()
        guard directory.type == .directory, directory.mode == 0o040700, directory.uid != 0 else {
            throw InstallationRecordError.invalidRecord
        }
        let locks = [namespace, lifecycle, operation, run, launcher, catalogGuard]
        var nodes = Set<String>()
        for node in [directory] + locks {
            try node.validate()
            guard node.uid == directory.uid,
                  nodes.insert("\(node.device):\(node.inode)").inserted else {
                throw InstallationRecordError.invalidRecord
            }
        }
        guard locks.allSatisfy({ $0.type == .regular && $0.mode == 0o100600 && $0.links == 1 }) else {
            throw InstallationRecordError.invalidRecord
        }
    }
    var wire: PolicyWireValue { .object([
        "directory": directory.wire, "namespace": namespace.wire, "lifecycle": lifecycle.wire,
        "operation": operation.wire, "run": run.wire, "launcher": launcher.wire, "catalogGuard": catalogGuard.wire,
    ]) }
    func digest() throws -> String { try InstallationWire.digest(wire) }
}
extension InstallationStateBinding {
    init(wire: PolicyWireValue) throws {
        let v = try wire.object(keys: ["directory", "namespace", "lifecycle", "operation", "run", "launcher", "catalogGuard"])
        directory = try InstallationNodeIdentity(wire: CustodyWire.required(v["directory"]))
        namespace = try InstallationNodeIdentity(wire: CustodyWire.required(v["namespace"]))
        lifecycle = try InstallationNodeIdentity(wire: CustodyWire.required(v["lifecycle"]))
        operation = try InstallationNodeIdentity(wire: CustodyWire.required(v["operation"]))
        run = try InstallationNodeIdentity(wire: CustodyWire.required(v["run"]))
        launcher = try InstallationNodeIdentity(wire: CustodyWire.required(v["launcher"]))
        catalogGuard = try InstallationNodeIdentity(wire: CustodyWire.required(v["catalogGuard"]))
        try validate()
    }
}

struct InstallationSlotImage: Equatable {
    // An absent slot still retains its pinned parent. Null is not a guessed
    // inode or an empty preimage. Live capture must prove the exact absence.
    let parentDevice: UInt64, parentInode: UInt64
    let node: InstallationNodeIdentity?
    let size: UInt64?
    let contentDigest: String?
    // Present namespaces carry EVERY fixed document key. A null value is an
    // evidenced absence; a digest references its separate durable preimage receipt.
    let documentReceipts: [InstallationDocument: String?]?
    func validate(slot: InstallationSlot, uid: UInt32) throws {
        guard parentDevice > 0, parentInode > 0 else { throw InstallationRecordError.invalidRecord }
        guard let node else {
            guard size == nil, contentDigest == nil, documentReceipts == nil else { throw InstallationRecordError.invalidRecord }
            return
        }
        try node.validate()
        guard node.uid == uid else { throw InstallationRecordError.invalidRecord }
        if slot.isSocket {
            guard node.type == .socket, node.mode == 0o140600, size == nil,
                  contentDigest == nil, documentReceipts == nil else { throw InstallationRecordError.invalidRecord }
        } else if slot.isNamespace {
            guard node.type == .directory, node.mode == 0o040700, size == nil, contentDigest == nil,
                  let documents = documentReceipts,
                  Set(documents.keys) == Set(InstallationDocument.allCases) else { throw InstallationRecordError.invalidRecord }
            for digest in documents.values { if let digest { try InstallationWire.requireDigest(digest) } }
        } else {
            guard node.type == (slot.isBundle ? .directory : .regular),
                  slot.isBundle ? size == nil : size != nil,
                  let contentDigest, documentReceipts == nil else { throw InstallationRecordError.invalidRecord }
            try InstallationWire.requireDigest(contentDigest)
        }
    }
    var wire: PolicyWireValue {
        var documents: PolicyWireValue = .null
        if let documentReceipts {
            documents = .object(Dictionary(uniqueKeysWithValues: InstallationDocument.allCases.map {
                ($0.rawValue, (documentReceipts[$0] ?? nil).map(PolicyWireValue.string) ?? .null)
            }))
        }
        return .object([
            "presence": .string(node == nil ? "absent" : "present"),
            "parentDevice": .unsigned(parentDevice), "parentInode": .unsigned(parentInode),
            "node": node?.wire ?? .null, "size": size.map(PolicyWireValue.unsigned) ?? .null,
            "contentDigest": contentDigest.map(PolicyWireValue.string) ?? .null, "documentReceipts": documents,
        ])
    }
}
extension InstallationSlotImage {
    init(wire: PolicyWireValue) throws {
        let v = try wire.object(keys: ["presence", "parentDevice", "parentInode", "node", "size", "contentDigest", "documentReceipts"])
        parentDevice = try CustodyWire.uint(v["parentDevice"]); parentInode = try CustodyWire.uint(v["parentInode"])
        node = try InstallationWire.optional(v["node"], InstallationNodeIdentity.init(wire:))
        size = try InstallationWire.optional(v["size"], { try CustodyWire.uint($0) })
        contentDigest = try CustodyWire.optionalText(v["contentDigest"])
        if v["documentReceipts"] == .null { documentReceipts = nil }
        else {
            let documents = try CustodyWire.required(v["documentReceipts"]).object(keys: Set(InstallationDocument.allCases.map(\.rawValue)))
            var result: [InstallationDocument: String?] = [:]
            for document in InstallationDocument.allCases {
                // updateValue preserves a key whose optional value is nil.
                result.updateValue(try CustodyWire.optionalText(documents[document.rawValue]), forKey: document)
            }
            documentReceipts = result
        }
        guard try CustodyWire.text(v["presence"]) == (node == nil ? "absent" : "present") else {
            throw InstallationRecordError.invalidRecord
        }
    }
}

struct InstallationSlotSnapshot: Equatable {
    let images: [InstallationSlot: InstallationSlotImage]
    func validate(uid: UInt32) throws {
        guard Set(images.keys) == Set(InstallationSlot.allCases) else { throw InstallationRecordError.invalidRecord }
        for slot in InstallationSlot.allCases { try images[slot]!.validate(slot: slot, uid: uid) }
    }
    var wire: PolicyWireValue { .object(Dictionary(uniqueKeysWithValues: images.map { ($0.key.rawValue, $0.value.wire) })) }
    func digest() throws -> String { try InstallationWire.digest(wire) }
}
extension InstallationSlotSnapshot {
    init(wire: PolicyWireValue) throws {
        let values = try wire.object(keys: Set(InstallationSlot.allCases.map(\.rawValue)))
        var result: [InstallationSlot: InstallationSlotImage] = [:]
        for slot in InstallationSlot.allCases { result[slot] = try InstallationSlotImage(wire: CustodyWire.required(values[slot.rawValue])) }
        images = result
    }
}

// Unlike CustodyProcessObservation this does not assume a process-group leader.
// The observation never authenticates a peer; authenticated construction belongs
// to the separate audit-token/lifetime capability, not to this wire model.
struct InstallationProcessObservation: Equatable {
    let pid: UInt32, uid: UInt32
    let startSeconds: UInt64, startMicroseconds: UInt64
    let generation: String
    func validate() throws {
        guard pid > 1, pid <= UInt32(Int32.max), startSeconds > 0, startMicroseconds < 1_000_000,
              RunIdentity.isValid(generation) else { throw InstallationRecordError.invalidRecord }
    }
    var wire: PolicyWireValue { .object([
        "pid": .unsigned(UInt64(pid)), "uid": .unsigned(UInt64(uid)), "startSeconds": .unsigned(startSeconds),
        "startMicroseconds": .unsigned(startMicroseconds), "generation": .string(generation),
    ]) }
}
extension InstallationProcessObservation {
    init(wire: PolicyWireValue) throws {
        let v = try wire.object(keys: ["pid", "uid", "startSeconds", "startMicroseconds", "generation"])
        pid = try InstallationWire.uint32(v["pid"]); uid = try InstallationWire.uint32(v["uid"])
        startSeconds = try CustodyWire.uint(v["startSeconds"]); startMicroseconds = try CustodyWire.uint(v["startMicroseconds"])
        generation = try CustodyWire.text(v["generation"]); try validate()
    }
}
struct InstallationCoordinatorObservation: Equatable {
    let process: InstallationProcessObservation
    let team: String, identifier: String, cdHash: String
    func validate(uid: UInt32) throws {
        try process.validate()
        guard process.uid == uid, team == ReleaseIdentity.publisherTeamIdentifier,
              identifier == LifecyclePublisher.identifier, CustodyWire.hex(cdHash, bytes: 20) else {
            throw InstallationRecordError.invalidRecord
        }
    }
    var wire: PolicyWireValue { .object([
        "process": process.wire, "team": .string(team), "identifier": .string(identifier), "cdHash": .string(cdHash),
    ]) }
}
extension InstallationCoordinatorObservation {
    init(wire: PolicyWireValue) throws {
        let v = try wire.object(keys: ["process", "team", "identifier", "cdHash"])
        process = try InstallationProcessObservation(wire: CustodyWire.required(v["process"]))
        team = try CustodyWire.text(v["team"]); identifier = try CustodyWire.text(v["identifier"]); cdHash = try CustodyWire.text(v["cdHash"])
    }
}
struct InstallationCandidate: Equatable {
    let release: ReleaseIdentity
    let bundleDigest: String, appCDHash: String, coordinatorCDHash: String
    func validate() throws {
        try release.validate(requireProduction: true)
        try InstallationWire.requireDigest(bundleDigest)
        guard CustodyWire.hex(appCDHash, bytes: 20), CustodyWire.hex(coordinatorCDHash, bytes: 20) else {
            throw InstallationRecordError.invalidRecord
        }
    }
    var wire: PolicyWireValue { .object([
        "release": InstallationWire.release(release), "bundleDigest": .string(bundleDigest),
        "appCDHash": .string(appCDHash), "coordinatorCDHash": .string(coordinatorCDHash),
    ]) }
}
extension InstallationCandidate {
    init(wire: PolicyWireValue) throws {
        let v = try wire.object(keys: ["release", "bundleDigest", "appCDHash", "coordinatorCDHash"])
        release = try ReleaseIdentity.decode(CustodyWire.encode(CustodyWire.required(v["release"]), maximum: 16_384))
        bundleDigest = try CustodyWire.text(v["bundleDigest"])
        appCDHash = try CustodyWire.text(v["appCDHash"]); coordinatorCDHash = try CustodyWire.text(v["coordinatorCDHash"])
        try validate()
    }
}

struct InstallationTransaction: Equatable {
    let id: String, boot: String
    let intent: InstallationTransactionIntent
    let coordinator: InstallationCoordinatorObservation
    let sourceReleaseDigest: String
    let candidate: InstallationCandidate?
    let priorCommitDigest: String?
    let slots: InstallationSlotSnapshot
    func validate(state: InstallationStateBinding) throws {
        guard RunIdentity.isValid(id), RunIdentity.isValid(boot), (intent == .remove) == (candidate == nil) else {
            throw InstallationRecordError.invalidRecord
        }
        try coordinator.validate(uid: state.directory.uid)
        try InstallationWire.requireDigest(sourceReleaseDigest)
        if let priorCommitDigest { try InstallationWire.requireDigest(priorCommitDigest) }
        try candidate?.validate(); try slots.validate(uid: state.directory.uid)
    }
    var bindingWire: [String: PolicyWireValue] { [
        "id": .string(id), "boot": .string(boot), "intent": .string(intent.rawValue), "coordinator": coordinator.wire,
        "sourceReleaseDigest": .string(sourceReleaseDigest), "candidate": candidate?.wire ?? .null,
        "priorCommitDigest": priorCommitDigest.map(PolicyWireValue.string) ?? .null,
    ] }
    var wire: PolicyWireValue { var v = bindingWire; v["slots"] = slots.wire; return .object(v) }
    func sameBinding(as other: Self) -> Bool { PolicyWireValue.object(bindingWire) == PolicyWireValue.object(other.bindingWire) }
}
extension InstallationTransaction {
    init(wire: PolicyWireValue) throws {
        let v = try wire.object(keys: ["id", "boot", "intent", "coordinator", "sourceReleaseDigest", "candidate", "priorCommitDigest", "slots"])
        id = try CustodyWire.text(v["id"]); boot = try CustodyWire.text(v["boot"]); intent = try InstallationWire.enumeration(v["intent"])
        coordinator = try InstallationCoordinatorObservation(wire: CustodyWire.required(v["coordinator"]))
        sourceReleaseDigest = try CustodyWire.text(v["sourceReleaseDigest"])
        candidate = try InstallationWire.optional(v["candidate"], InstallationCandidate.init(wire:))
        priorCommitDigest = try CustodyWire.optionalText(v["priorCommitDigest"])
        slots = try InstallationSlotSnapshot(wire: CustodyWire.required(v["slots"]))
    }
}

struct InstallationStep: Equatable {
    let ordinal: UInt64
    let action: InstallationAction
    let status: InstallationStepStatus
    let preimageDigest: String
    let postimageDigest: String?
    func validate() throws {
        guard (1...128).contains(ordinal), (status == .intent) == (postimageDigest == nil) else {
            throw InstallationRecordError.invalidRecord
        }
        try InstallationWire.requireDigest(preimageDigest)
        if let postimageDigest { try InstallationWire.requireDigest(postimageDigest) }
    }
    var wire: PolicyWireValue { .object([
        "ordinal": .unsigned(ordinal), "action": .string(action.rawValue), "status": .string(status.rawValue),
        "preimageDigest": .string(preimageDigest), "postimageDigest": postimageDigest.map(PolicyWireValue.string) ?? .null,
    ]) }
}
extension InstallationStep {
    init(wire: PolicyWireValue) throws {
        let v = try wire.object(keys: ["ordinal", "action", "status", "preimageDigest", "postimageDigest"])
        ordinal = try CustodyWire.uint(v["ordinal"]); action = try InstallationWire.enumeration(v["action"])
        status = try InstallationWire.enumeration(v["status"]); preimageDigest = try CustodyWire.text(v["preimageDigest"])
        postimageDigest = try CustodyWire.optionalText(v["postimageDigest"]); try validate()
    }
}

struct InstallationReadinessCommit: Equatable {
    let transactionID: String
    let commitRevision: UInt64
    let candidateReleaseDigest: String, candidateBundleDigest: String
    let candidateAppCDHash: String, candidateCoordinatorCDHash: String
    let stateBindingDigest: String, completedStepReceiptDigest: String
    let host: InstallationProcessObservation
    // Only hello/challenge/ready. No commit digest is part of this transcript,
    // and the referenced candidate-ready receipt contains no hash of this commit.
    let precommitTranscriptDigest: String
    func validate(transaction: InstallationTransaction, state: InstallationStateBinding, revision: UInt64) throws {
        guard transactionID == transaction.id, commitRevision > 1, commitRevision <= revision,
              let candidate = transaction.candidate,
              candidateReleaseDigest == candidate.release.releaseContractSHA256,
              candidateBundleDigest == candidate.bundleDigest, candidateAppCDHash == candidate.appCDHash,
              candidateCoordinatorCDHash == candidate.coordinatorCDHash,
              stateBindingDigest == (try state.digest()), host.uid == state.directory.uid,
              host.pid != transaction.coordinator.process.pid else { throw InstallationRecordError.invalidRecord }
        try host.validate(); try InstallationWire.requireDigest(completedStepReceiptDigest)
        try InstallationWire.requireDigest(precommitTranscriptDigest)
    }
    var wire: PolicyWireValue { .object([
        "transactionID": .string(transactionID), "commitRevision": .unsigned(commitRevision),
        "candidateReleaseDigest": .string(candidateReleaseDigest), "candidateBundleDigest": .string(candidateBundleDigest),
        "candidateAppCDHash": .string(candidateAppCDHash), "candidateCoordinatorCDHash": .string(candidateCoordinatorCDHash),
        "stateBindingDigest": .string(stateBindingDigest), "completedStepReceiptDigest": .string(completedStepReceiptDigest),
        "host": host.wire, "precommitTranscriptDigest": .string(precommitTranscriptDigest),
    ]) }
    func digest() throws -> String { try InstallationWire.digest(wire) }
}
extension InstallationReadinessCommit {
    init(wire: PolicyWireValue) throws {
        let v = try wire.object(keys: ["transactionID", "commitRevision", "candidateReleaseDigest", "candidateBundleDigest",
            "candidateAppCDHash", "candidateCoordinatorCDHash", "stateBindingDigest", "completedStepReceiptDigest", "host", "precommitTranscriptDigest"])
        transactionID = try CustodyWire.text(v["transactionID"]); commitRevision = try CustodyWire.uint(v["commitRevision"])
        candidateReleaseDigest = try CustodyWire.text(v["candidateReleaseDigest"]); candidateBundleDigest = try CustodyWire.text(v["candidateBundleDigest"])
        candidateAppCDHash = try CustodyWire.text(v["candidateAppCDHash"]); candidateCoordinatorCDHash = try CustodyWire.text(v["candidateCoordinatorCDHash"])
        stateBindingDigest = try CustodyWire.text(v["stateBindingDigest"]); completedStepReceiptDigest = try CustodyWire.text(v["completedStepReceiptDigest"])
        host = try InstallationProcessObservation(wire: CustodyWire.required(v["host"]))
        precommitTranscriptDigest = try CustodyWire.text(v["precommitTranscriptDigest"])
    }
}

struct InstallationStepReceipt: Equatable {
    static let schema = "shadow-sync-installation-step/v1"
    static let prefix = "installation-step-"
    static let maximumBytes = 32_768
    let transactionID: String
    let ordinal: UInt64
    let previousReceiptDigest: String?
    let action: InstallationAction
    let status: InstallationStepStatus
    let preimage: InstallationSlotSnapshot
    let postimage: InstallationSlotSnapshot?
    // Hash of the exact canonical {state, transaction-without-slots} binding.
    // No paths, output, document bytes or reusable authority are serialized.
    let bindingDigest: String
    var wire: PolicyWireValue { .object([
        "schema": .string(Self.schema), "transactionID": .string(transactionID), "ordinal": .unsigned(ordinal),
        "previousReceiptDigest": previousReceiptDigest.map(PolicyWireValue.string) ?? .null,
        "action": .string(action.rawValue), "status": .string(status.rawValue), "preimage": preimage.wire,
        "postimage": postimage?.wire ?? .null, "bindingDigest": .string(bindingDigest),
    ]) }
    func validate(uid: UInt32) throws {
        guard RunIdentity.isValid(transactionID), (1...128).contains(ordinal),
              (status == .intent) == (postimage == nil),
              (previousReceiptDigest == nil) == (ordinal == 1 && status == .intent && action == .reserve) else {
            throw InstallationRecordError.invalidRecord
        }
        if let previousReceiptDigest { try InstallationWire.requireDigest(previousReceiptDigest) }
        try InstallationWire.requireDigest(bindingDigest); try preimage.validate(uid: uid); try postimage?.validate(uid: uid)
    }
    func step() throws -> InstallationStep {
        InstallationStep(ordinal: ordinal, action: action, status: status,
            preimageDigest: try preimage.digest(), postimageDigest: try postimage?.digest())
    }
    func encode(uid: UInt32) throws -> Data { try validate(uid: uid); return try CustodyWire.encode(wire, maximum: Self.maximumBytes) }
    func digest(uid: UInt32) throws -> String { InstallationWire.hash(try encode(uid: uid)) }
    static func decode(_ data: Data, uid: UInt32) throws -> Self {
        try CanonicalObservation(decoding: data, uid: uid).receipt
    }
    // Exact recognized names only: no caller-selected receipt destination.
    func filename(uid: UInt32) throws -> String { Self.prefix + transactionID + "-" + String(ordinal) + "-" + status.rawValue + "-" + (try digest(uid: uid)) + ".json" }

    // One immutable, snapshot-local observation of validated canonical bytes.
    // Both constructors validate the receipt for the recorded UID; no caller can
    // supply a digest. This is neither live storage proof nor reusable authority.
    struct CanonicalObservation {
        let receipt: InstallationStepReceipt
        let uid: UInt32
        let digest: String
        init(validating receipt: InstallationStepReceipt, uid: UInt32) throws {
            let data = try receipt.encode(uid: uid)
            self.receipt = receipt; self.uid = uid; digest = InstallationWire.hash(data)
        }
        init(decoding data: Data, uid: UInt32) throws {
            do {
                let receipt = try InstallationStepReceipt(wire: InstallationWire.parse(data))
                // Compare the typed serialization, not just the parsed wire:
                // schema conversion must preserve every canonical byte too.
                guard try receipt.encode(uid: uid) == data else { throw InstallationRecordError.invalidRecord }
                self.receipt = receipt; self.uid = uid; digest = InstallationWire.hash(data)
            } catch { throw InstallationRecordError.invalidRecord }
        }
        var filename: String {
            InstallationStepReceipt.prefix + receipt.transactionID + "-" + String(receipt.ordinal)
                + "-" + receipt.status.rawValue + "-" + digest + ".json"
        }
    }
}
extension InstallationStepReceipt {
    init(wire: PolicyWireValue) throws {
        let v = try wire.object(keys: ["schema", "transactionID", "ordinal", "previousReceiptDigest", "action", "status", "preimage", "postimage", "bindingDigest"])
        guard try CustodyWire.text(v["schema"]) == Self.schema else { throw InstallationRecordError.invalidRecord }
        transactionID = try CustodyWire.text(v["transactionID"]); ordinal = try CustodyWire.uint(v["ordinal"])
        previousReceiptDigest = try CustodyWire.optionalText(v["previousReceiptDigest"])
        action = try InstallationWire.enumeration(v["action"]); status = try InstallationWire.enumeration(v["status"])
        preimage = try InstallationSlotSnapshot(wire: CustodyWire.required(v["preimage"]))
        postimage = try InstallationWire.optional(v["postimage"], InstallationSlotSnapshot.init(wire:))
        bindingDigest = try CustodyWire.text(v["bindingDigest"])
    }
}

struct InstallationControlRecord: Equatable {
    static let schema = "shadow-sync-installation-control/v1"
    static let filename = "installation.json"
    static let maximumBytes = 32_768
    static let maximumSteps: UInt64 = 128
    let revision: UInt64
    let phase: InstallationPhase
    let state: InstallationStateBinding
    let transaction: InstallationTransaction?
    let step: InstallationStep?
    // 'Complete durable receipt' means the entire durable record, not necessarily
    // status=complete. The very first reserve INTENT must be referenced here.
    let latestReceiptDigest: String?
    let readinessCommit: InstallationReadinessCommit?
    let recoveryReason: InstallationRecoveryReason?
    static func initial(state: InstallationStateBinding) throws -> Self {
        let value = Self(revision: 1, phase: .initial, state: state, transaction: nil, step: nil,
            latestReceiptDigest: nil, readinessCommit: nil, recoveryReason: nil)
        try value.validate(); return value
    }
    func validate() throws {
        try state.validate()
        guard revision > 0 else { throw InstallationRecordError.invalidRecord }
        if phase == .initial {
            guard revision == 1, transaction == nil, step == nil, latestReceiptDigest == nil,
                  readinessCommit == nil, recoveryReason == nil else { throw InstallationRecordError.invalidRecord }
            return // fenced; this is never idle/admissible ordinary state.
        }
        guard revision > 1, let transaction, let step, let latestReceiptDigest,
              (phase == .recovery) == (recoveryReason != nil),
              phase != .active || readinessCommit == nil,
              phase != .committed || readinessCommit != nil,
              transaction.intent != .remove || (phase != .committed && readinessCommit == nil) else {
            throw InstallationRecordError.invalidRecord
        }
        try transaction.validate(state: state); try step.validate(); try InstallationWire.requireDigest(latestReceiptDigest)
        guard InstallationActionTable.isKnown(step.action, intent: transaction.intent) else { throw InstallationRecordError.invalidRecord }
        if let readinessCommit {
            try readinessCommit.validate(transaction: transaction, state: state, revision: revision)
            guard InstallationActionTable.isForwardAfterCommit(step.action),
                  step.action != .readinessCommit || step.status == .complete else { throw InstallationRecordError.invalidRecord }
        } else {
            guard step.action != .readinessCommit || step.status == .intent,
                  phase == .recovery || !InstallationActionTable.isRollback(step.action),
                  phase == .recovery || step.action != .finish else { throw InstallationRecordError.invalidRecord }
        }
        if recoveryReason == .restoredStopped {
            guard readinessCommit == nil, step.action == .finish, step.status == .complete else { throw InstallationRecordError.invalidRecord }
        }
    }
    var wire: PolicyWireValue { .object([
        "schema": .string(Self.schema), "revision": .unsigned(revision), "phase": .string(phase.rawValue), "state": state.wire,
        "transaction": transaction?.wire ?? .null, "step": step?.wire ?? .null,
        "latestReceiptDigest": latestReceiptDigest.map(PolicyWireValue.string) ?? .null,
        "readinessCommit": readinessCommit?.wire ?? .null,
        "recoveryReason": recoveryReason.map { .string($0.rawValue) } ?? .null,
    ]) }
    func encode() throws -> Data { try validate(); return try CustodyWire.encode(wire, maximum: Self.maximumBytes) }
    static func decode(_ data: Data) throws -> Self {
        do { let value = try Self(wire: InstallationWire.decode(data)); try value.validate(); return value }
        catch { throw InstallationRecordError.invalidRecord }
    }
    func bindingDigest() throws -> String {
        guard let transaction else { throw InstallationRecordError.invalidRecord }
        return try InstallationWire.digest(.object(["state": state.wire, "transaction": .object(transaction.bindingWire)]))
    }

    // Requires the COMPLETE current-transaction chain (<=256 records), already
    // read by the store's exact fixed receipt-family recognizer. This binds wire
    // observations only. Storage metadata, extras, current boot/process, live
    // peers, retired commands and allowed residual layout remain caller gates.
    func validateReceiptChain(_ receipts: [InstallationStepReceipt]) throws {
        guard receipts.count <= 256 else { throw InstallationRecordError.invalidRecord }
        try validateReceiptChain(observations: receipts.map {
            try InstallationStepReceipt.CanonicalObservation(validating: $0, uid: state.directory.uid)
        })
    }
    func validateReceiptChain(observations: [InstallationStepReceipt.CanonicalObservation]) throws {
        try validate()
        if phase == .initial { guard observations.isEmpty else { throw InstallationRecordError.invalidRecord }; return }
        guard let transaction, let step, !observations.isEmpty, observations.count <= 256 else { throw InstallationRecordError.invalidRecord }
        // Every receipt publication consumes at least one control revision after
        // the initial control. Recovery-only replacements and earlier completed
        // transactions may make revision larger, but never smaller.
        guard revision > UInt64(observations.count) else { throw InstallationRecordError.invalidRecord }
        let uid = state.directory.uid, binding = try bindingDigest()
        var prior: InstallationStepReceipt.CanonicalObservation?
        var rollback = false, committed = false
        var candidateReadyDigest: String?
        for (index, observation) in observations.enumerated() {
            guard observation.uid == uid else { throw InstallationRecordError.invalidRecord }
            let receipt = observation.receipt
            guard receipt.transactionID == transaction.id, receipt.bindingDigest == binding else { throw InstallationRecordError.invalidRecord }
            if let priorObservation = prior {
                let prior = priorObservation.receipt
                guard receipt.previousReceiptDigest == priorObservation.digest else { throw InstallationRecordError.invalidRecord }
                if prior.status == .intent {
                    guard receipt.status == .complete, receipt.ordinal == prior.ordinal, receipt.action == prior.action,
                          receipt.preimage == prior.preimage else { throw InstallationRecordError.invalidRecord }
                } else {
                    guard receipt.status == .intent, prior.ordinal < Self.maximumSteps,
                          receipt.ordinal == prior.ordinal + 1, receipt.preimage == prior.postimage,
                          InstallationActionTable.allows(prior.action, receipt.action, intent: transaction.intent,
                              rollback: rollback, committed: committed, recovery: phase == .recovery) else {
                        throw InstallationRecordError.invalidRecord
                    }
                }
            } else {
                guard receipt.ordinal == 1, receipt.action == .reserve, receipt.status == .intent,
                      receipt.previousReceiptDigest == nil else { throw InstallationRecordError.invalidRecord }
            }
            if receipt.action == .candidateStop || (transaction.intent == .remove && receipt.action == .restoreApplication) { rollback = true }
            if receipt.action == .candidateReady && receipt.status == .complete { candidateReadyDigest = observation.digest }
            if receipt.action == .readinessCommit && receipt.status == .complete {
                guard let readinessCommit, readinessCommit.completedStepReceiptDigest == candidateReadyDigest,
                      readinessCommit.commitRevision >= UInt64(index) + 2,
                      revision - readinessCommit.commitRevision >= UInt64(observations.count - index - 1) else {
                    throw InstallationRecordError.invalidRecord
                }
                committed = true
            }
            prior = observation
        }
        guard let latestObservation = prior else { throw InstallationRecordError.invalidRecord }
        let latest = latestObservation.receipt
        guard try latest.step() == step,
              latestObservation.digest == latestReceiptDigest,
              transaction.slots == (latest.postimage ?? latest.preimage),
              committed == (readinessCommit != nil),
              !rollback || phase == .recovery else { throw InstallationRecordError.invalidRecord }
        if let readinessCommit {
            guard readinessCommit.completedStepReceiptDigest == candidateReadyDigest else { throw InstallationRecordError.invalidRecord }
        }
    }

    // Pure proposal validation. The typed store must perform this against LIVE
    // old control and a fully validated chain while retaining its original guard.
    // No public API accepts an arbitrary executable transition/action list.
    func validateReplacement(_ next: Self, receipts: [InstallationStepReceipt]) throws {
        try validate(); try next.validateReceiptChain(receipts)
        guard revision < UInt64.max, next.revision == revision + 1, state == next.state else { throw InstallationRecordError.invalidTransition }
        if phase == .initial || (phase == .committed && step?.action == .finish && step?.status == .complete) {
            guard next.phase == .active, let transaction = next.transaction,
                  transaction.id != self.transaction?.id, next.step?.action == .reserve,
                  next.step?.status == .intent, next.step?.ordinal == 1, receipts.count == 1,
                  transaction.priorCommitDigest == (try readinessCommit?.digest()) else { throw InstallationRecordError.invalidTransition }
            return // caller must separately authenticate coordinator/current boot.
        }
        guard let oldTransaction = transaction, let newTransaction = next.transaction,
              oldTransaction.sameBinding(as: newTransaction), let oldStep = step, let newStep = next.step else {
            throw InstallationRecordError.invalidTransition
        }
        if let readinessCommit { guard next.readinessCommit == readinessCommit else { throw InstallationRecordError.invalidTransition } }
        if oldStep == newStep {
            if phase == .recovery && next.phase == .committed {
                // A typed recovery owner must separately prove every command is
                // retired and the exact final residual layout is admissible.
                // This only validates the evidence-preserving metadata edge;
                // it never admits a host or clears an uncertain filesystem cut.
                guard oldStep.action == .finish, oldStep.status == .complete,
                      readinessCommit != nil, next.readinessCommit == readinessCommit,
                      next.latestReceiptDigest == latestReceiptDigest,
                      newTransaction.slots == oldTransaction.slots,
                      next.recoveryReason == nil else { throw InstallationRecordError.invalidTransition }
                return
            }
            // Record a failure without inventing action success or clearing it.
            guard next.phase == .recovery, next.latestReceiptDigest == latestReceiptDigest,
                  newTransaction.slots == oldTransaction.slots, next.readinessCommit == readinessCommit else {
                throw InstallationRecordError.invalidTransition
            }
            return
        }
        // The supplied chain must append exactly ONE durable receipt to the
        // old referenced receipt; an arbitrary already-advanced chain is refused.
        guard receipts.count >= 2,
              try receipts[receipts.count - 2].digest(uid: state.directory.uid) == latestReceiptDigest else {
            throw InstallationRecordError.invalidTransition
        }
        if oldStep.status == .intent {
            guard newStep.status == .complete, newStep.ordinal == oldStep.ordinal, newStep.action == oldStep.action,
                  newStep.preimageDigest == oldStep.preimageDigest else { throw InstallationRecordError.invalidTransition }
            // Incomplete start commands are reconciled, never replayed. This
            // method proposes only evidence; a completion still needs live proof.
            if oldStep.action == .readinessCommit {
                guard phase == .active, next.phase == .committed,
                      next.readinessCommit?.commitRevision == next.revision else { throw InstallationRecordError.invalidTransition }
            } else {
                guard next.readinessCommit == readinessCommit, next.phase == phase || next.phase == .recovery else {
                    throw InstallationRecordError.invalidTransition
                }
            }
        } else {
            guard newStep.status == .intent, oldStep.ordinal < Self.maximumSteps,
                  newStep.ordinal == oldStep.ordinal + 1,
                  newStep.preimageDigest == oldStep.postimageDigest,
                  InstallationActionTable.allows(oldStep.action, newStep.action, intent: oldTransaction.intent,
                      rollback: receipts.dropLast().contains(where: {
                          $0.action == .candidateStop || (oldTransaction.intent == .remove && $0.action == .restoreApplication)
                      }), committed: readinessCommit != nil,
                      recovery: phase == .recovery),
                  next.readinessCommit == readinessCommit,
                  next.phase == phase || next.phase == .recovery else { throw InstallationRecordError.invalidTransition }
        }
    }
}
extension InstallationControlRecord {
    init(wire: PolicyWireValue) throws {
        let v = try wire.object(keys: ["schema", "revision", "phase", "state", "transaction", "step", "latestReceiptDigest", "readinessCommit", "recoveryReason"])
        guard try CustodyWire.text(v["schema"]) == Self.schema else { throw InstallationRecordError.invalidRecord }
        revision = try CustodyWire.uint(v["revision"]); phase = try InstallationWire.enumeration(v["phase"])
        state = try InstallationStateBinding(wire: CustodyWire.required(v["state"]))
        transaction = try InstallationWire.optional(v["transaction"], InstallationTransaction.init(wire:))
        step = try InstallationWire.optional(v["step"], InstallationStep.init(wire:))
        latestReceiptDigest = try CustodyWire.optionalText(v["latestReceiptDigest"])
        readinessCommit = try InstallationWire.optional(v["readinessCommit"], InstallationReadinessCommit.init(wire:))
        recoveryReason = try InstallationWire.optional(v["recoveryReason"], { try InstallationWire.enumeration($0) })
    }
}

// This finite table describes legal metadata progress, not filesystem execution.
// All install/repair non-applicable stages complete as proven no-ops. Migration
// uses those same fixed slots but supplies real state translation/move receipts.
// Rollback after any incomplete action requires FIRST reconciling that action's
// exact before/after images to a complete receipt under recovery authority.
private enum InstallationActionTable {
    static func forward(_ intent: InstallationTransactionIntent) -> [InstallationAction] {
        switch intent {
        case .install, .repair, .migrate:
            return [.reserve, .drainPrior, .stageApplication, .stagePlist, .retireApplication, .retirePlist,
                .retireCoordination, .translateState, .moveStateForward, .promoteApplication, .promotePlist,
                .openStagedAdmission, .bootstrapCandidate, .kickstartCandidate, .candidateReady, .readinessCommit,
                .cleanupCoordination, .cleanupBackups, .cleanupIncoming, .finish]
        case .remove:
            return [.reserve, .drainPrior, .retireApplication, .retirePlist, .retireCoordination,
                .removeInstallation, .cleanupCoordination, .cleanupBackups, .cleanupIncoming, .finish]
        }
    }
    static let rollback: [InstallationAction] = [.candidateStop, .cleanupCoordination, .moveStateBack,
        .restoreApplication, .restorePlist, .restoreCoordination, .cleanupIncoming, .finish]
    static let removalRollback: [InstallationAction] = [.restoreApplication, .restorePlist, .restoreCoordination, .cleanupIncoming, .finish]
    static func isKnown(_ action: InstallationAction, intent: InstallationTransactionIntent) -> Bool {
        forward(intent).contains(action) || (intent == .remove ? removalRollback : rollback).contains(action)
    }
    static func isRollback(_ action: InstallationAction) -> Bool {
        [.candidateStop, .moveStateBack, .restoreApplication, .restorePlist, .restoreCoordination].contains(action)
    }
    static func isForwardAfterCommit(_ action: InstallationAction) -> Bool {
        [.readinessCommit, .cleanupCoordination, .cleanupBackups, .cleanupIncoming, .finish].contains(action)
    }
    static func follows(_ a: InstallationAction, _ b: InstallationAction, in sequence: [InstallationAction]) -> Bool {
        guard let index = sequence.firstIndex(of: a), index + 1 < sequence.count else { return false }
        return sequence[index + 1] == b
    }
    static func allows(_ a: InstallationAction, _ b: InstallationAction, intent: InstallationTransactionIntent,
                       rollback: Bool, committed: Bool, recovery: Bool) -> Bool {
        if committed {
            return !rollback && follows(a, b, in: [.readinessCommit, .cleanupCoordination, .cleanupBackups, .cleanupIncoming, .finish])
        }
        if rollback {
            return recovery && follows(a, b, in: intent == .remove ? removalRollback : Self.rollback)
        }
        if follows(a, b, in: forward(intent)) {
            // Successful removal is a fenced recovery/tombstone, never committed.
            return intent != .remove || b != .finish || recovery
        }
        guard recovery, a != .finish, a != .readinessCommit, !isForwardAfterCommit(a) else { return false }
        return b == (intent == .remove ? .restoreApplication : .candidateStop)
    }
}

private enum InstallationWire {
    static func parse(_ data: Data) throws -> PolicyWireValue {
        guard !data.isEmpty, data.count <= InstallationControlRecord.maximumBytes else { throw InstallationRecordError.limit }
        // Seventeen fixed slot keys exceed configuration's 16-object-key cap.
        // Reuse the existing larger-object profile, then enforce exact schema,
        // small byte cap and canonical byte equality. No grammar broadening.
        var parser = try PolicyWireParser(data, profile: .bundleLayout)
        return try parser.parse()
    }
    static func decode(_ data: Data) throws -> PolicyWireValue {
        let value = try parse(data)
        guard try CustodyWire.encode(value, maximum: InstallationControlRecord.maximumBytes) == data else {
            throw InstallationRecordError.invalidRecord
        }
        return value
    }
    static func enumeration<T: RawRepresentable>(_ value: PolicyWireValue?) throws -> T where T.RawValue == String {
        guard let result = T(rawValue: try CustodyWire.text(value)) else { throw InstallationRecordError.invalidRecord }; return result
    }
    static func uint32(_ value: PolicyWireValue?) throws -> UInt32 {
        guard let result = UInt32(exactly: try CustodyWire.uint(value)) else { throw InstallationRecordError.invalidRecord }; return result
    }
    static func optional<T>(_ value: PolicyWireValue?, _ decode: (PolicyWireValue) throws -> T) throws -> T? {
        value == .null ? nil : try decode(CustodyWire.required(value))
    }
    static func requireDigest(_ digest: String) throws {
        guard CustodyWire.hex(digest, bytes: 32) else { throw InstallationRecordError.invalidRecord }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func digest(_ value: PolicyWireValue) throws -> String {
        hash(try CustodyWire.encode(value, maximum: InstallationControlRecord.maximumBytes))
    }
    static func release(_ value: ReleaseIdentity) -> PolicyWireValue { .object([
        "schema": .string(value.schema), "version": .string(value.version), "buildNumber": .string(value.buildNumber),
        "sourceRevision": .string(value.sourceRevision), "sourceInputSHA256": .string(value.sourceInputSHA256),
        "releaseContractSHA256": .string(value.releaseContractSHA256), "architecture": .string(value.architecture),
        "minimumSystemVersion": .string(value.minimumSystemVersion), "buildMode": .string(value.buildMode),
    ]) }
}
