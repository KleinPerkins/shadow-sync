#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

enum InstallationReadinessAliasFixtures {
    typealias H = InstallationStorageFixtures
    static func drainage() throws {
        try H.fixture { root, location in
            var initializer: FreshStateInitialization? = try .testing(root: root)
            _ = try initializer!.publish(); initializer = nil
            let admission = try LifecycleAdmissionAuthority.acquire(at: location)
            defer { admission.release() }
            var aliases: CustodyAuthorityLeaseSet? = try admission.retainObservationLeases()
            var child: CustodyAuthorityLeaseSet? = try aliases!.duplicate()
            try H.check(admission.retireCommittedHostAdmission() == .inProgress, "live aliases released original admission")
            try H.check(admission.testingReadinessRetirements == [.notAttempted, .notAttempted], "pending alias consumed original lock")
            try H.refuses { _ = try admission.retainObservationLeases() }
            try H.refuses { _ = try aliases!.duplicate() }
            aliases = nil
            try H.check(admission.retireCommittedHostAdmission() == .inProgress, "descendant alias lost custody")
            child = nil
            try H.check(admission.retireCommittedHostAdmission() == .succeeded, "actual aliases did not retire")
            try H.check(admission.retireCommittedHostAdmission() == .succeeded, "original retirement was retried")
            _ = child
        }
    }
    static func uncertainty() throws {
        try H.fixture { root, location in
            var initializer: FreshStateInitialization? = try .testing(root: root)
            _ = try initializer!.publish(); initializer = nil
            let admission = try LifecycleAdmissionAuthority.acquire(at: location)
            defer { admission.release() }
            var aliases: CustodyAuthorityLeaseSet? = try admission.retainObservationLeases()
            var child: CustodyAuthorityLeaseSet? = try aliases!.duplicate()
            var actualCloses = 0
            try child!.testingUncertainObservationClose { actualCloses += 1 }
            aliases = nil; child = nil
            try H.check(actualCloses == 1, "fixture original descriptor was not closed once")
            try H.check(admission.retireCommittedHostAdmission() == .uncertain(EIO), "uncertain alias retirement disappeared")
            try H.check(admission.testingReadinessRetirements == [.notAttempted, .notAttempted], "uncertain alias consumed original admission")
            try H.check(!admission.commandAdmissionIsOpen, "closed observation family admitted new commands")
            try H.refuses { _ = try admission.retainObservationLeases() }
            try H.check(admission.retireCommittedHostAdmission() == .uncertain(EIO) && actualCloses == 1, "uncertain descriptor number was retried")
        }
    }
    static func partialLauncher() throws {
        try H.fixture { root, location in
            var initializer: FreshStateInitialization? = try .testing(root: root)
            _ = try initializer!.publish(); initializer = nil
            let admission = try LifecycleAdmissionAuthority.acquire(at: location)
            let incumbent = try LauncherAuthority.acquireWithinLifecycle(at: location)
            var partial: LauncherAuthority?
            defer { partial?.release(); incumbent.release(); admission.release() }
            try H.refuses {
                _ = try LauncherAuthority.acquireForReadiness(admission: admission) { partial = $0 }
            }
            guard let original = partial else { throw CustodyRecordError.fenced }
            try H.check(original.retireCommittedHostLauncher() == .succeeded, "partial launcher acquisition lost its actual owner")
            try H.check(original.retireCommittedHostLauncher() == .succeeded, "partial launcher close retried its number")
            try H.refuses { _ = try LauncherAuthority.acquireWithinLifecycle(at: location) }
            try H.check(admission.testingReadinessRetirements == [.notAttempted, .notAttempted], "failed launcher released admission")
        }
    }
}
#endif
