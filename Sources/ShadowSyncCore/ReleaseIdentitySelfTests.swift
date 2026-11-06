#if SHADOW_SYNC_TESTING
import Foundation

public enum ReleaseIdentitySelfTestRunner {
    public static func runAll(observer: (String) -> Void = { _ in }) throws {
        let (current, update) = try RuntimeFixtureSession.withCaseValue("RELEASE-IDENTITY-T01-build15-to16") {
            let current = try release()
            let update = try release(version: "0.10.1", build: "16")
            try require(current.version == "0.10.0" && current.buildNumber == "15"
                && update.isForwardVersion(from: current), "initial update ordering")
            return (current, update)
        }
        observer("RELEASE-IDENTITY-T01-build15-to16")
        try RuntimeFixtureSession.withCase("RELEASE-IDENTITY-T02-future-and-independent-builds") {
            try require(try release(version: "1.0.0", build: "30").isForwardVersion(from: update),
                        "later standalone release unreadable")
            try require(try release(build: "16").isForwardVersion(from: current), "independent build sequence")
        }
        observer("RELEASE-IDENTITY-T02-future-and-independent-builds")
        try RuntimeFixtureSession.withCase("RELEASE-IDENTITY-T03-rollback-and-reuse-refused") {
            try require(!current.isForwardVersion(from: update) && !current.isForwardVersion(from: current)
                && !(try release(version: "0.10.0", build: "17")).isForwardVersion(from: update)
                && !(try release(version: "1.0.0", build: "15")).isForwardVersion(from: current),
                "downgrade or reused build accepted")
        }
        observer("RELEASE-IDENTITY-T03-rollback-and-reuse-refused")
        try RuntimeFixtureSession.withCase("RELEASE-IDENTITY-T04-semver-refusals") {
            for version in ["0.9.0", "0.10", "0.10.0.1", "00.10.0", "0.10.01", "0.10.0-beta", "0.10.0+1", "-1.0.0", "0.10.0 ", "０.10.0", "2147483648.0.0"] {
                try require(refuses { _ = try release(version: version) }, "noncanonical semantic version")
            }
        }
        observer("RELEASE-IDENTITY-T04-semver-refusals")
        try RuntimeFixtureSession.withCase("RELEASE-IDENTITY-T05-build-refusals") {
            for build in ["", "0", "14", "015", "+15", "15.0", "15 ", "１5", "2147483648", String(repeating: "9", count: 128)] {
                try require(refuses { _ = try release(build: build) }, "noncanonical build")
            }
        }
        observer("RELEASE-IDENTITY-T05-build-refusals")
        try RuntimeFixtureSession.withCase("RELEASE-IDENTITY-T06-exact-source-provenance") {
            let changedRevision = try release(revision: String(repeating: "d", count: 40))
            try require(current.sameInstallContract(as: current) && !current.sameInstallContract(as: changedRevision),
                        "source revision disappeared from install equality")
        }
        observer("RELEASE-IDENTITY-T06-exact-source-provenance")
        let encoded = try RuntimeFixtureSession.withCaseValue("RELEASE-IDENTITY-T07-codable-validation") {
            let encoded = try JSONEncoder().encode(current)
            try require(try ReleaseIdentity.decode(encoded) == current, "strict JSON roundtrip")
            var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            object["schema"] = "shadow-sync-release/v99"
            try require(refuses { _ = try JSONDecoder().decode(ReleaseIdentity.self, from: JSONSerialization.data(withJSONObject: object)) },
                        "Codable skipped metadata validation")
            return encoded
        }
        observer("RELEASE-IDENTITY-T07-codable-validation")
        try RuntimeFixtureSession.withCase("RELEASE-IDENTITY-T08-closed-bounded-json") {
            var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            object["unexpected"] = true
            try require(refuses { _ = try ReleaseIdentity.decode(JSONSerialization.data(withJSONObject: object)) }
                && refuses { _ = try JSONDecoder().decode(ReleaseIdentity.self, from: JSONSerialization.data(withJSONObject: object)) },
                "unknown JSON field accepted")
            let duplicate = Data(("{\"buildNumber\":\"14\"," + String(decoding: encoded, as: UTF8.self).dropFirst()).utf8)
            try require(refuses { _ = try ReleaseIdentity.decode(duplicate) }
                && refuses { _ = try ReleaseIdentity.decode(encoded + Data("{}".utf8)) }
                && refuses { _ = try ReleaseIdentity.decode(Data(repeating: 32, count: 16_385)) },
                "ambiguous or oversized JSON accepted")
        }
        observer("RELEASE-IDENTITY-T08-closed-bounded-json")
        try RuntimeFixtureSession.withCase("RELEASE-IDENTITY-T09-bundle-platform-refusals") {
            var info = currentInfo()
            try require(try ReleaseIdentity(infoDictionary: info) == current, "bundle metadata mismatch")
            for (key, value) in [("CFBundleIdentifier", "com.fixture.other"), ("CFBundleExecutable", "Other"),
                                 ("ShadowSyncArchitecture", "x86_64"), ("LSMinimumSystemVersion", "15.0"),
                                 ("ShadowSyncBuildMode", "unknown"), ("CFBundleVersion", "14")] {
                info = currentInfo(); info[key] = value
                try require(refuses { _ = try ReleaseIdentity(infoDictionary: info) }, "wrong identity or unsupported platform")
            }
        }
        observer("RELEASE-IDENTITY-T09-bundle-platform-refusals")
        try RuntimeFixtureSession.withCase("RELEASE-IDENTITY-T10-closed-info-namespace") {
            var info = currentInfo(); info["ShadowSyncUnknown"] = "unexpected"
            try require(refuses { _ = try ReleaseIdentity(infoDictionary: info) }, "unknown metadata accepted")
            info = currentInfo(); info["CFBundleVersion"] = 15
            try require(refuses { _ = try ReleaseIdentity(infoDictionary: info) }, "non-string build accepted")
        }
        observer("RELEASE-IDENTITY-T10-closed-info-namespace")
        try RuntimeFixtureSession.withCase("RELEASE-IDENTITY-T11-unqualified-production-refusal") {
            var info = currentInfo(); info["ShadowSyncSourceRevision"] = String(repeating: "0", count: 40)
            let unqualified = try ReleaseIdentity(infoDictionary: info)
            try require(refuses { try unqualified.validate(requireProduction: true) }
                && !unqualified.isForwardVersion(from: current), "zero provenance admitted to production")
            info = currentInfo(); info["ShadowSyncBuildMode"] = "testing"; info["CFBundleVersion"] = "16"
            try require(!(try ReleaseIdentity(infoDictionary: info)).isForwardVersion(from: current), "test build admitted as update")
        }
        observer("RELEASE-IDENTITY-T11-unqualified-production-refusal")
        let legacy = try RuntimeFixtureSession.withCaseValue("RELEASE-IDENTITY-T12-explicit-legacy-reader") {
            let legacy = legacyInfo()
            let decodedLegacy = try LegacyInstallationRelease(infoDictionary: legacy)
            try require(decodedLegacy.sourceRevision == String(repeating: "a", count: 40)
                && refuses { _ = try ReleaseIdentity(infoDictionary: legacy) }
                && refuses { _ = try LegacyInstallationRelease(infoDictionary: currentInfo()) },
                "legacy and current identities were interchangeable")
            return legacy
        }
        observer("RELEASE-IDENTITY-T12-explicit-legacy-reader")
        try RuntimeFixtureSession.withCase("RELEASE-IDENTITY-T13-legacy-version-and-provenance-refusals") {
            for (key, value) in [("CFBundleVersion", "13"), ("CFBundleShortVersionString", "0.8.0"),
                                 ("CFBundleIdentifier", ReleaseIdentity.bundleIdentifier),
                                 ("DevMainSyncSourceRevision", String(repeating: "0", count: 40)),
                                 ("DevMainSyncArchitecture", "x86_64"), ("DevMainSyncBuildMode", "testing")] {
                var changed = legacy; changed[key] = value
                try require(refuses { _ = try LegacyInstallationRelease(infoDictionary: changed) }, "unsupported legacy metadata")
            }
        }
        observer("RELEASE-IDENTITY-T13-legacy-version-and-provenance-refusals")
        try RuntimeFixtureSession.withCase("RELEASE-IDENTITY-T14-mixed-identities-refused") {
            var mixed = currentInfo(); mixed["DevMainSyncReleaseSchema"] = LegacyInstallationRelease.schemaName
            try require(refuses { _ = try ReleaseIdentity(infoDictionary: mixed) }, "mixed current metadata")
            mixed = legacy; mixed["ShadowSyncReleaseSchema"] = ReleaseIdentity.schemaName
            try require(refuses { _ = try LegacyInstallationRelease(infoDictionary: mixed) }, "mixed legacy metadata")
            mixed = legacy; mixed["DevMainSyncUnexpected"] = "unknown"
            try require(refuses { _ = try LegacyInstallationRelease(infoDictionary: mixed) }, "unknown legacy namespace")
        }
        observer("RELEASE-IDENTITY-T14-mixed-identities-refused")
    }

