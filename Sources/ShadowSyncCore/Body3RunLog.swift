import Darwin
import Foundation

public let shadowSyncBody3LogSchema =
    "shadow-sync-log/v2"

public struct Body3CommandLogEvidence:
    Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let force: String?
    public let outcome: String

    public init(
        executable: String,
        arguments: [String],
        force: String? = nil,
        outcome: String
    ) {
        self.executable = executable
        self.arguments = arguments
        self.force = force
        self.outcome = outcome
    }

    public init(_ removal: RemovalCommandEvidence) {
        self.init(
            executable: removal.executable,
            arguments: removal.arguments,
            force: removal.forceLevel.rawValue,
            outcome: removal.outcome
        )
    }
}

public struct Body3LogRecord:
    Codable, Equatable, Sendable {
    public let schema: String
    public let run: String
    public let sequence: Int
    public let timestamp: String
    public let type: String
    public let repository: String?
    public let operation: String?
    public let target: String?
    public let kind: String?
    public let phase: String?
    public let worker: Int?
    public let recommendation: String?
    public let selection: String?
    public let awa: String?
    public let retention: String?
    public let artifact: String?
    public let restore: String?
    public let exclusions: [String]?
    public let executable: String?
    public let arguments: [String]?
    public let force: String?
    public let outcome: String?
    public let status: Body3BatchNodeStatus?
    public let residue: String?
    public let recovery: String?
    public let detail: String?
    public let technicalDetail: String?
    public let durationMilliseconds: Int64?
    public let plan: Body3BatchPlan?
    public let report: Body3BatchReport?

    public init(
        run: String,
        sequence: Int,
        type: String,
        repository: String? = nil,
        operation: String? = nil,
        target: String? = nil,
        kind: String? = nil,
        phase: String? = nil,
        worker: Int? = nil,
        recommendation: String? = nil,
        selection: String? = nil,
        awa: String? = nil,
        retention: String? = nil,
        artifact: String? = nil,
        restore: String? = nil,
        exclusions: [String]? = nil,
        executable: String? = nil,
        arguments: [String]? = nil,
        force: String? = nil,
        outcome: String? = nil,
        status: Body3BatchNodeStatus? = nil,
        residue: String? = nil,
        recovery: String? = nil,
        detail: String? = nil,
        technicalDetail: String? = nil,
        durationMilliseconds: Int64? = nil,
        plan: Body3BatchPlan? = nil,
        report: Body3BatchReport? = nil
    ) {
        schema = shadowSyncBody3LogSchema
        self.run = run
        self.sequence = sequence
        timestamp = WallClock.timestamp()
        self.type = Redactor.sanitize(type)
        self.repository = repository.map(
            Redactor.sanitize
        )
        self.operation = operation.map(
            Redactor.sanitize
        )
        self.target = target.map(Redactor.sanitize)
        self.kind = kind.map(Redactor.sanitize)
        self.phase = phase.map(Redactor.sanitize)
        self.worker = worker
        self.recommendation =
            recommendation.map(Redactor.sanitize)
        self.selection = selection.map(Redactor.sanitize)
        self.awa = awa.map(Redactor.sanitize)
        self.retention = retention.map(Redactor.sanitize)
        self.artifact = artifact.map(Redactor.sanitize)
        self.restore = restore.map(Redactor.sanitize)
        self.exclusions = exclusions?.prefix(100).map {
            String(Redactor.sanitize($0).prefix(1_024))
        }
        self.executable = executable.map(
            Redactor.sanitize
        )
        self.arguments = arguments?.prefix(32).map {
            String(Redactor.sanitize($0).prefix(4_096))
        }
        self.force = force.map(Redactor.sanitize)
        self.outcome = outcome.map(Redactor.sanitize)
        self.status = status
        self.residue = residue.map(Redactor.sanitize)
        self.recovery = recovery.map(Redactor.sanitize)
        self.detail = detail.map {
            String(Redactor.sanitize($0).prefix(4_096))
        }
        self.technicalDetail =
            Body3TechnicalDetail.canonical(technicalDetail)
        self.durationMilliseconds = durationMilliseconds
        self.plan = plan
        self.report = report
    }
}

