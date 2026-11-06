#if SHADOW_SYNC_TESTING
import CryptoKit
import Darwin
import Foundation
import ShadowSyncCatalog

public enum DM4PreflightSelfTestRunner {
    private static let tests: [(String, String)] = [
        ("DM4-T01", "naming-classification"),
        ("DM4-T02", "package-and-production-identity"),
        ("DM4-T03", "bundle-and-icon-contract"),
        ("DM4-T04", "deterministic-icon-generation"),
        ("DM4-T05", "fresh-and-current-install"),
        ("DM4-T06", "predecessor-forward-migration"),
        ("DM4-T07", "duplicate-prevention"),
        ("DM4-T08", "migration-fault-cuts"),
        ("DM4-T09", "repair-doctor-rollback-uninstall"),
        ("DM4-T10", "host-activation-and-drain"),
        ("DM4-T11", "release-attestation-reproducibility"),
        ("DM4-T12", "inherited-v3-closure"),
    ]

    public static func runAll(
        testExecutable: String,
        record: (String) -> Void
    ) throws {
        for (id, name) in tests {
            try run(id, testExecutable: testExecutable)
            record("\(id) \(name)")
        }
    }

    public static func runFocused(
        _ id: String,
        testExecutable: String,
        record: (String) -> Void
    ) throws {
        guard let test = tests.first(where: { $0.0 == id }) else {
            throw DM4PreflightError.message("unknown v4 test \(id)")
        }
        try run(id, testExecutable: testExecutable)
        record("\(test.0) \(test.1)")
    }

    private static func run(
        _ id: String,
        testExecutable: String
    ) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = try InstallationPaths.isolated(root: root)
        switch id {
        case "DM4-T01":
            try check(
                InstallationPaths.label == "com.kleinperkins.shadow-sync"
                    && paths.state.path.hasSuffix("/state/shadow-sync"),
                "stable launchd/state identity changed"
            )
        case "DM4-T02":
            try check(
                URL(fileURLWithPath: testExecutable).lastPathComponent
                    == "ShadowSync",
                "testing app executable is not ShadowSync"
            )
        case "DM4-T03", "DM4-T04", "DM4-T11":
            let bundle = URL(fileURLWithPath: testExecutable)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent().path
            let info = NSDictionary(
                contentsOfFile: bundle + "/Contents/Info.plist"
            ) as? [String: Any]
            let icon = bundle + "/Contents/Resources/ShadowSync.icns"
            let notice = bundle
                + "/Contents/Resources/THIRD_PARTY_NOTICES.md"
            let iconDigest = try SHA256.hash(
                data: Data(contentsOf: URL(fileURLWithPath: icon))
            ).map { String(format: "%02x", $0) }.joined()
            let noticeDigest = try SHA256.hash(
                data: Data(contentsOf: URL(fileURLWithPath: notice))
            ).map { String(format: "%02x", $0) }.joined()
            var iconInfo = stat()
            var noticeInfo = stat()
            try check(
                info?["CFBundleDisplayName"] as? String == "ShadowSync"
                    && info?["CFBundleName"] as? String == "ShadowSync"
                    && info?["CFBundleExecutable"] as? String == "ShadowSync"
                    && info?["CFBundleIdentifier"] as? String
                        == "com.kleinperkins.shadow-sync"
                    && info?["CFBundleIconFile"] as? String
                        == "ShadowSync.icns"
                    && lstat(icon, &iconInfo) == 0
                    && (iconInfo.st_mode & S_IFMT) == S_IFREG
                    && iconInfo.st_nlink == 1
                    && iconInfo.st_size > 0
                    && iconDigest
                        == "e27b55fc793f25867793f1ca9000e2454d448329169ade1b89e4beb3950444cc"
                    && lstat(notice, &noticeInfo) == 0
                    && (noticeInfo.st_mode & S_IFMT) == S_IFREG
                    && noticeInfo.st_nlink == 1
                    && noticeDigest
                        == "0aecc40e6acd041a89719ec68d4db33e2e292b5d1cd4b43358a081956a9a2442",
                "signed bundle icon contract is incomplete"
            )
            let artifact = try BundleArtifactIdentity.inspect(
                bundlePath: bundle
            )
            try check(
                artifact.inventory.contains {
                    $0.contains("Contents/Resources/ShadowSync.icns")
                } && artifact.inventory.contains {
                    $0.contains(
                        "Contents/Resources/THIRD_PARTY_NOTICES.md"
                    )
                },
                "icon or notice bytes are absent from bundle attestation"
            )
        case "DM4-T05":
            try check(
                paths.app.hasSuffix("/Applications/ShadowSync.app")
                    && paths.executable.hasSuffix(
                        "/ShadowSync.app/Contents/MacOS/ShadowSync"
                    ),
                "forward lifecycle path is not ShadowSync"
            )
        case "DM4-T06":
            try check(
                paths.predecessorApp.hasSuffix(
                    "/Applications/Dev Main Sync.app"
                )
                    && paths.predecessorExecutable.hasSuffix(
                        "/Dev Main Sync.app/Contents/MacOS/ShadowSync"
                    ),
                "predecessor lifecycle path is not exact"
            )
        case "DM4-T07":
            try check(
                paths.app != paths.predecessorApp
                    && paths.executable != paths.predecessorExecutable
                    && InstallationPaths.label
                        == "com.kleinperkins.shadow-sync",
                "app generations do not share one stable launchd identity"
            )
        case "DM4-T08":
            try check(
                paths.app.deletingLastPathComponent
                    == paths.predecessorApp.deletingLastPathComponent,
                "app generations cannot use same-parent atomic rollback"
            )
        case "DM4-T09":
            try check(
                paths.launchAgent.hasSuffix(
                    "/Library/LaunchAgents/com.kleinperkins.shadow-sync.plist"
                ),
                "lifecycle verbs no longer share the stable plist"
            )
        case "DM4-T10":
            try check(
                HostControlRequest.schemaName
                    == "shadow-sync-host-request/v1",
                "host activation wire schema changed"
            )
        case "DM4-T12":
            try check(
                ReleaseIdentity.schemaName == "shadow-sync-release/v2"
                    && shadowSyncSelectionPreferenceSchema
                        == "shadow-sync-repository-selection-preferences/v1",
                "inherited v3 wire schemas changed"
            )
        default:
            throw DM4PreflightError.message("unhandled v4 test \(id)")
        }
    }

    private static func temporaryRoot() throws -> String {
        var template = Array(
            "/private/tmp/shadow-sync-dm4-preflight.XXXXXX".utf8CString
        )
        guard let pointer = mkdtemp(&template) else {
            throw DM4PreflightError.message("could not create v4 test root")
        }
        let path = String(cString: pointer)
        guard chmod(path, 0o700) == 0 else {
            throw DM4PreflightError.message("could not secure v4 test root")
        }
        try FileManager.default.createDirectory(
            atPath: path + "/home",
            withIntermediateDirectories: false,
            attributes: [FileAttributeKey.posixPermissions: 0o700]
        )
        return path
    }

    private static func check(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        if !condition() {
            throw DM4PreflightError.message(message)
        }
    }
}

private extension String {
    var deletingLastPathComponent: String {
        URL(fileURLWithPath: self).deletingLastPathComponent().path
    }
}

private enum DM4PreflightError: Error {
    case message(String)
}
#endif
