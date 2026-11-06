#if SHADOW_SYNC_TESTING
import CryptoKit
import Darwin
import Foundation

public enum HistoricalLogSelfTestRunner {
    public static func runAll(observer: (String) -> Void = { _ in }) throws {
        try RuntimeFixtureSession.withCase("identity-history-v1-readable") {
            let fixtures = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Tests/ShadowSyncSelfTests/Fixtures")
            let v1 = try Data(contentsOf: fixtures.appendingPathComponent("legacy-v1-latest.log"))
            let v2 = try Data(contentsOf: fixtures.appendingPathComponent("pre-v06-v2-latest.log"))
            try require(hash(v1) == "51fc82e088fcd2d9342bdf847503a3411718a74731ddb03f489750b1054a58f7"
                && hash(v2) == "127c4530f3d071f66b283363eaf81f9fdef9c51a8dff6389128d9b04e0815f0a",
                "pinned historical bytes changed")
            let first = RunLogReader.decodeCompleteLines(v1)
            try require(first.records.count == 5 && first.disposition == .legacy,
                        "historical v1 log is no longer readable")
            try require(RunLogReader.completedLegacyReport(in: first.records) != nil,
                        "historical completed report is unavailable")
        }
        observer("identity-history-v1-readable")
        try RuntimeFixtureSession.withCase("identity-history-v2-readable") {
            let fixtures = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Tests/ShadowSyncSelfTests/Fixtures")
            let v1 = try Data(contentsOf: fixtures.appendingPathComponent("legacy-v1-latest.log"))
            let v2 = try Data(contentsOf: fixtures.appendingPathComponent("pre-v06-v2-latest.log"))
            try require(hash(v1) == "51fc82e088fcd2d9342bdf847503a3411718a74731ddb03f489750b1054a58f7"
                && hash(v2) == "127c4530f3d071f66b283363eaf81f9fdef9c51a8dff6389128d9b04e0815f0a",
                "pinned historical bytes changed")
            let second = Body3RunLogReader.decode(v2)
            try require(second.count == 4 && second.last?.report != nil,
                        "historical v2 log is no longer readable")
        }
        observer("identity-history-v2-readable")
        try RuntimeFixtureSession.withCase("identity-history-current-readable") {
            let fixtures = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Tests/ShadowSyncSelfTests/Fixtures")
            let v1 = try Data(contentsOf: fixtures.appendingPathComponent("legacy-v1-latest.log"))
            let v2 = try Data(contentsOf: fixtures.appendingPathComponent("pre-v06-v2-latest.log"))
            try require(hash(v1) == "51fc82e088fcd2d9342bdf847503a3411718a74731ddb03f489750b1054a58f7"
                && hash(v2) == "127c4530f3d071f66b283363eaf81f9fdef9c51a8dff6389128d9b04e0815f0a",
                "pinned historical bytes changed")
            let v1Objects = try objects(v1)
            let v2Objects = try objects(v2)
            let currentV1 = try encoded(v1Objects.map { convertToCurrent($0) as! [String: Any] })
            let currentV2 = try encoded(v2Objects.map { convertToCurrent($0) as! [String: Any] })
            try require(RunLogReader.decodeCompleteLines(currentV1).records.count == 5
                && Body3RunLogReader.decode(currentV2).count == 4,
                "current identity logs stopped decoding")
        }
        observer("identity-history-current-readable")
        try RuntimeFixtureSession.withCase("identity-history-v1-mixed-and-future-refusal") {
            let fixtures = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Tests/ShadowSyncSelfTests/Fixtures")
            let v1 = try Data(contentsOf: fixtures.appendingPathComponent("legacy-v1-latest.log"))
            let v2 = try Data(contentsOf: fixtures.appendingPathComponent("pre-v06-v2-latest.log"))
            try require(hash(v1) == "51fc82e088fcd2d9342bdf847503a3411718a74731ddb03f489750b1054a58f7"
                && hash(v2) == "127c4530f3d071f66b283363eaf81f9fdef9c51a8dff6389128d9b04e0815f0a",
                "pinned historical bytes changed")
            let v1Objects = try objects(v1)
            var mixedV1 = v1Objects
            var event = mixedV1[1]["event"] as! [String: Any]
            event["schema"] = shadowSyncEventSchema
            mixedV1[1]["event"] = event
            try require(isIncompatible(try encoded(mixedV1)), "mixed v1 event identity was accepted")
            mixedV1 = v1Objects
            mixedV1[2]["schema"] = shadowSyncRecordSchema
            try require(isIncompatible(try encoded(mixedV1)), "mixed v1 frame identity was accepted")
            mixedV1 = v1Objects
            mixedV1[0]["schema"] = "shadow-sync-log/v99"
            try require(isIncompatible(try encoded(mixedV1)), "future v1 frame identity was accepted")
        }
        observer("identity-history-v1-mixed-and-future-refusal")
        try RuntimeFixtureSession.withCase("identity-history-v2-mixed-and-future-refusal") {
            let fixtures = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Tests/ShadowSyncSelfTests/Fixtures")
            let v1 = try Data(contentsOf: fixtures.appendingPathComponent("legacy-v1-latest.log"))
            let v2 = try Data(contentsOf: fixtures.appendingPathComponent("pre-v06-v2-latest.log"))
            try require(hash(v1) == "51fc82e088fcd2d9342bdf847503a3411718a74731ddb03f489750b1054a58f7"
                && hash(v2) == "127c4530f3d071f66b283363eaf81f9fdef9c51a8dff6389128d9b04e0815f0a",
                "pinned historical bytes changed")
            let v2Objects = try objects(v2)
            var mixedV2 = v2Objects
            var plan = mixedV2[0]["plan"] as! [String: Any]
            plan["schema"] = "shadow-sync-batch-plan/v2"
            mixedV2[0]["plan"] = plan
            try require(Body3RunLogReader.decode(try encoded(mixedV2)).isEmpty,
                        "mixed v2 plan identity was accepted")
            mixedV2 = v2Objects
            mixedV2[2]["schema"] = shadowSyncBody3LogSchema
            try require(Body3RunLogReader.decode(try encoded(mixedV2)).isEmpty,
                        "mixed v2 frame identity was accepted")
            mixedV2 = v2Objects
            mixedV2[0]["schema"] = "shadow-sync-log/v99"
            try require(Body3RunLogReader.decode(try encoded(mixedV2)).isEmpty,
                        "future v2 frame identity was accepted")
        }
        observer("identity-history-v2-mixed-and-future-refusal")
        try RuntimeFixtureSession.withCase("identity-history-no-implicit-replay") {
            let fixtures = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Tests/ShadowSyncSelfTests/Fixtures")
            let v1 = try Data(contentsOf: fixtures.appendingPathComponent("legacy-v1-latest.log"))
            let v2 = try Data(contentsOf: fixtures.appendingPathComponent("pre-v06-v2-latest.log"))
            try require(hash(v1) == "51fc82e088fcd2d9342bdf847503a3411718a74731ddb03f489750b1054a58f7"
                && hash(v2) == "127c4530f3d071f66b283363eaf81f9fdef9c51a8dff6389128d9b04e0815f0a",
                "pinned historical bytes changed")
            let second = Body3RunLogReader.decode(v2)
            var postflightCalled = false
            let recovered = Body3InterruptedRunReconstructor.reconstruct(records: second) { _ in
                postflightCalled = true
                return Body3RecoveredNodeDisposition(status: .succeeded, detail: "unreachable")
            }
            try require(recovered == nil && !postflightCalled
                && second.first?.plan?.isStructurallyValid == false,
                "historical presentation acquired current operation authority")
        }
        observer("identity-history-no-implicit-replay")
        try RuntimeFixtureSession.withCase("identity-history-preserved-durable-bytes") {
            let fixtures = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Tests/ShadowSyncSelfTests/Fixtures")
            let v1 = try Data(contentsOf: fixtures.appendingPathComponent("legacy-v1-latest.log"))
            let v2 = try Data(contentsOf: fixtures.appendingPathComponent("pre-v06-v2-latest.log"))
            try require(hash(v1) == "51fc82e088fcd2d9342bdf847503a3411718a74731ddb03f489750b1054a58f7"
                && hash(v2) == "127c4530f3d071f66b283363eaf81f9fdef9c51a8dff6389128d9b04e0815f0a",
                "pinned historical bytes changed")
            let temporary = try M1TemporaryDirectory()
            defer { temporary.remove() }
            let location = try StateLocation.isolated(root: temporary.path)
            try TestIsolation.initializeState(at: location)
            let authority = try RunAuthority.acquireRun(at: location)
            defer { authority.release() }
            let log = URL(fileURLWithPath: authority.stateDirectory.path).appendingPathComponent("latest.log")
            for source in [v1, v2] {
                try source.write(to: log)
                guard chmod(log.path, 0o600) == 0 else { throw Failure(detail: "fixture mode failed") }
                try DurableRunLogEvidence.validate(state: authority.stateDirectory)
                try require(try Data(contentsOf: log) == source, "read validation rewrote historical bytes")
            }
            authority.release()
            temporary.remove()
            var absent = stat()
            try require(lstat(temporary.path, &absent) == -1 && errno == ENOENT,
                        "historical state fixture cleanup incomplete")
        }
        observer("identity-history-preserved-durable-bytes")
        try RuntimeFixtureSession.withCase("identity-history-v1-current-writes-only") {
            let fixtures = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Tests/ShadowSyncSelfTests/Fixtures")
            let v1 = try Data(contentsOf: fixtures.appendingPathComponent("legacy-v1-latest.log"))
            let v2 = try Data(contentsOf: fixtures.appendingPathComponent("pre-v06-v2-latest.log"))
            try require(hash(v1) == "51fc82e088fcd2d9342bdf847503a3411718a74731ddb03f489750b1054a58f7"
                && hash(v2) == "127c4530f3d071f66b283363eaf81f9fdef9c51a8dff6389128d9b04e0815f0a",
                "pinned historical bytes changed")
            let first = RunLogReader.decodeCompleteLines(v1)
            let temporary = try M1TemporaryDirectory()
            defer { temporary.remove() }
            let location = try StateLocation.isolated(root: temporary.path)
            try TestIsolation.initializeState(at: location)
            let authority = try RunAuthority.acquireRun(at: location)
            defer { authority.release() }
            let log = URL(fileURLWithPath: authority.stateDirectory.path).appendingPathComponent("latest.log")
            try v2.write(to: log)
            try require(chmod(log.path, 0o600) == 0, "preceding historical log mode")
            let report = first.records.compactMap(\.report).first!
            let legacyEvent = first.records.compactMap(\.event).first!
            let writer = try RunLogWriter(authority: authority, runID: report.run)
            try require(refuses { _ = try writer.append(type: "run_finished", report: report) }
                && refuses { _ = try writer.append(type: "event", event: legacyEvent) },
                "v1 writer accepted a historical nested payload")
            try require(try Data(contentsOf: log).isEmpty, "v1 refusal wrote bytes")
            let currentEvent = RunEvent(run: report.run, sequence: 1, type: .diagnostic, message: "fixture")
            let written = try writer.append(type: "event", event: currentEvent)
            try writer.flush()
            try require(written.schema == shadowSyncRecordSchema && written.event?.schema == shadowSyncEventSchema,
                        "new v1 write used historical identity")
            authority.release()
            temporary.remove()
            var absent = stat()
            try require(lstat(temporary.path, &absent) == -1 && errno == ENOENT,
                        "historical state fixture cleanup incomplete")
        }
        observer("identity-history-v1-current-writes-only")
        try RuntimeFixtureSession.withCase("identity-history-v2-current-writes-only") {
            let fixtures = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Tests/ShadowSyncSelfTests/Fixtures")
            let v1 = try Data(contentsOf: fixtures.appendingPathComponent("legacy-v1-latest.log"))
            let v2 = try Data(contentsOf: fixtures.appendingPathComponent("pre-v06-v2-latest.log"))
            try require(hash(v1) == "51fc82e088fcd2d9342bdf847503a3411718a74731ddb03f489750b1054a58f7"
                && hash(v2) == "127c4530f3d071f66b283363eaf81f9fdef9c51a8dff6389128d9b04e0815f0a",
                "pinned historical bytes changed")
            let second = Body3RunLogReader.decode(v2)
            let temporary = try M1TemporaryDirectory()
            defer { temporary.remove() }
            let location = try StateLocation.isolated(root: temporary.path)
            try TestIsolation.initializeState(at: location)
            let authority = try RunAuthority.acquireRun(at: location)
            defer { authority.release() }
            let log = URL(fileURLWithPath: authority.stateDirectory.path).appendingPathComponent("latest.log")
            let first = RunLogReader.decodeCompleteLines(v1)
            let priorReport = first.records.compactMap(\.report).first!
            do {
                let priorWriter = try RunLogWriter(authority: authority, runID: priorReport.run)
                _ = try priorWriter.append(type: "event", event: RunEvent(run: priorReport.run,
                    sequence: 1, type: .diagnostic, message: "fixture"))
                try priorWriter.flush()
            }
            let oldPlan = second.first!.plan!
            let oldReport = second.last!.report!
            let preserved = try Data(contentsOf: log)
            try require(refuses { _ = try Body3RunLogWriter(authority: authority, plan: oldPlan) },
                        "batch writer accepted historical plan authority")
            try require(try Data(contentsOf: log) == preserved, "batch refusal truncated prior evidence")
            let currentPlan = try Body3BatchPlan(run: oldPlan.run, createdAt: oldPlan.createdAt,
                policyEvidenceDigest: oldPlan.policyEvidenceDigest, nodes: oldPlan.nodes)
            let batchWriter = try Body3RunLogWriter(authority: authority, plan: currentPlan)
            let initial = try Data(contentsOf: log)
            try require(refuses { _ = try batchWriter.append(type: "plan", plan: oldPlan) }
                && refuses { _ = try batchWriter.append(type: "run_finished", report: oldReport) },
                "batch writer accepted historical nested payload")
            try require(try Data(contentsOf: log) == initial, "batch payload refusal wrote bytes")
            let currentReport = try Body3BatchReport(run: oldReport.run, startedAt: oldReport.startedAt,
                endedAt: oldReport.endedAt, cancelled: oldReport.cancelled, paused: oldReport.paused,
                results: oldReport.results)
            let batchWritten = try batchWriter.append(type: "run_finished", report: currentReport)
            try batchWriter.flush()
            try require(batchWritten.schema == shadowSyncBody3LogSchema
                && batchWritten.report?.schema == "shadow-sync-batch-report/v2",
                "new batch write used historical identity")
            authority.release()
            temporary.remove()
            var absent = stat()
            try require(lstat(temporary.path, &absent) == -1 && errno == ENOENT,
                        "historical state fixture cleanup incomplete")
        }
        observer("identity-history-v2-current-writes-only")
        try RuntimeFixtureSession.withCase("identity-history-fixtures-unchanged") {
            let fixtures = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Tests/ShadowSyncSelfTests/Fixtures")
            let v1 = try Data(contentsOf: fixtures.appendingPathComponent("legacy-v1-latest.log"))
            let v2 = try Data(contentsOf: fixtures.appendingPathComponent("pre-v06-v2-latest.log"))
            try require(hash(v1) == "51fc82e088fcd2d9342bdf847503a3411718a74731ddb03f489750b1054a58f7"
                && hash(v2) == "127c4530f3d071f66b283363eaf81f9fdef9c51a8dff6389128d9b04e0815f0a",
                "pinned historical bytes changed")
            try require(try Data(contentsOf: fixtures.appendingPathComponent("legacy-v1-latest.log")) == v1
                && Data(contentsOf: fixtures.appendingPathComponent("pre-v06-v2-latest.log")) == v2,
                "immutable source fixture bytes changed")
        }
        observer("identity-history-fixtures-unchanged")
    }