public final class Body3RunLogWriter:
    @unchecked Sendable {
    private static let maximumBytes = 4_194_304
    private static let maximumLineBytes = 1_048_576
    private let lock = NSLock()
    private let file: OwnedFileDescriptor
    private let encoder: JSONEncoder
    private var nextSequence = 1
    private var writtenBytes = 0
    public let runID: String
    public let path: String

    public init(
        authority: RunAuthority,
        plan: Body3BatchPlan
    ) throws {
        guard plan.schema
                == "shadow-sync-batch-plan/v2" else {
            throw GitSafetyError.unsafeRepository(
                "Body 3 log requires an immutable v2 plan"
            )
        }
        runID = plan.run
        path = authority.stateDirectory.path
            + "/latest.log"
        let configuredEncoder = JSONEncoder()
        configuredEncoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        let initialRecord = Body3LogRecord(
            run: plan.run,
            sequence: 1,
            type: "plan",
            phase: "Queued",
            detail:
                "Immutable selected operation plan recorded.",
            plan: plan
        )
        var initialData =
            try configuredEncoder.encode(initialRecord)
        guard initialData.count + 1
                <= Self.maximumLineBytes,
              initialData.count + 1
                <= Self.maximumBytes else {
            throw SecureStateError.unsafePath(
                "Body 3 immutable plan framing bound"
            )
        }
        initialData.append(0x0A)
        let descriptor = try authority.openRetainedLogForWriting(append: true)
        guard ftruncate(descriptor, 0) == 0,
              lseek(descriptor, 0, SEEK_SET) >= 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw SecureStateError.systemCall(
                "initialize Body 3 latest.log",
                code
            )
        }
        file = OwnedFileDescriptor(descriptor)
        encoder = configuredEncoder
        try writeAll(initialData)
        nextSequence = 2
        writtenBytes = initialData.count
        try flush()
    }

    @discardableResult
    public func append(
        type: String,
        repository: String? = nil,
        operation: String? = nil,
        target: String? = nil,
        kind: String? = nil,
        phase: String? = nil,
        worker: Int? = nil,
        recommendation: String? = nil,
        selection: String? = nil,
        awa: String? = nil,
        retention: String? = nil,
        artifact: String? = nil,
        restore: String? = nil,
        exclusions: [String]? = nil,
        command: Body3CommandLogEvidence? = nil,
        outcome: String? = nil,
        status: Body3BatchNodeStatus? = nil,
        residue: String? = nil,
        recovery: String? = nil,
        detail: String? = nil,
        technicalDetail: String? = nil,
        durationMilliseconds: Int64? = nil,
        plan: Body3BatchPlan? = nil,
        report: Body3BatchReport? = nil
    ) throws -> Body3LogRecord {
        guard (plan == nil || plan?.schema == "shadow-sync-batch-plan/v2"),
              (report == nil || report?.schema == "shadow-sync-batch-report/v2") else {
            throw SecureStateError.unsafePath("new batch log writes require current record identity")
        }
        lock.lock()
        defer { lock.unlock() }
        let record = Body3LogRecord(
            run: runID,
            sequence: nextSequence,
            type: type,
            repository: repository,
            operation: operation,
            target: target,
            kind: kind,
            phase: phase,
            worker: worker,
            recommendation: recommendation,
            selection: selection,
            awa: awa,
            retention: retention,
            artifact: artifact,
            restore: restore,
            exclusions: exclusions,
            executable: command?.executable,
            arguments: command?.arguments,
            force: command?.force,
            outcome: outcome ?? command?.outcome,
            status: status,
            residue: residue,
            recovery: recovery,
            detail: detail,
            technicalDetail: technicalDetail,
            durationMilliseconds: durationMilliseconds,
            plan: plan,
            report: report
        )
        var data = try encoder.encode(record)
        guard data.count + 1 <= Self.maximumLineBytes,
              writtenBytes + data.count + 1
                <= Self.maximumBytes else {
            throw SecureStateError.unsafePath(
                "Body 3 latest.log framing bound"
            )
        }
        data.append(0x0A)
        try writeAll(data)
        nextSequence += 1
        writtenBytes += data.count
        return record
    }

    public func flush() throws {
        lock.lock()
        defer { lock.unlock() }
        guard fsync(file.value) == 0 else {
            throw SecureStateError.systemCall(
                "fsync Body 3 latest.log",
                errno
            )
        }
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    file.value,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw SecureStateError.systemCall(
                        "write Body 3 latest.log",
                        errno
                    )
                }
            }
        }
    }
}

