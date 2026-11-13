#if SHADOW_SYNC_TESTING
import Darwin

public enum ReconciliationDiagnosticSelfTestRunner {
    private typealias D = InstallationReconciliationDiagnostic
    private typealias H = InstallationStorageFixtures

    // This invokes the actual observer and its actual emission cap. It creates
    // no installation, journal, helper, process or synthetic ownership proof.
    public static func runAll(record: (String) -> Void) throws {
        try RuntimeFixtureSession.withCase("reconciliation-observer-capped-exclusion-unwind") {
            try cappedExclusionUnwind()
            try fourReservations()
            try setupAndDisabled()
        }
        record("reconciliation-observer-capped-exclusion-unwind")
    }

    private static func step(_ action: () -> Void) throws {
        let previous = errno
        defer { errno = previous }
        errno = EDOM
        action()
        try H.check(errno == EDOM, "reconciliation observer changed errno")
    }

    private static func fillProgress(_ probe: D) throws {
        for _ in 0..<160 { try step { probe.mark(.resolvedAssertion) } }
        try H.check(probe.testingRecords.count == 124
            && probe.testingRecords.allSatisfy { $0.edge == .entered },
            "reconciliation observer progress cap")
    }

    private static func successfulPart(_ probe: D, _ part: D.Part) throws {
        try step { probe.begin(part) }
        try step { probe.observe(.bodyEntered, .none) }
        try step { probe.observe(.bodyReturned, .none) }
        try step { probe.observe(.readinessCloseEntry, .none) }
        try step { probe.observe(.readinessCloseReturned, .none) }
        try step { probe.observe(.exclusion, .none) }
        try step { probe.observe(.preparationCleanupEntry, .none) }
        try step { probe.observe(.preparationCleanupReturned, .none) }
        try step { probe.observe(.rootCleanupEntry, .none) }
        try step { probe.observe(.rootCleanupReturned, .none) }
        try step { probe.observe(.fixtureReturned, .none) }
    }

    private static func cappedExclusionUnwind() throws {
        for preparationReplacement in [false, true] {
            for rootReplacement in [false, true] {
                let probe = D(testingEnabled: true)
                try successfulPart(probe, .unpublishedKickstart)
                try successfulPart(probe, .beforeSpawn)
                try step { probe.begin(.afterAnchor) }
                try step { probe.observe(.bodyEntered, .none) }
                try step { probe.observe(.bodyReturned, .none) }
                try step { probe.observe(.readinessCloseEntry, .none) }
                try step { probe.observe(.readinessCloseReturned, .none) }
                try fillProgress(probe)
                try step { probe.observe(.exclusion, .none) }
                try step { probe.observe(.preparationCaught, .init(H.Failure(message: "fixture exclusion assertion"))) }
                let initiating = probe.testingRecords.last!
                try H.check(probe.testingRecords.count == 125
                    && initiating.part == .afterAnchor && initiating.stage == .resolvedAssertion
                    && initiating.bootstrap == nil && initiating.boundary == .exclusion
                    && initiating.origin == .cleanup && initiating.edge == .firstExclusionFailure
                    && initiating.failure == .assertion,
                    "reconciliation observer lost initiating exclusion before cleanup")
                try H.check(initiating.line == "M6 STAGED RECONCILIATION DIAGNOSTIC part=afterAnchor stage=resolvedAssertion bootstrap=none boundary=exclusion origin=cleanup edge=firstExclusionFailure error=assertion\n",
                    "reconciliation observer changed closed emitted record")
                try step { probe.observe(.preparationCleanupEntry, .none) }
                if preparationReplacement {
                    try step { probe.observe(.preparationCleanupFailed, .busy) }
                    try step { probe.observe(.rootCaught, .busy) }
                } else {
                    try step { probe.observe(.preparationCleanupReturned, .none) }
                    try step { probe.observe(.preparationRethrow, .assertion) }
                    try step { probe.observe(.rootCaught, .assertion) }
                }
                try step { probe.observe(.rootCleanupEntry, .none) }
                if rootReplacement {
                    try step { probe.observe(.rootCleanupFailed, .conflict) }
                    try step { probe.outerFailure(CustodyRecordError.conflict) }
                } else {
                    try step { probe.observe(.rootCleanupReturned, .none) }
                    try step { probe.observe(.rootRethrow, preparationReplacement ? .busy : .assertion) }
                    if preparationReplacement {
                        try step { probe.outerFailure(CustodyRecordError.busy) }
                    } else {
                        try step { probe.outerFailure(H.Failure(message: "fixture exclusion assertion")) }
                    }
                }
                let terminal = probe.testingRecords.filter { $0.edge != .entered }
                let expectedEdges: [D.Edge] = preparationReplacement
                    ? [.firstExclusionFailure, .preparationFailure, .outerFailure]
                    : [.firstExclusionFailure, .outerFailure]
                try H.check(terminal.map { $0.edge } == expectedEdges && terminal[0] == initiating
                    && probe.testingRecords.count == 124 + expectedEdges.count,
                    "reconciliation observer replaced or duplicated initiating exclusion")
                if preparationReplacement {
                    try H.check(terminal[1].boundary == .preparationCleanupFailed
                        && terminal[1].failure == .busy, "reconciliation observer lost preparation replacement")
                }
                let outer = terminal.last!
                try H.check(outer.boundary == (rootReplacement ? .rootCleanupFailed : .rootRethrow)
                    && outer.origin == .cleanup
                    && outer.failure == (rootReplacement ? .conflict : (preparationReplacement ? .busy : .assertion)),
                    "reconciliation observer lost final replacement or rethrow")
            }
        }
    }

