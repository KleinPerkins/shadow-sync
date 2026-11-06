import Darwin
import Foundation

public struct LogRecord: Codable, Equatable, Sendable {
    public let schema: String
    public let run: String
    public let sequence: Int
    public let timestamp: String
    public let type: String
    public let event: RunEvent?
    public let report: RunReport?
    public let intent: RunIntent?
    public let checkpoint: RepositoryCheckpoint?
    public let data: String?

    public init(
        run: String,
        sequence: Int,
        type: String,
        event: RunEvent? = nil,
        report: RunReport? = nil,
        intent: RunIntent? = nil,
        checkpoint: RepositoryCheckpoint? = nil,
        data: String? = nil
    ) {
        self.schema = shadowSyncRecordSchema
        self.run = run
        self.sequence = sequence
        self.timestamp = WallClock.timestamp()
        self.type = type
        self.event = event
        self.report = report
        self.intent = intent
        self.checkpoint = checkpoint
        self.data = data
    }
}

public enum Redactor {
    public static let subprocessByteLimit = 8_192
    private struct Rule: @unchecked Sendable {
        let expression: NSRegularExpression
        let replacement: String
    }

    private static let rules: [Rule] = [
        (
            #"(?is)-----BEGIN [^-\r\n]*PRIVATE KEY-----.*?-----END [^-\r\n]*PRIVATE KEY-----"#,
            "[REDACTED PRIVATE KEY]"
        ),
        (
            #"(?i)(authorization\s*[:=]\s*)(?:bearer\s+)?[^\s,\r\n]+"#,
            "$1[REDACTED]"
        ),
        (
            #"(?i)(\bbearer\s+)[A-Za-z0-9._~+/\-=]{8,}"#,
            "$1[REDACTED]"
        ),
        (
            #"(?i)((?:credentials?|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|private[_-]?key|pat|token|password|passwd|secret)\s*[=:]\s*["']?)[^\s"'&,\r\n]+"#,
            "$1[REDACTED]"
        ),
        (
            #"(?i)([?&](?:credentials?|api[_-]?key|access[_-]?token|pat|token|key)=)[^&\s]+"#,
            "$1[REDACTED]"
        ),
        (
            #"(?i)([a-z][a-z0-9+.-]*://)[^/@\s]+@"#,
            "$1[REDACTED]@"
        ),
        (
            #"(?i)(x-access-token:)[^@\s]+"#,
            "$1[REDACTED]"
        ),
        (
            #"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[A-Z0-9]{16})\b"#,
            "[REDACTED TOKEN]"
        ),
    ].compactMap { pattern, replacement in
        guard let expression = try? NSRegularExpression(
            pattern: pattern
        ) else {
            return nil
        }
        return Rule(
            expression: expression,
            replacement: replacement
        )
    }

    public static func subprocessBytes(_ data: Data) -> String {
        let bounded = data.prefix(subprocessByteLimit)
        var text = String(decoding: bounded, as: UTF8.self)
        if data.count > subprocessByteLimit {
            text += "\n[output truncated]"
        }
        return sanitize(text)
    }

    public static func sanitize(_ input: String) -> String {
        var value = input
        for rule in rules {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = rule.expression.stringByReplacingMatches(
                in: value,
                range: range,
                withTemplate: rule.replacement
            )
        }
        return value
    }

    #if SHADOW_SYNC_TESTING
    public static var testingCompiledExpressionIdentifiers:
        [ObjectIdentifier] {
        rules.map {
            ObjectIdentifier($0.expression)
        }
    }
    #endif
}