public enum Body3RunLogReader {
    public static func records(
        state: SecureStateDirectory,
        maximumBytes: Int = 4_194_304
    ) throws -> [Body3LogRecord] {
        let descriptor = try state.openRegularFile(
            named: "latest.log",
            flags: O_RDONLY,
            create: false,
            repairPermissions: false
        )
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_size >= 0,
              info.st_size <= maximumBytes else {
            throw SecureStateError.unsafePath(
                "Body 3 latest.log size"
            )
        }
        var data = Data(count: Int(info.st_size))
        let read = try data.withUnsafeMutableBytes {
            bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count == 0 {
                    break
                } else if errno == EINTR {
                    continue
                } else {
                    throw SecureStateError.systemCall(
                        "read Body 3 latest.log",
                        errno
                    )
                }
            }
            return offset
        }
        data.count = read
        return decode(data)
    }

    static func decode(
        _ source: Data
    ) -> [Body3LogRecord] {
        var data = source
        if data.last != 0x0A {
            guard let last = data.lastIndex(of: 0x0A) else {
                return []
            }
            data = data.prefix(through: last)
        }
        let decoder = JSONDecoder()
        var result: [Body3LogRecord] = []
        var sequence = 1
        var run: String?
        var logIdentity: HistoricalLogIdentity?
        var immutablePlan: Body3BatchPlan?
        var nodeStates:
            [String: Body3BatchNodeStatus] = [:]
        var sawReport = false
        for line in data.split(
            separator: 0x0A,
            omittingEmptySubsequences: true
        ) {
            guard line.count <= 1_048_576,
                  let record = try? decoder.decode(
                    Body3LogRecord.self,
                    from: Data(line)
                  ),
                  let recordIdentity = HistoricalLogIdentity.v2(record.schema),
                  logIdentity == nil || logIdentity == recordIdentity,
                  record.sequence == sequence,
                  RunIdentity.isValid(record.run),
                  run == nil || run == record.run,
                  record.worker == nil
                    || (1...2).contains(record.worker!),
                  record.plan == nil
                    || record.plan?.run == record.run,
                  record.report == nil
                    || record.report?.run == record.run else {
                return []
            }
            logIdentity = recordIdentity
            if let technicalDetail = record.technicalDetail,
               !Body3TechnicalDetail.isCanonical(
                   technicalDetail
               ) {
                return []
            }
            if sequence == 1 {
                guard record.type == "plan",
                      record.plan?.isStructurallyValidForLog(recordIdentity)
                        == true,
                      record.operation == nil,
                      record.status == nil else {
                    return []
                }
                immutablePlan = record.plan
            } else {
                guard record.plan == nil,
                      immutablePlan != nil else {
                    return []
                }
            }
            if let operation = record.operation,
               let status = record.status {
                guard immutablePlan?.nodes.contains(
                    where: { $0.id == operation }
                ) == true else {
                    break
                }
                let previous = nodeStates[operation]
                if let previous, previous.isTerminal {
                    return []
                }
                if previous == nil,
                   status != .running,
                   status != .cancelled,
                   status != .cleanupPending {
                    return []
                }
                nodeStates[operation] = status
            }
            if let report = record.report {
                guard !sawReport,
                      ((record.type == "run_finished" && !report.cleanupPending)
                        || (record.type == "run_cleanup_pending" && report.cleanupPending && record.status == .cleanupPending)),
                      report.schema == recordIdentity.v2Report,
                      report.results.count
                        == immutablePlan?.nodes.count,
                      Set(report.results.map(\.node.id))
                        == Set(
                            immutablePlan?.nodes.map(\.id)
                                ?? []
                        ),
                      report.results.allSatisfy({
                          $0.status.isSettled
                            && immutablePlan?.nodes
                                .contains($0.node)
                                == true
                            && (
                                nodeStates[$0.node.id] == nil
                                    || nodeStates[$0.node.id]
                                        == $0.status
                            )
                      }),
                      (try? Body3BatchMetadata.deriveForLog(
                          plan: immutablePlan!,
                          report: report,
                          identity: recordIdentity
                      )) != nil else {
                    return []
                }
                sawReport = true
            } else if sawReport {
                return []
            }
            result.append(record)
            run = record.run
            sequence += 1
        }
        return result
    }

    public static func render(
        _ records: [Body3LogRecord],
        maximumCharacters: Int = 131_072
    ) -> String {
        let lines = records.map(renderLine)
        let rendered = lines.joined(separator: "\n")
        guard rendered.count > maximumCharacters else {
            return rendered
        }
        return "… earlier validated events omitted …\n"
            + String(rendered.suffix(maximumCharacters))
    }

    public static func renderLine(
        _ record: Body3LogRecord
    ) -> String {
        var fields = [
            "#\(record.sequence)",
            record.timestamp,
            record.phase ?? record.type,
            record.repository ?? "batch",
            record.operation ?? record.type,
        ]
        if let status = record.status {
            fields.append(status.rawValue)
        }
        if let worker = record.worker {
            fields.append("worker \(worker)")
        }
        if let recommendation = record.recommendation {
            fields.append(
                "recommendation \(recommendation)"
            )
        }
        if let selection = record.selection {
            fields.append("selection \(selection)")
        }
        if let awa = record.awa {
            fields.append("AWA \(awa)")
        }
        if let retention = record.retention {
            fields.append("retention \(retention)")
        }
        if let artifact = record.artifact {
            fields.append("artifact \(artifact)")
        }
        if let restore = record.restore {
            fields.append("restore \(restore)")
        }
        if let exclusions = record.exclusions,
           !exclusions.isEmpty {
            fields.append(
                "exclusions "
                    + exclusions.joined(separator: ", ")
            )
        }
        if let executable = record.executable {
            fields.append(
                ([executable]
                    + (record.arguments ?? []))
                    .joined(separator: " ")
            )
            if let outcome = record.outcome {
                fields.append(outcome)
            }
        }
        if let detail = record.detail {
            fields.append(detail)
        }
        if let technicalDetail = record.technicalDetail {
            fields.append(
                "technical \(technicalDetail)"
            )
        }
        if let residue = record.residue {
            fields.append("residue \(residue)")
        }
        if let recovery = record.recovery {
            fields.append("recovery \(recovery)")
        }
        if let duration = record.durationMilliseconds {
            fields.append("duration \(duration) ms")
        }
        return fields.map(Redactor.sanitize)
            .joined(separator: " · ")
    }
}