    private static func fourReservations() throws {
        let probe = D(testingEnabled: true)
        try step { probe.begin(.afterOwner) }
        try step { probe.observe(.bodyEntered, .none) }
        try fillProgress(probe)
        try step { probe.observe(.bodyFailed, .fenced) }
        try step { probe.observe(.readinessCloseEntry, .none) }
        try step { probe.observe(.readinessCloseFailed, .busy) }
        try step { probe.observe(.preparationCaught, .busy) }
        try step { probe.observe(.preparationCleanupEntry, .none) }
        try step { probe.observe(.preparationCleanupFailed, .invalidResource) }
        try step { probe.observe(.rootCaught, .invalidResource) }
        try step { probe.observe(.rootCleanupEntry, .none) }
        try step { probe.observe(.rootCleanupFailed, .conflict) }
        try step { probe.outerFailure(CustodyRecordError.conflict) }
        let terminal = Array(probe.testingRecords.suffix(4))
        try H.check(probe.testingRecords.count == 128
            && terminal.map { $0.edge } == [.firstBodyFailure, .readinessFailure, .preparationFailure, .outerFailure]
            && terminal.map { $0.failure } == [.fenced, .busy, .invalidResource, .conflict]
            && terminal.last?.boundary == .rootCleanupFailed,
            "reconciliation observer changed four reserved records")
        let full = probe.testingRecords
        try step { probe.mark(.reconcile) }
        try step { probe.outerFailure(CustodyRecordError.fenced) }
        try step { probe.returned() }
        try H.check(probe.testingRecords == full, "reconciliation observer exceeded total cap")
    }

    private static func setupAndDisabled() throws {
        let previous = errno
        defer { errno = previous }
        errno = EDOM
        let probe = D(testingEnabled: true)
        try H.check(errno == EDOM, "reconciliation observer capture initialization changed errno")
        try step { probe.begin(.unpublishedKickstart) }
        try step { probe.observe(.transfer, .none) }
        try step { probe.observe(.preparationCaught, .fenced) }
        try step { probe.observe(.rootCaught, .fenced) }
        try step { probe.outerFailure(CustodyRecordError.fenced) }
        let first = probe.testingRecords.filter { $0.edge == .firstSetupFailure }
        try H.check(first.count == 1 && first[0].boundary == .transfer
            && first[0].failure == .fenced, "reconciliation observer changed setup reservation")
        let disabled = D(testingEnabled: false)
        try successfulPart(disabled, .afterAnchor)
        try step { disabled.observe(.exclusion, .none) }
        try step { disabled.observe(.preparationCaught, .assertion) }
        try step { disabled.outerFailure(CustodyRecordError.fenced) }
        try H.check(disabled.testingRecords.isEmpty, "reconciliation observer emitted while disabled")
    }
}
#endif