public final class RunLogWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let file: OwnedFileDescriptor
    private let encoder: JSONEncoder
    private var nextSequence = 1
    public let path: String
    public let runID: String

    public init(authority: RunAuthority, runID: String) throws {
        self.runID = runID
        path = URL(fileURLWithPath: authority.stateDirectory.path)
            .appendingPathComponent("latest.log").path
        let fd = try authority.openRetainedLogForWriting()
        guard ftruncate(fd, 0) == 0 else {
            let code = errno
            close(fd)
            throw SecureStateError.systemCall("ftruncate latest.log", code)
        }
        guard lseek(fd, 0, SEEK_SET) >= 0 else {
            let code = errno
            close(fd)
            throw SecureStateError.systemCall("lseek latest.log", code)
        }
        file = OwnedFileDescriptor(fd)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    @discardableResult
    public func append(
        type: String,
        event: RunEvent? = nil,
        report: RunReport? = nil,
        intent: RunIntent? = nil,
        checkpoint: RepositoryCheckpoint? = nil,
        data: String? = nil
    ) throws -> LogRecord {
        guard (event == nil || event?.schema == shadowSyncEventSchema),
              (report == nil || report?.schema == "shadow-sync-report/v1") else {
            throw SecureStateError.unsafePath("new log writes require current record identity")
        }
        lock.lock()
        defer { lock.unlock() }
        let record = LogRecord(
            run: runID,
            sequence: nextSequence,
            type: type,
            event: event,
            report: report,
            intent: intent,
            checkpoint: checkpoint,
            data: data.map(Redactor.sanitize)
        )
        nextSequence += 1
        var bytes = try encoder.encode(record)
        bytes.append(0x0A)
        try writeAll(bytes, to: file.value)
        return record
    }

    public func flush() throws {
        lock.lock()
        defer { lock.unlock() }
        guard fsync(file.value) == 0 else {
            throw SecureStateError.systemCall("fsync latest.log", errno)
        }
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                return
            }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw SecureStateError.systemCall("write latest.log", errno)
                }
                guard count > 0 else {
                    throw SecureStateError.systemCall("write latest.log", EPIPE)
                }
                offset += count
            }
        }
    }
}

public enum RunLogCompatibilityDisposition:
    Equatable, Sendable
{
    case empty
    case current
    case legacy
    case incompatible(String)
}

public struct RunLogReadSnapshot: Equatable, Sendable {
    public let records: [LogRecord]
    public let disposition: RunLogCompatibilityDisposition

    public init(
        records: [LogRecord],
        disposition: RunLogCompatibilityDisposition
    ) {
        self.records = records
        self.disposition = disposition
    }
}

public enum RunLogReader {
    public static func records(
        state: SecureStateDirectory,
        maximumBytes: Int = 1_048_576
    ) throws -> [LogRecord] {
        try snapshot(
            state: state,
            maximumBytes: maximumBytes
        ).records
    }