    private static func objects(_ bytes: Data) throws -> [[String: Any]] {
        try bytes.split(separator: 0x0A).map {
            try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
        }
    }

    private static func encoded(_ objects: [[String: Any]]) throws -> Data {
        var result = Data()
        for object in objects {
            result.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            result.append(0x0A)
        }
        return result
    }

    private static func convertToCurrent(_ value: Any) -> Any {
        if var object = value as? [String: Any] {
            let map = [HistoricalLogIdentity.legacyV1Record: shadowSyncRecordSchema,
                       HistoricalLogIdentity.legacyV1Event: shadowSyncEventSchema,
                       HistoricalLogIdentity.legacyV1Report: "shadow-sync-report/v1",
                       HistoricalLogIdentity.legacyV2Record: shadowSyncBody3LogSchema,
                       HistoricalLogIdentity.legacyV2Plan: "shadow-sync-batch-plan/v2",
                       HistoricalLogIdentity.legacyV2Report: "shadow-sync-batch-report/v2"]
            if let schema = object["schema"] as? String, let current = map[schema] {
                object["schema"] = current
            }
            return object.mapValues(convertToCurrent)
        }
        if let array = value as? [Any] { return array.map(convertToCurrent) }
        return value
    }

    private static func isIncompatible(_ bytes: Data) -> Bool {
        if case .incompatible = RunLogReader.decodeCompleteLines(bytes).disposition { return true }
        return false
    }

    private static func refuses(_ operation: () throws -> Void) -> Bool {
        do { try operation(); return false } catch { return true }
    }

    private static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func require(_ condition: Bool, _ detail: String) throws {
        if !condition { throw Failure(detail: detail) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let detail: String
        var description: String { detail }
    }
}
#endif
