#if SHADOW_SYNC_TESTING && SHADOW_SYNC_SIGNED_FIXTURE
import Foundation

/// Closed installation-positive route. Source preflight is a different suite
/// and cannot satisfy this case. Native execution remains a separate gate.
enum SignedInstallationFixtureEntrypoint {
    static func dispatch(_ arguments: [String]) -> Int32? {
        guard arguments.dropFirst().contains("--verify-signed-installation-fixture") else { return nil }
        guard arguments.count == 2, arguments[1] == "--verify-signed-installation-fixture" else { return 64 }
        do {
            try SignedInstallationFixtureSourceEntrypoint.requireInheritedManifest()
            let request = try SignedInstallationFixtureContext.Request.consume()
            guard let scenario = SignedInstallationFixtureCase(rawValue: request.caseID) else { throw CustodyRecordError.fenced }
            if scenario.isStartAdapterJoinControl {
                try SignedInstallationFixtureJoinControlFixtures.requireControlReportTransport()
            }
            let guardian = try RuntimeSuiteGuardian(suite: SignedInstallationFixtureContext.installationSuite,
                cases: [request.caseID], nonce: request.nonce, deadline: request.deadline,
                source: request.source, executable: request.executable, app: request.app, probeTarget: nil)
            try RuntimeFixtureSession.installGuardian(guardian)
            defer { RuntimeFixtureSession.removeGuardian(guardian) }
            return guardian.execute {
                try RuntimeFixtureSession.withCase(request.caseID) {
                    let context = try SignedInstallationFixtureContext.capture(request: request, guardian: guardian)
                    let custody = try context.retainRootCustody()
                    let service = try SignedInstallationFixtureService(context: context, custody: custody)
                    let bootstrap = try InstallationBootstrap.signedFixture(context, service: service, custody: custody)
                    if scenario.rawValue.hasPrefix("signed-installation/fresh-driver/") {
                        try SignedFreshInstallationDriverFixture.run(scenario, bootstrap: bootstrap, context: context, custody: custody)
                        return
                    }
                    if scenario.isStartAdapterJoinControl {
                        try SignedInstallationFixtureJoinControlFixtures.runSubject(scenario, bootstrap: bootstrap,
                            context: context, service: service, custody: custody)
                    }
                    if scenario.isStartAdapterJoin {
                        try SignedInstallationFixtureJoinFixtures.run(scenario, bootstrap: bootstrap,
                            context: context, service: service, custody: custody)
                        return
                    }
                    try bootstrap.reserve(deadline: context.deadline)
                    try bootstrap.prepareExclusive()
                    try bootstrap.transferToStagedAdmission()
                    try bootstrap.continueStagedJournal()
                    try bootstrap.openStagedReadiness()
                    try bootstrap.bootstrapCandidate()
                    try bootstrap.kickstartCandidate()
                    try bootstrap.confirmCandidateReady()
                    try bootstrap.commitCandidateReadiness()
                    guard let journal = bootstrap.testingTerminalJournal() else { throw CustodyRecordError.fenced }
                    try scenario.run(bootstrap: bootstrap, journal: journal, context: context, service: service)
                    // This branch intentionally retains original operation EX.
                    // The external root creator must observe coordinator reap
                    // before disposal; no finish or installed acceptance claim.
                }
                return true
            }
        } catch { return 78 }
    }
}
#endif