    public static func snapshot(
        state: SecureStateDirectory,
        maximumBytes: Int = 1_048_576
    ) throws -> RunLogReadSnapshot {
        let fd = try state.openRegularFile(
            named: "latest.log",
            flags: O_RDONLY,
            create: false,
            repairPermissions: false
        )
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw SecureStateError.systemCall("fstat latest.log", errno)
        }
        guard info.st_size >= 0, info.st_size <= maximumBytes else {
            throw SecureStateError.unsafePath("latest.log size")
        }
        var data = Data(count: Int(info.st_size))
        let readCount: Int = try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                return 0
            }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.read(fd, base.advanced(by: offset), raw.count - offset)
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw SecureStateError.systemCall("read latest.log", errno)
                }
                if count == 0 {
                    break
                }
                offset += count
            }
            return offset
        }
        data.count = readCount
        var after = stat()
        var named = stat()
        guard fstat(fd, &after) == 0,
            fstatat(
                state.descriptor.value,
                "latest.log",
                &named,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            sameReadSnapshot(info, after),
            sameReadSnapshot(info, named)
        else {
            throw SecureStateError.unsafePath(
                "latest.log changed while reading"
            )
        }
        let truncated = !data.isEmpty && data.last != 0x0A
        if truncated {
            if let lastNewline = data.lastIndex(of: 0x0A) {
                data = data.prefix(through: lastNewline)
            } else {
                return RunLogReadSnapshot(
                    records: [],
                    disposition: .incompatible(
                        "latest.log has a truncated first record"
                    )
                )
            }
        }
        let decoded = decodeCompleteLines(data)
        if truncated {
            return RunLogReadSnapshot(
                records: decoded.records,
                disposition: .incompatible(
                    "latest.log has a truncated trailing record"
                )
            )
        }
        return decoded
    }

    private static func sameReadSnapshot(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_uid == rhs.st_uid
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
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

    public static func latestReport(
        state: SecureStateDirectory,
        matching expectedRunID: String
    ) throws -> RunReport? {
        let read = try snapshot(state: state)
        guard case .incompatible = read.disposition else {
            return completedReport(
                in: read.records,
                matching: expectedRunID
            )
        }
        return nil
    }

    public static func completedReport(
        in records: [LogRecord],
        matching expectedRunID: String
    ) -> RunReport? {
        guard RunIdentity.isValid(expectedRunID) else {
            return nil
        }
        return records.reversed().first(where: {
            $0.type == "run_finished"
                && $0.run == expectedRunID
                && HistoricalLogIdentity.isV1Report($0.report?.schema)
                && $0.report?.run == expectedRunID
                && $0.report?.results.isEmpty == false
        })?.report
    }

    public static func completedLegacyReport(
        in records: [LogRecord]
    ) -> RunReport? {
        records.reversed().compactMap(\.report).first {
            report in
            LegacyRunPresentation.isLegacy(report)
                && RunIdentity.isValid(report.run)
                && !report.results.isEmpty
                && records.contains(where: {
                    $0.type == "run_finished"
                        && $0.run == report.run
                        && $0.report == report
                })
        }
    }

    static func decodeCompleteLines(
        _ data: Data
    ) -> RunLogReadSnapshot {
        guard !data.isEmpty else {
            return RunLogReadSnapshot(
                records: [],
                disposition: .empty
            )
        }
        let decoder = JSONDecoder()
        var records: [LogRecord] = []
        var expectedSequence = 1
        var runID: String?
        var logIdentity: HistoricalLogIdentity?
        var sawLegacy = false
        var sawCurrent = false
        var sawIntent = false
        var terminalReport: RunReport?
        var sawWorkerExit = false
        var sawFinalEvent = false
        let knownTypes = Set([
            "run_intent",
            "event",
            "repository_checkpoint",
            "control",
            "run_finished",
            "worker_exit",
            "subprocess",
        ])
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true)
        {
            guard line.count <= 1_048_576,
                let object = try? JSONSerialization.jsonObject(
                    with: Data(line)
                ) as? [String: Any],
                rawRecordIsSupported(object),
                let record = try? decoder.decode(
                    LogRecord.self,
                    from: Data(line)
                ),
                let recordIdentity = HistoricalLogIdentity.v1(record.schema),
                logIdentity == nil || logIdentity == recordIdentity,
                record.sequence == expectedSequence,
                runID == nil || record.run == runID,
                RunIdentity.isValid(record.run),
                validTimestamp(record.timestamp),
                knownTypes.contains(record.type),
                payloadIsValid(record),
                record.event?.schema == nil
                    || (record.event?.schema == recordIdentity.v1Event
                        && record.event?.run == record.run),
                record.report?.schema == nil
                    || (record.report?.schema == recordIdentity.v1Report
                        && record.report?.run == record.run),
                record.intent?.run == nil || record.intent?.run == record.run,
                record.checkpoint == nil
                    || record.checkpoint?.repository.path.isEmpty == false
            else {
                return RunLogReadSnapshot(
                    records: records,
                    disposition: .incompatible(
                        "latest.log contains a malformed or newer record"
                    )
                )
            }
            logIdentity = recordIdentity
            if let terminalReport {
                if !sawWorkerExit {
                    guard record.type == "worker_exit" else {
                        return RunLogReadSnapshot(
                            records: records,
                            disposition: .incompatible(
                                "latest.log requires worker exit after completion"
                            )
                        )
                    }
                    sawWorkerExit = true
                } else if !sawFinalEvent {
                    guard finalEventMatches(
                        record,
                        report: terminalReport
                    ) else {
                        return RunLogReadSnapshot(
                            records: records,
                            disposition: .incompatible(
                                "latest.log has an invalid final event"
                            )
                        )
                    }
                    sawFinalEvent = true
                } else {
                    return RunLogReadSnapshot(
                        records: records,
                        disposition: .incompatible(
                            "latest.log contains records after completion"
                        )
                    )
                }
            } else if record.type == "worker_exit"
                || record.event?.type == .runFinished
            {
                return RunLogReadSnapshot(
                    records: records,
                    disposition: .incompatible(
                        "latest.log contains an early terminal record"
                    )
                )
            }
            if let intent = record.intent {
                guard !sawIntent,
                    terminalReport == nil,
                    intent.repositoryModel == nil
                        || intent.repositoryModel == "v2"
                else {
                    return RunLogReadSnapshot(
                        records: records,
                        disposition: .incompatible(
                            "latest.log contains an unsupported intent model"
                        )
                    )
                }
                sawIntent = true
                if intent.repositoryModel == nil {
                    sawLegacy = true
                } else {
                    sawCurrent = true
                }
            }
            if let report = record.report {
                guard
                    report.repositoryModel == nil
                        || report.repositoryModel == "v2"
                else {
                    return RunLogReadSnapshot(
                        records: records,
                        disposition: .incompatible(
                            "latest.log contains an unsupported report model"
                        )
                    )
                }
                if LegacyRunPresentation.isLegacy(report) {
                    sawLegacy = true
                } else {
                    sawCurrent = true
                }
                guard !(sawLegacy && sawCurrent) else {
                    return RunLogReadSnapshot(
                        records: records,
                        disposition: .incompatible(
                            "latest.log mixes legacy and current reports"
                        )
                    )
                }
            }
            if record.type == "run_finished" {
                guard terminalReport == nil,
                    let report = record.report
                else {
                    return RunLogReadSnapshot(
                        records: records,
                        disposition: .incompatible(
                            "latest.log contains duplicate completion"
                        )
                    )
                }
                terminalReport = report
            }
            runID = record.run
            expectedSequence += 1
            records.append(record)
        }
        return RunLogReadSnapshot(
            records: records,
            disposition:
                sawLegacy
                ? .legacy
                : .current
        )
    }

    private static func finalEventMatches(
        _ record: LogRecord,
        report: RunReport
    ) -> Bool {
        guard record.type == "event",
            let event = record.event else {
            return false
        }
        return event.type == .runFinished
            && event.run == report.run
            && event.repositoryID == nil
            && event.phase == nil
            && event.result == nil
            && event.message == report.summary
    }

    private static func rawRecordIsSupported(
        _ object: [String: Any]
    ) -> Bool {
        let payloadKeys = Set([
            "event", "report", "intent", "checkpoint", "data",
        ])
        let allowed = payloadKeys.union([
            "schema", "run", "sequence", "timestamp", "type",
        ])
        guard Set(object.keys).isSubset(of: allowed),
            let type = object["type"] as? String
        else {
            return false
        }
        let presentPayloads = payloadKeys.filter {
            object[$0] != nil && !(object[$0] is NSNull)
        }
        let expectedPayload: String
        switch type {
        case "run_intent":
            expectedPayload = "intent"
        case "event":
            expectedPayload = "event"
        case "repository_checkpoint":
            expectedPayload = "checkpoint"
        case "run_finished":
            expectedPayload = "report"
        case "control", "worker_exit", "subprocess":
            expectedPayload = "data"
        default:
            return false
        }
        guard presentPayloads == [expectedPayload] else {
            return false
        }
        if let report = object["report"] as? [String: Any],
            !rawReportIsSupported(report)
        {
            return false
        }
        if let intent = object["intent"] as? [String: Any] {
            guard
                Set(intent.keys).isSubset(of: [
                    "run", "startedAt", "candidates",
                    "repositoryModel",
                ]),
                let candidates =
                    intent["candidates"] as? [[String: Any]],
                candidates.allSatisfy(rawRepositoryIsSupported)
            else {
                return false
            }
            if intent.keys.contains("repositoryModel"),
                intent["repositoryModel"] as? String != "v2"
            {
                return false
            }
        }
        if let event = object["event"] as? [String: Any] {
            guard
                Set(event.keys).isSubset(of: [
                    "schema", "run", "sequence", "timestamp", "type",
                    "repositoryID", "phase", "result", "message",
                ])
            else {
                return false
            }
            if let result = event["result"] as? [String: Any],
                !rawResultIsSupported(result)
            {
                return false
            }
        }
        if let checkpoint = object["checkpoint"]
            as? [String: Any]
        {
            guard
                Set(checkpoint.keys).isSubset(of: [
                    "repository", "startedAt", "beforeCommit",
                    "targetCommit", "fetched",
                ])
            else {
                return false
            }
            if let repository = checkpoint["repository"]
                as? [String: Any],
                !rawRepositoryIsSupported(repository)
            {
                return false
            }
        }
        return true
    }

    private static func rawReportIsSupported(
        _ report: [String: Any]
    ) -> Bool {
        guard
            Set(report.keys).isSubset(of: [
                "schema", "run", "startedAt", "endedAt",
                "durationMilliseconds", "cancelled",
                "cancellationState", "results", "summaryOverride",
                "repositoryModel",
            ]), let results = report["results"] as? [[String: Any]],
            results.allSatisfy(rawResultIsSupported)
        else {
            return false
        }
        if report["repositoryModel"] == nil {
            return results.allSatisfy {
                $0["operationID"] == nil
                    && $0["defaultBranch"] == nil
            }
        }
        return report["repositoryModel"] as? String == "v2"
    }

    private static func rawResultIsSupported(
        _ result: [String: Any]
    ) -> Bool {
        guard
            Set(result.keys).isSubset(of: [
                "repository", "operationID", "defaultBranch",
                "code", "resultClass", "fetched", "mainUpdated",
                "beforeCommit", "targetCommit", "afterCommit",
                "remoteTrackingBeforeCommit",
                "remoteTrackingAfterCommit", "startedAt",
                "endedAt", "durationMilliseconds", "explanation",
                "technicalDetail", "failureReason",
            ]),
            let repository = result["repository"]
                as? [String: Any]
        else {
            return false
        }
        return rawRepositoryIsSupported(repository)
    }

    private static func rawRepositoryIsSupported(
        _ repository: [String: Any]
    ) -> Bool {
        Set(repository.keys).isSubset(of: [
            "id", "displayName", "path", "rawOrigin",
            "originIdentity", "presentationLocation",
            "rootIdentity", "gitDirectoryIdentity",
            "commonDirectoryIdentity", "configIdentity",
            "policyAdmissionSHA256", "hookAdmissionSHA256",
            "linkedWorktreePaths", "linkedWorktrees",
            "cachedMainRelation", "blockedReason",
        ])
    }

    private static func payloadIsValid(
        _ record: LogRecord
    ) -> Bool {
        switch record.type {
        case "run_intent":
            guard let intent = record.intent else { return false }
            return intent.run == record.run
                && RunIdentity.isValid(intent.run)
                && validTimestamp(intent.startedAt)
                && !intent.candidates.isEmpty
                && intent.candidates.allSatisfy(
                    \.hasValidatedOriginIdentity
                )
        case "event":
            guard let event = record.event else { return false }
            return event.run == record.run
                && RunIdentity.isValid(event.run)
                && event.sequence > 0
                && validTimestamp(event.timestamp)
                && (event.result == nil
                    || validResult(event.result!))
        case "repository_checkpoint":
            guard let checkpoint = record.checkpoint else {
                return false
            }
            return validTimestamp(checkpoint.startedAt)
                && checkpoint.repository
                    .hasValidatedOriginIdentity
                && validOptionalOID(checkpoint.beforeCommit)
                && validOptionalOID(checkpoint.targetCommit)
        case "run_finished":
            guard let report = record.report else { return false }
            return validReport(report)
        case "control", "worker_exit", "subprocess":
            return record.data?.isEmpty == false
        default:
            return false
        }
    }

    private static func validReport(
        _ report: RunReport
    ) -> Bool {
        RunIdentity.isValid(report.run)
            && validTimestamp(report.startedAt)
            && validTimestamp(report.endedAt)
            && report.durationMilliseconds >= 0
            && report.cancellationState
                == (report.cancelled
                    ? .cancelled : .notCancelled)
            && report.results.allSatisfy(validResult)
    }

    private static func validResult(
        _ result: RepositoryResult
    ) -> Bool {
        result.repository.hasValidatedOriginIdentity
            && result.resultClass == result.code.resultClass
            && result.durationMilliseconds >= 0
            && validTimestamp(result.startedAt)
            && validTimestamp(result.endedAt)
            && validOptionalOID(result.beforeCommit)
            && validOptionalOID(result.targetCommit)
            && validOptionalOID(result.afterCommit)
            && validOptionalOID(
                result.remoteTrackingBeforeCommit
            )
            && validOptionalOID(
                result.remoteTrackingAfterCommit
            )
            && (result.defaultBranch == nil
                || GitReferenceSyntax.isValidBranchName(
                    result.defaultBranch!
                ))
            && !result.explanation.isEmpty
    }

    private static func validOptionalOID(
        _ value: String?
    ) -> Bool {
        guard let value else { return true }
        return (value.count == 40 || value.count == 64)
            && value.allSatisfy {
                $0.isNumber
                    || ("a"..."f").contains($0.lowercased())
            }
    }

    private static func validTimestamp(
        _ value: String
    ) -> Bool {
        guard value.count <= 64 else { return false }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds,
        ]
        if fractional.date(from: value) != nil {
            return true
        }
        let ordinary = ISO8601DateFormatter()
        ordinary.formatOptions = [.withInternetDateTime]
        return ordinary.date(from: value) != nil
    }
}

