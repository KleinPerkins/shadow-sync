// Exact read compatibility for preserved source-built logs. Never a launch,
// installation, operation, or writer identity. Unknown versions remain refused.
enum HistoricalLogIdentity: Equatable {
    case current
    case legacySource

    static let legacyV1Record = "dev-main-sync-log/v1"
    static let legacyV1Event = "dev-main-sync-event/v1"
    static let legacyV1Report = "dev-main-sync-report/v1"
    static let legacyV2Record = "dev-main-sync-log/v2"
    static let legacyV2Plan = "dev-main-sync-batch-plan/v2"
    static let legacyV2Report = "dev-main-sync-batch-report/v2"

    static func v1(_ schema: String) -> Self? {
        switch schema {
        case shadowSyncRecordSchema: .current
        case legacyV1Record: .legacySource
        default: nil
        }
    }

    static func v2(_ schema: String) -> Self? {
        switch schema {
        case shadowSyncBody3LogSchema: .current
        case legacyV2Record: .legacySource
        default: nil
        }
    }

    static func isV1Report(_ schema: String?) -> Bool {
        schema == Self.current.v1Report || schema == Self.legacySource.v1Report
    }

    var v1Event: String {
        self == .current ? shadowSyncEventSchema : Self.legacyV1Event
    }
    var v1Report: String {
        self == .current ? "shadow-sync-report/v1" : Self.legacyV1Report
    }
    var v2Plan: String {
        self == .current ? "shadow-sync-batch-plan/v2" : Self.legacyV2Plan
    }
    var v2Report: String {
        self == .current ? "shadow-sync-batch-report/v2" : Self.legacyV2Report
    }
}