public struct Body3RunLogProjectionMetrics:
    Equatable, Sendable {
    public let recordVisits: Int
    public let renderedCharacterCount: Int
    public let retainedCharacterCount: Int
    public let omittedEarlierEvents: Bool
}

public struct Body3RunLogProjectionMutation:
    Equatable, Sendable {
    public let appendedText: String
    public let removedLeadingCharacters: Int
    public let removedLeadingUTF16Units: Int
    public let startedOmittingEarlierEvents: Bool
}

public final class Body3RunLogProjection {
    public static let defaultMaximumCharacters = 131_072
    public static let omissionMarker =
        "… earlier validated events omitted …\n"
    private let maximumCharacters: Int
    private var chunks: [String] = []
    private var firstChunkIndex = 0
    private var retainedCharacterCount = 0
    private var recordVisits = 0
    private var renderedCharacterCount = 0
    private var omittedEarlierEvents = false

    public init(
        maximumCharacters: Int =
            Body3RunLogProjection.defaultMaximumCharacters
    ) {
        precondition(maximumCharacters > 0)
        self.maximumCharacters = maximumCharacters
    }

    @discardableResult
    public func append(
        _ record: Body3LogRecord
    ) -> Body3RunLogProjectionMutation {
        let line = Body3RunLogReader.renderLine(record)
        let addition =
            (recordVisits == 0 ? "" : "\n") + line
        let wasOmitting = omittedEarlierEvents
        recordVisits += 1
        renderedCharacterCount += addition.count
        chunks.append(addition)
        retainedCharacterCount += addition.count
        var removed = 0
        var removedUTF16 = 0
        while retainedCharacterCount
                > maximumCharacters {
            let excess =
                retainedCharacterCount
                    - maximumCharacters
            let chunk = chunks[firstChunkIndex]
            if chunk.count <= excess {
                removed += chunk.count
                removedUTF16 += chunk.utf16.count
                retainedCharacterCount -= chunk.count
                chunks[firstChunkIndex] = ""
                firstChunkIndex += 1
            } else {
                let removedPrefix = String(
                    chunk.prefix(excess)
                )
                chunks[firstChunkIndex] = String(
                    chunk.dropFirst(excess)
                )
                removed += excess
                removedUTF16 +=
                    removedPrefix.utf16.count
                retainedCharacterCount -= excess
            }
            omittedEarlierEvents = true
        }
        if firstChunkIndex >= 1_024,
           firstChunkIndex * 2 >= chunks.count {
            chunks.removeFirst(firstChunkIndex)
            firstChunkIndex = 0
        }
        return Body3RunLogProjectionMutation(
            appendedText: addition,
            removedLeadingCharacters: removed,
            removedLeadingUTF16Units: removedUTF16,
            startedOmittingEarlierEvents:
                !wasOmitting && omittedEarlierEvents
        )
    }

    public var text: String {
        let retained = chunks[
            firstChunkIndex..<chunks.count
        ].joined()
        guard omittedEarlierEvents else {
            return retained
        }
        return Self.omissionMarker
            + retained
    }

    public var isOmittingEarlierEvents: Bool {
        omittedEarlierEvents
    }

    public var metrics: Body3RunLogProjectionMetrics {
        Body3RunLogProjectionMetrics(
            recordVisits: recordVisits,
            renderedCharacterCount:
                renderedCharacterCount,
            retainedCharacterCount:
                retainedCharacterCount,
            omittedEarlierEvents:
                omittedEarlierEvents
        )
    }
}

public struct Body3RecoveredNodeDisposition:
    Equatable, Sendable {
    public let status: Body3BatchNodeStatus
    public let detail: String

    public init(
        status: Body3BatchNodeStatus,
        detail: String
    ) {
        precondition(status.isSettled)
        self.status = status
        self.detail = Redactor.sanitize(detail)
    }
}