public enum DurableRunLogEvidence {
    public static func validate(
        state: SecureStateDirectory
    ) throws {
        let descriptor = try state.openRegularFile(
            named: "latest.log",
            flags: O_RDONLY,
            create: false,
            repairPermissions: false
        )
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
            before.st_size >= 0,
            before.st_size <= 4_194_304
        else {
            throw SecureStateError.unsafePath(
                "latest.log durable evidence"
            )
        }
        var data = Data(count: Int(before.st_size))
        let count = try data.withUnsafeMutableBytes {
            bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
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
                        "read latest.log durable evidence",
                        errno
                    )
                }
            }
            return offset
        }
        data.count = count
        var after = stat()
        var named = stat()
        guard fstat(descriptor, &after) == 0,
            fstatat(
                state.descriptor.value,
                "latest.log",
                &named,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            sameFileSnapshot(before, after),
            sameFileSnapshot(before, named)
        else {
            throw SecureStateError.unsafePath(
                "latest.log changed while validating"
            )
        }
        guard !data.isEmpty else { return }
        if data.last != 0x0A {
            guard let lastNewline = data.lastIndex(of: 0x0A),
                  data.distance(from: data.index(after: lastNewline), to: data.endIndex)
                    <= 1_048_576 else {
                throw SecureStateError.unsafePath(
                    "latest.log partial tail is invalid"
                )
            }
            data = data.prefix(through: lastNewline)
        }
        let lines = data.split(
            separator: 0x0A,
            omittingEmptySubsequences: true
        )
        guard !lines.isEmpty,
            lines.allSatisfy({ $0.count <= 1_048_576 }),
            let first = try? JSONSerialization.jsonObject(
                with: Data(lines[0])
            ) as? [String: Any],
            let schema = first["schema"] as? String
        else {
            throw SecureStateError.unsafePath(
                "latest.log framing is incompatible"
            )
        }
        switch schema {
        case shadowSyncRecordSchema, HistoricalLogIdentity.legacyV1Record:
            let read = RunLogReader.decodeCompleteLines(data)
            guard read.records.count == lines.count else {
                throw SecureStateError.unsafePath(
                    "latest.log v1 evidence is incomplete"
                )
            }
            if case .incompatible = read.disposition {
                throw SecureStateError.unsafePath(
                    "latest.log v1 evidence is incompatible"
                )
            }
        case shadowSyncBody3LogSchema, HistoricalLogIdentity.legacyV2Record:
            let allowed = Set([
                "schema", "run", "sequence", "timestamp",
                "type", "repository", "operation", "target",
                "kind", "phase", "worker", "recommendation",
                "selection", "awa", "retention", "artifact",
                "restore", "exclusions", "executable",
                "arguments", "force", "outcome", "status",
                "residue", "recovery", "detail", "technicalDetail",
                "durationMilliseconds", "plan", "report",
            ])
            guard
                lines.allSatisfy({ line in
                    guard
                        let object =
                            try? JSONSerialization.jsonObject(
                                with: Data(line)
                            ) as? [String: Any]
                    else {
                        return false
                    }
                    return object["schema"] as? String
                        == schema
                        && Set(object.keys).isSubset(of: allowed)
                }),
                Body3RunLogReader.decode(data).count
                    == lines.count
            else {
                throw SecureStateError.unsafePath(
                    "latest.log v2 evidence is incompatible"
                )
            }
        default:
            throw SecureStateError.unsafePath(
                "latest.log schema is unsupported"
            )
        }
    }

    private static func sameFileSnapshot(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_uid == rhs.st_uid
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
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
}