    private static func release(version: String = "0.10.0", build: String = "15", revision: String = String(repeating: "a", count: 40)) throws -> ReleaseIdentity {
        try ReleaseIdentity(version: version, buildNumber: build, sourceRevision: revision,
            sourceInputSHA256: String(repeating: "b", count: 64), releaseContractSHA256: String(repeating: "c", count: 64),
            architecture: "arm64", buildMode: "production")
    }

    private static func currentInfo() -> [String: Any] {
        ["CFBundleIdentifier": ReleaseIdentity.bundleIdentifier, "CFBundleExecutable": "ShadowSync",
         "CFBundleShortVersionString": "0.10.0", "CFBundleVersion": "15", "LSMinimumSystemVersion": "26.0",
         "ShadowSyncReleaseSchema": ReleaseIdentity.schemaName, "ShadowSyncSourceRevision": String(repeating: "a", count: 40),
         "ShadowSyncSourceInputSHA256": String(repeating: "b", count: 64), "ShadowSyncReleaseContractSHA256": String(repeating: "c", count: 64),
         "ShadowSyncArchitecture": "arm64", "ShadowSyncBuildMode": "production"]
    }

    private static func legacyInfo() -> [String: Any] {
        ["CFBundleIdentifier": LegacyInstallationRelease.bundleIdentifier, "CFBundleExecutable": "ShadowSync",
         "CFBundleShortVersionString": "0.9.0", "CFBundleVersion": "14", "LSMinimumSystemVersion": "26.0",
         "DevMainSyncReleaseSchema": LegacyInstallationRelease.schemaName, "DevMainSyncSourceRevision": String(repeating: "a", count: 40),
         "DevMainSyncSourceInputSHA256": String(repeating: "b", count: 64), "DevMainSyncMetadataContractSHA256": String(repeating: "c", count: 64),
         "DevMainSyncArchitecture": "arm64", "DevMainSyncBuildMode": "production"]
    }

    private static func refuses(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(message: message) }
    }
    private struct Failure: Error { let message: String }
}
#endif