public enum Body3InterruptedRunReconstructor {
    public static func reconstruct(
        records: [Body3LogRecord],
        postflight: (
            Body3BatchNode
        ) -> Body3RecoveredNodeDisposition
    ) -> Body3BatchReport? {
        guard let plan = records.first(
            where: { $0.plan != nil }
        )?.plan,
        plan.schema == "shadow-sync-batch-plan/v2" else {
            return nil
        }
        if let completed = records.reversed()
            .compactMap(\.report).first,
           completed.run == plan.run,
           completed.results.count == plan.nodes.count,
           completed.results.allSatisfy({
               $0.status.isSettled
           }) {
            return completed
        }
        let latest = Dictionary(
            records.compactMap { record -> (
                String,
                Body3LogRecord
            )? in
                guard let operation = record.operation,
                      plan.nodes.contains(where: {
                          $0.id == operation
                      }) else { return nil }
                return (operation, record)
            },
            uniquingKeysWith: { _, new in new }
        )
        let started = Dictionary(
            records.compactMap { record -> (
                String,
                Body3LogRecord
            )? in
                guard record.type == "node_started",
                      let operation = record.operation,
                      record.status == .running,
                      plan.nodes.contains(where: {
                          $0.id == operation
                      }) else { return nil }
                return (operation, record)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let durableEnd =
            records.last?.timestamp ?? plan.createdAt
        let results = plan.nodes.map { node
            -> Body3BatchNodeResult in
            if let record = latest[node.id],
               let status = record.status,
               status.isSettled {
                return Body3BatchNodeResult(
                    node: node,
                    status: status,
                    worker: record.worker,
                    startedAt:
                        started[node.id]?.timestamp,
                    endedAt: record.timestamp,
                    durationMilliseconds:
                        record.durationMilliseconds ?? 0,
                    detail: record.detail
                        ?? "Recovered terminal event.",
                    technicalDetail:
                        record.technicalDetail
                )
            }
            let observed = postflight(node)
            return Body3BatchNodeResult(
                node: node,
                status: observed.status,
                worker: latest[node.id]?.worker,
                startedAt: started[node.id]?.timestamp,
                endedAt: durableEnd,
                durationMilliseconds: 0,
                detail:
                    "Interrupted node was postflighted without retry. "
                    + observed.detail,
                technicalDetail: nil
            )
        }
        return try? Body3BatchReport(
            run: plan.run,
            startedAt: plan.createdAt,
            endedAt: durableEnd,
            cancelled: true,
            results: results
        )
    }
}

public struct Body3RecoveredRun:
    Equatable, Sendable {
    public let plan: Body3BatchPlan
    public let report: Body3BatchReport
    public let records: [Body3LogRecord]

    public var requiresReview: Bool {
        !records.contains(where: { $0.report != nil })
            || report.requiresReview
    }

    public init(
        plan: Body3BatchPlan,
        report: Body3BatchReport,
        records: [Body3LogRecord]
    ) {
        self.plan = plan
        self.report = report
        self.records = records
    }
}

public enum Body3RunRecoveryState:
    Equatable, Sendable {
    case notBody3
    case previous(Body3RecoveredRun)
    case operationStillActive
    case needsAttention
}

public enum Body3RunRecoveryInspector {
    public static func inspect(
        at location: StateLocation,
        account: EffectiveAccount
    ) -> Body3RunRecoveryState {
        let authority: RunAuthority
        do {
            authority = try RunAuthority.acquireRun(
                at: location
            )
        } catch let SecureStateError.contention(name)
            where name == "operation.lock"
                || name == "run.lock" {
            return .operationStillActive
        } catch {
            return .needsAttention
        }
        defer { authority.release() }
        do {
            let records = try Body3RunLogReader.records(
                state: authority.stateDirectory
            )
            guard !records.isEmpty else {
                return try latestLogDeclaresBody3(
                    state: authority.stateDirectory
                ) ? .needsAttention : .notBody3
            }
            guard let plan = records.first?.plan else {
                return .needsAttention
            }
            let store = RetentionArtifactStore(
                state: authority.stateDirectory,
                account: account
            )
            let summaries = try store.list()
            let artifacts = Dictionary(
                uniqueKeysWithValues: summaries.map {
                    ($0.artifactID, $0)
                }
            )
            let artifactByNode = Dictionary(
                records.compactMap {
                    record -> (String, String)? in
                    guard let operation = record.operation,
                          let artifact = record.artifact else {
                        return nil
                    }
                    return (operation, artifact)
                },
                uniquingKeysWith: { _, latest in latest }
            )
            guard let report =
                    Body3InterruptedRunReconstructor
                        .reconstruct(
                            records: records,
                            postflight: { node in
                                postflight(
                                    node,
                                    artifactID:
                                        artifactByNode[
                                            node.id
                                        ],
                                    artifacts: artifacts
                                )
                            }
                        ) else {
                return .needsAttention
            }
            return .previous(Body3RecoveredRun(
                plan: plan,
                report: report,
                records: records
            ))
        } catch let SecureStateError.systemCall(_, code)
            where code == ENOENT {
            return .notBody3
        } catch {
            return .needsAttention
        }
    }

    private static func postflight(
        _ node: Body3BatchNode,
        artifactID: String?,
        artifacts: [String: RetentionArtifactSummary]
    ) -> Body3RecoveredNodeDisposition {
        let artifactIntact = artifactID.map {
            artifacts[$0]?.restoreProven == true
        } ?? true
        do {
            switch node.payload {
            case let .operation(operation):
                guard operation.kind == .fastForward
                        || operation.kind
                            == .initializeDefaultBranch else {
                    return disposition(
                        .failed,
                        "Interrupted Repair requires fresh repository inspection; it was not retried or inferred from the default ref."
                    )
                }
                let observed = try localRefOID(
                    operation.target.resolvedDefault
                        .localRef,
                    candidate: operation.target
                        .canonicalClone.sourceSnapshot
                )
                if observed
                    == operation.target.expectedFetchedOID {
                    return disposition(
                        .succeeded,
                        "Fresh default-ref postflight found the planned target."
                    )
                }
                if observed
                    == operation.target.expectedLocalOID {
                    return disposition(
                        .cancelled,
                        "Fresh default-ref postflight found the pre-run value."
                    )
                }
                return disposition(
                    .failed,
                    "Fresh default-ref postflight is ambiguous."
                )

            case .reinspection, .confirmation,
                 .policyInvalidation:
                return disposition(
                    .cancelled,
                    "Read-only or confirmation work is never retried."
                )

            case .retention:
                guard let artifactID else {
                    return disposition(
                        .cancelled,
                        "No completed artifact was recorded before interruption."
                    )
                }
                return disposition(
                    artifacts[artifactID]?.restoreProven
                        == true ? .succeeded : .failed,
                    artifacts[artifactID]?.restoreProven
                        == true
                        ? "A logged completed artifact remains restore-proven."
                        : "The logged completed artifact was not trusted."
                )

            case let .removal(candidate):
                return removalPostflight(
                    candidate,
                    artifactIntact: artifactIntact
                )

            case let .residue(candidate):
                let observed = removalPostflight(
                    candidate,
                    artifactIntact: artifactIntact
                )
                return disposition(
                    observed.status == .failed
                        ? .failed : .succeeded,
                    "Fresh residue inspection completed. "
                        + observed.detail
                )
            }
        } catch {
            return disposition(
                .failed,
                "Fresh entity/ref postflight could not be proven."
            )
        }
    }

    private static func removalPostflight(
        _ candidate: RemovalCandidate,
        artifactIntact: Bool
    ) -> Body3RecoveredNodeDisposition {
        guard artifactIntact else {
            return disposition(
                .failed,
                "The logged recovery artifact is not intact."
            )
        }
        do {
            let metadata = try commonMetadata(candidate)
            defer { Darwin.close(metadata.descriptor) }
            if let worktree = candidate.worktree {
                var info = stat()
                let pathPresent =
                    lstat(worktree.path, &info) == 0
                let registrationPresent =
                    worktree.registrationIdentity.map {
                        metadata.registrations
                            .contains($0)
                    } ?? false
                if !pathPresent && !registrationPresent {
                    return disposition(
                        .succeeded,
                        "Path and Git registration are absent."
                    )
                }
                if pathPresent && registrationPresent {
                    return disposition(
                        .cancelled,
                        "Path and Git registration remain present."
                    )
                }
                return disposition(
                    .failed,
                    "Path and Git registration disagree; attention is required."
                )
            }
            guard let branch = candidate.branch else {
                return disposition(
                    .failed,
                    "Removal target is incomplete."
                )
            }
            let observed = try localRefOID(
                branch.fullRef,
                commonDescriptor: metadata.descriptor
            )
            let claims = metadata.claims[
                branch.fullRef,
                default: 0
            ]
            if observed == nil && claims == 0 {
                return disposition(
                    .succeeded,
                    "Local ref is absent and fresh claims are empty."
                )
            }
            if observed == branch.tipOID && claims == 0 {
                return disposition(
                    .cancelled,
                    "Expected local ref remains and fresh claims are empty."
                )
            }
            return disposition(
                .failed,
                "Local ref or fresh claims are ambiguous."
            )
        } catch {
            return disposition(
                .failed,
                "Fresh removal postflight could not be proven."
            )
        }
    }

    private struct CommonMetadata {
        let descriptor: Int32
        let registrations: [RepositoryDirectoryIdentity]
        let claims: [String: Int]
    }

    private static func commonMetadata(
        _ candidate: RemovalCandidate
    ) throws -> CommonMetadata {
        let path = candidate.clone.primaryRoot + "/.git"
        let common = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard common >= 0 else {
            throw SecureStateError.systemCall(
                "open recovery common directory",
                errno
            )
        }
        var returnedDescriptor = false
        defer {
            if !returnedDescriptor {
                Darwin.close(common)
            }
        }
        var info = stat()
        guard fstat(common, &info) == 0,
              info.st_uid == geteuid(),
              (info.st_mode & 0o022) == 0,
              RepositoryDirectoryIdentity(FileIdentity(info))
                == candidate.clone.commonDirectoryIdentity else {
            throw GitSafetyError.unsafeRepository(
                "recovery common-directory identity changed"
            )
        }
        var claims: [String: Int] = [:]
        guard let head = try readRegular(
            "HEAD",
            parent: common,
            maximumBytes: 1_024
        ) else {
            throw GitSafetyError.unsafeRepository(
                "recovery primary HEAD is unavailable"
            )
        }
        try recordClaim(head, into: &claims)
        var registrations:
            [RepositoryDirectoryIdentity] = []
        let worktrees = openat(
            common,
            "worktrees",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if worktrees >= 0 {
            defer { Darwin.close(worktrees) }
            var worktreesInfo = stat()
            guard fstat(worktrees, &worktreesInfo) == 0,
                  FileIdentity(worktreesInfo).isDirectory,
                  worktreesInfo.st_uid == geteuid(),
                  (worktreesInfo.st_mode & 0o022) == 0 else {
                throw GitSafetyError.unsafeRepository(
                    "recovery worktree directory is unsafe"
                )
            }
            for name in try directoryNames(worktrees) {
                let registration = openat(
                    worktrees,
                    name,
                    O_RDONLY | O_DIRECTORY
                        | O_NOFOLLOW | O_CLOEXEC
                )
                guard registration >= 0 else {
                    throw GitSafetyError.unsafeRepository(
                        "recovery registration is unsafe"
                    )
                }
                do {
                    var registrationInfo = stat()
                    guard fstat(
                        registration,
                        &registrationInfo
                    ) == 0,
                    FileIdentity(registrationInfo).isDirectory,
                    registrationInfo.st_uid == geteuid(),
                    (registrationInfo.st_mode & 0o022) == 0 else {
                        throw GitSafetyError.unsafeRepository(
                            "recovery registration cannot be inspected"
                        )
                    }
                    registrations.append(
                        RepositoryDirectoryIdentity(
                            FileIdentity(registrationInfo)
                        )
                    )
                    guard let head = try readRegular(
                        "HEAD",
                        parent: registration,
                        maximumBytes: 1_024
                    ) else {
                        throw GitSafetyError.unsafeRepository(
                            "recovery linked HEAD is unavailable"
                        )
                    }
                    try recordClaim(head, into: &claims)
                } catch {
                    Darwin.close(registration)
                    throw error
                }
                Darwin.close(registration)
            }
        } else if errno != ENOENT {
            throw GitSafetyError.unsafeRepository(
                "recovery worktree metadata is unsafe"
            )
        }
        returnedDescriptor = true
        return CommonMetadata(
            descriptor: common,
            registrations: registrations,
            claims: claims
        )
    }

    private static func localRefOID(
        _ reference: String,
        candidate: RepositoryCandidate
    ) throws -> String? {
        let path = candidate.path + "/.git"
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SecureStateError.systemCall(
                "open recovery Git directory",
                errno
            )
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_uid == geteuid(),
              (info.st_mode & 0o022) == 0,
              RepositoryDirectoryIdentity(FileIdentity(info))
                == candidate.commonDirectoryIdentity else {
            throw GitSafetyError.unsafeRepository(
                "recovery Git-directory identity changed"
            )
        }
        return try localRefOID(
            reference,
            commonDescriptor: descriptor
        )
    }

    private static func localRefOID(
        _ reference: String,
        commonDescriptor: Int32
    ) throws -> String? {
        guard GitReferenceSyntax.isValidLocalBranchRef(
            reference
        ) else {
            throw GitSafetyError.unsafeRepository(
                "recovery local ref is malformed"
            )
        }
        if let loose = try readRelativeRegular(
            reference,
            parent: commonDescriptor,
            maximumBytes: 256
        ) {
            let value = String(
                decoding: loose,
                as: UTF8.self
            ).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard isOID(value) else {
                throw GitSafetyError.unsafeRepository(
                    "recovery loose ref is malformed"
                )
            }
            return value.lowercased()
        }
        guard let packed = try readRegular(
            "packed-refs",
            parent: commonDescriptor,
            maximumBytes: 1_048_576
        ) else {
            return nil
        }
        var match: String?
        for line in String(
            decoding: packed,
            as: UTF8.self
        ).split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.count == 2,
               fields[1] == Substring(reference) {
                let value = String(fields[0])
                guard isOID(value), match == nil else {
                    throw GitSafetyError.unsafeRepository(
                        "recovery packed ref is ambiguous"
                    )
                }
                match = value.lowercased()
            }
        }
        return match
    }

    private static func readRelativeRegular(
        _ path: String,
        parent: Int32,
        maximumBytes: Int
    ) throws -> Data? {
        let components = path.split(separator: "/")
        guard !components.isEmpty else { return nil }
        var directory = fcntl(
            parent,
            F_DUPFD_CLOEXEC,
            0
        )
        guard directory >= 0 else {
            throw SecureStateError.systemCall(
                "duplicate recovery directory",
                errno
            )
        }
        defer { Darwin.close(directory) }
        for component in components.dropLast() {
            let next = openat(
                directory,
                String(component),
                O_RDONLY | O_DIRECTORY
                    | O_NOFOLLOW | O_CLOEXEC
            )
            if next < 0, errno == ENOENT {
                return nil
            }
            guard next >= 0 else {
                throw GitSafetyError.unsafeRepository(
                    "recovery ref path is unsafe"
                )
            }
            Darwin.close(directory)
            directory = next
        }
        return try readRegular(
            String(components.last!),
            parent: directory,
            maximumBytes: maximumBytes
        )
    }

    private static func readRegular(
        _ name: String,
        parent: Int32,
        maximumBytes: Int
    ) throws -> Data? {
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT {
            return nil
        }
        guard descriptor >= 0 else {
            throw GitSafetyError.unsafeRepository(
                "recovery metadata is unsafe"
            )
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        var named = stat()
        guard fstat(descriptor, &info) == 0,
              fstatat(
                  parent,
                  name,
                  &named,
                  AT_SYMLINK_NOFOLLOW
              ) == 0,
              FileIdentity(info) == FileIdentity(named),
              FileIdentity(info).isRegular,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              (info.st_mode & 0o022) == 0,
              info.st_size >= 0,
              info.st_size <= maximumBytes else {
            throw GitSafetyError.unsafeRepository(
                "recovery metadata is invalid"
            )
        }
        var data = Data(count: Int(info.st_size))
        let count = try data.withUnsafeMutableBytes {
            bytes -> Int in
            guard let base = bytes.baseAddress else {
                return 0
            }
            var offset = 0
            while offset < bytes.count {
                let readCount = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if readCount > 0 {
                    offset += readCount
                } else if readCount == 0 {
                    break
                } else if errno != EINTR {
                    throw SecureStateError.systemCall(
                        "read recovery metadata",
                        errno
                    )
                }
            }
            return offset
        }
        data.count = count
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              FileIdentity(after) == FileIdentity(info),
              after.st_size == info.st_size,
              after.st_mtimespec.tv_sec
                == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec
                == info.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec
                == info.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec
                == info.st_ctimespec.tv_nsec else {
            throw GitSafetyError.unsafeRepository(
                "recovery metadata changed while read"
            )
        }
        return data
    }

    private static func directoryNames(
        _ descriptor: Int32
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
                "recovery directory cannot be enumerated"
            )
        }
        defer { closedir(directory) }
        var names: [String] = []
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
            if name != "." && name != ".." {
                guard !name.contains("/"),
                      !name.contains("\0") else {
                    throw GitSafetyError.unsafeRepository(
                        "recovery directory entry is invalid"
                    )
                }
                names.append(name)
            }
        }
        return names.sorted()
    }