public enum CurrentLogOpenError: Error, CustomStringConvertible {
    case unsafeLog
    case openFailed

    public var description: String {
        switch self {
        case .unsafeLog:
            return "the latest log failed its safety validation"
        case .openFailed:
            return "the default application did not open the latest log"
        }
    }
}

public enum CurrentLogOpener {
    public static let maximumBytes: Int64 = 1_048_576

    public static func open(
        state: SecureStateDirectory,
        opener: (URL) -> Bool
    ) throws {
        try openValidated(
            state: state,
            expectedUID: state.uid,
            maximumBytes: maximumBytes,
            opener: opener
        )
    }

    #if SHADOW_SYNC_TESTING
    public static func testingOpen(
        state: SecureStateDirectory,
        expectedUID: uid_t? = nil,
        maximumBytes: Int64 = CurrentLogOpener.maximumBytes,
        opener: (URL) -> Bool
    ) throws {
        try openValidated(
            state: state,
            expectedUID: expectedUID ?? state.uid,
            maximumBytes: maximumBytes,
            opener: opener
        )
    }
    #endif

    private static func openValidated(
        state: SecureStateDirectory,
        expectedUID: uid_t,
        maximumBytes: Int64,
        opener: (URL) -> Bool
    ) throws {
        guard maximumBytes >= 0 else {
            throw CurrentLogOpenError.unsafeLog
        }
        let descriptor = try state.openRegularFile(
            named: "latest.log",
            flags: O_RDONLY,
            create: false,
            repairPermissions: false
        )
        defer { close(descriptor) }
        let opened = try validatedIdentity(
            descriptor: descriptor,
            state: state,
            expectedUID: expectedUID,
            maximumBytes: maximumBytes
        )

        // NSWorkspace accepts a pathname, not an already-verified descriptor. Keep the
        // descriptor open, compare the basename immediately before the synchronous request,
        // and compare it again afterward. This detects ordinary same-user replacement drift;
        // it does not claim to defeat a malicious same-UID pathname race outside v1's model.
        guard try pathnameMatches(
            opened,
            state: state,
            maximumBytes: maximumBytes
        ) else {
            throw CurrentLogOpenError.unsafeLog
        }
        let url = URL(fileURLWithPath: state.path)
            .appendingPathComponent("latest.log")
        guard opener(url) else {
            throw CurrentLogOpenError.openFailed
        }
        guard try pathnameMatches(
            opened,
            state: state,
            maximumBytes: maximumBytes
        ) else {
            throw CurrentLogOpenError.unsafeLog
        }
    }

    private static func validatedIdentity(
        descriptor: Int32,
        state: SecureStateDirectory,
        expectedUID: uid_t,
        maximumBytes: Int64
    ) throws -> stat {
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else {
            throw SecureStateError.systemCall("fstat latest.log", errno)
        }
        guard FileIdentity(opened).isRegular,
              opened.st_uid == expectedUID,
              opened.st_uid == state.uid,
              opened.st_nlink == 1,
              opened.st_size >= 0,
              opened.st_size <= maximumBytes else {
            throw CurrentLogOpenError.unsafeLog
        }
        return opened
    }

    private static func pathnameMatches(
        _ opened: stat,
        state: SecureStateDirectory,
        maximumBytes: Int64
    ) throws -> Bool {
        var relative = stat()
        guard fstatat(
            state.descriptor.value,
            "latest.log",
            &relative,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT {
                return false
            }
            throw SecureStateError.systemCall("fstatat latest.log", errno)
        }
        return FileIdentity(relative).isRegular
            && relative.st_uid == state.uid
            && relative.st_nlink == 1
            && relative.st_size >= 0
            && relative.st_size <= maximumBytes
            && opened.st_dev == relative.st_dev
            && opened.st_ino == relative.st_ino
    }
}