    private static func recordClaim(
        _ data: Data,
        into claims: inout [String: Int]
    ) throws {
        let line = String(
            decoding: data,
            as: UTF8.self
        ).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if isOID(line) { return }
        guard line.hasPrefix("ref: ") else {
            throw GitSafetyError.unsafeRepository(
                "recovery HEAD is malformed"
            )
        }
        let reference = String(line.dropFirst(5))
        guard GitReferenceSyntax.isValidLocalBranchRef(
            reference
        ) else {
            throw GitSafetyError.unsafeRepository(
                "recovery HEAD ref is malformed"
            )
        }
        claims[reference, default: 0] += 1
    }

    private static func latestLogDeclaresBody3(
        state: SecureStateDirectory
    ) throws -> Bool {
        guard let data = try readRegular(
            "latest.log",
            parent: state.descriptor.value,
            maximumBytes: 4_194_304
        ) else {
            return false
        }
        return data.prefix(1_048_576).range(
            of: Data(shadowSyncBody3LogSchema.utf8)
        ) != nil
    }

    private static func isOID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy {
                $0.isNumber
                    || ("a"..."f").contains(
                        $0.lowercased()
                    )
            }
    }

    private static func disposition(
        _ status: Body3BatchNodeStatus,
        _ detail: String
    ) -> Body3RecoveredNodeDisposition {
        Body3RecoveredNodeDisposition(
            status: status,
            detail: detail
        )
    }
}
