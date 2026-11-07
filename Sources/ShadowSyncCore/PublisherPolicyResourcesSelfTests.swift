#if SHADOW_SYNC_TESTING
import Darwin
import Foundation
import Security

public enum PublisherPolicyResourcesSelfTestRunner {
    private enum Failure: Error { case assertion(String) }
    public static func runAll(onPass: (String) -> Void) throws {
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T01-real-packaged-layout-and-stable-no-follow-inventory") {
            guard let framework = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_FRAMEWORK"],
                  let sourcePath = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_SOURCE"],
                  framework.hasPrefix("/private/tmp/"), sourcePath.hasPrefix("/private/tmp/") else {
                throw Failure.assertion("explicit test resources missing")
            }
            let manifest = try Data(contentsOf: URL(fileURLWithPath: framework + "/" + PolicyRuntimeLayout.manifest))
            let source = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
            let layout = try PolicyRuntimeLayout.decode(manifest, source: source)
            let started = DispatchTime.now().uptimeNanoseconds
            let tree = try PolicyRuntimeTree.capture(root: framework, owner: geteuid(), layout: layout)
            try require(try PolicyRuntimeTree.capture(root: framework, owner: geteuid(), layout: layout) == tree,
                        "stable runtime identity differs")
            print("METRIC policy-runtime two-scans-ns=\(DispatchTime.now().uptimeNanoseconds - started) entries=\(layout.entries.count) macho=\(tree.machOFiles.count)")
            let refreshStart = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<10 { try tree.revalidate(root: framework, owner: geteuid(), layout: layout) }
            print("METRIC policy-runtime ten-revalidations-ns=\(DispatchTime.now().uptimeNanoseconds - refreshStart)")
            try require(layout.entries.count == 158 && tree.machOFiles.count == 85, "qualified runtime inventory changed")
            var nativeCode: SecStaticCode?
            try require(SecStaticCodeCreateWithPath(URL(fileURLWithPath: framework) as CFURL, [], &nativeCode) == errSecSuccess,
                        "fixture native static code")
            try require(SecStaticCodeCheckValidity(nativeCode!, SecCSFlags(rawValue: SecCSFlags.noNetworkAccess.rawValue
                | kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures | kSecCSRestrictSymlinks), nil) == errSecSuccess,
                        "reviewed framework topology rejected by native strict validation")
            try require(SecCodeValidateFileResource(nativeCode!, "Resources/ShadowSyncRuntimeLayout.json" as CFString,
                manifest as CFData, .noNetworkAccess) == errSecSuccess, "native framework manifest seal")
        }
        onPass("PUBLISHER-POLICY-T01-real-packaged-layout-and-stable-no-follow-inventory")
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T02-path-link-ancestor-mode-and-required-file-refusals") {
            guard let framework = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_FRAMEWORK"],
                  let sourcePath = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_SOURCE"],
                  framework.hasPrefix("/private/tmp/"), sourcePath.hasPrefix("/private/tmp/") else {
                throw Failure.assertion("explicit test resources missing")
            }
            let manifest = try Data(contentsOf: URL(fileURLWithPath: framework + "/" + PolicyRuntimeLayout.manifest))
            let source = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
            let layout = try PolicyRuntimeLayout.decode(manifest, source: source)
            let raw = try JSONSerialization.jsonObject(with: manifest) as! [String: Any]
            let rows = raw["entries"] as! [String: Any]
            // Compare the optimized byte predicate against the independent
            // component-based contract, including boundary and Unicode inputs.
            func referencePath(_ path: String) -> Bool {
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                return !path.isEmpty && path.utf8.count <= 1024 && parts.count <= 32
                    && path.utf8.allSatisfy { (32...126).contains($0) && $0 != 92 }
                    && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            }
            var pathCases = Array(rows.keys).sorted() + ["", "/", ".", "..", "...", "a/", "/a", "a//b",
                "a/./b", "a/../b", "a/.../b", "a\\b", "a\n", "a\u{7f}", "a\u{1f}", "Kelvin", "\u{212A}elvin", "é", "e\u{301}",
                String(repeating: "x", count: 1024), String(repeating: "x", count: 1025),
                Array(repeating: "x", count: 32).joined(separator: "/"), Array(repeating: "x", count: 33).joined(separator: "/")]
            let alphabet = ["a", ".", "/", " ", "\\", "\u{7f}", "\u{212A}"]
            for a in alphabet { for b in alphabet { for c in alphabet { for d in alphabet {
                pathCases.append(a + b + c + d)
            } } } }
            try require(pathCases.count == 2582, "runtime path predicate fixture coverage changed")
            for path in pathCases {
                try require(PolicyRuntimeLayout.validPath(path) == referencePath(path), "runtime path predicate changed accepted grammar")
            }
            print("METRIC policy-runtime path-predicate-equivalence-cases=\(pathCases.count)")
            func decode(_ replacement: [String: Any]) throws {
                var changed = raw; changed["entries"] = replacement
                _ = try PolicyRuntimeLayout.decode(JSONSerialization.data(withJSONObject: changed), source: source)
            }
            for bad in ["/outside", "../outside", "Versions/../outside", "Versions//outside", "Versions/./outside",
                        "Versions/\\outside", "Versions/é", "Versions/\n"] {
                var changed = rows; changed[bad] = ["kind": "file", "mode": 420]
                try refused { try decode(changed) }
            }
            var wrong = rows
            wrong["Python"] = ["kind": "symlink", "mode": 493, "target": "/outside"]
            try refused { try decode(wrong) }
            wrong = rows; wrong["Versions/Current/unexpected"] = ["kind": "file", "mode": 420]
            try refused { try decode(wrong) }
            wrong = rows; wrong["Versions/3.14"] = ["kind": "symlink", "mode": 493, "target": "elsewhere"]
            try refused { try decode(wrong) }
            wrong = rows; wrong.removeValue(forKey: "Python")
            try refused { try decode(wrong) }
            wrong = rows; wrong[PolicyRuntimeLayout.interpreter] = ["kind": "file", "mode": 511]
            try refused { try decode(wrong) }
            for required in ["Versions/3.14/lib/python314.zip", "Versions/3.14/Resources/ShadowSyncStdlibArchive.json"] {
                wrong = rows; wrong.removeValue(forKey: required)
                try refused { try decode(wrong) }
            }
            for unsealedFallback in ["Versions/3.14/lib/python3.14/fallback.py", "Versions/3.14/lib/python3.14/fallback.pyc"] {
                wrong = rows; wrong[unsealedFallback] = ["kind": "file", "mode": 420]
                try refused { try decode(wrong) }
            }
        }
        onPass("PUBLISHER-POLICY-T02-path-link-ancestor-mode-and-required-file-refusals")
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T03-closed-grammar-source-binding-and-wire-limits") {
            guard let framework = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_FRAMEWORK"],
                  let sourcePath = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_SOURCE"],
                  framework.hasPrefix("/private/tmp/"), sourcePath.hasPrefix("/private/tmp/") else {
                throw Failure.assertion("explicit test resources missing")
            }
            let manifest = try Data(contentsOf: URL(fileURLWithPath: framework + "/" + PolicyRuntimeLayout.manifest))
            let source = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
            let layout = try PolicyRuntimeLayout.decode(manifest, source: source)
            let duplicate = Data("{\"schema\":0,\"schema\":1}".utf8)
            try refused { _ = try PolicyRuntimeLayout.decode(duplicate, source: source) }
            var changedSource = try JSONSerialization.jsonObject(with: source) as! [String: Any]
            changedSource["package_sha256"] = String(repeating: "b", count: 64)
            try refused { _ = try PolicyRuntimeLayout.decode(manifest, source: JSONSerialization.data(withJSONObject: changedSource)) }
            try refused { _ = try PolicyRuntimeLayout.decode(Data(repeating: 32, count: 1_048_577), source: source) }
            let largeObject = try JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: (0..<17).map { ("k\($0)", 1) }))
            for profile: PolicyWireParser.Profile in [.wire, .configuration] {
                do { var parser = try PolicyWireParser(largeObject, profile: profile); _ = try parser.parse()
                    throw Failure.assertion("wire/config grammar broadened") }
                catch PolicyProtocolError.invalidResponse {}
            }
        }
        onPass("PUBLISHER-POLICY-T03-closed-grammar-source-binding-and-wire-limits")
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T04-content-and-identical-byte-replacement-revoke") {
            guard let framework = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_FRAMEWORK"],
                  let sourcePath = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_SOURCE"],
                  framework.hasPrefix("/private/tmp/"), sourcePath.hasPrefix("/private/tmp/") else {
                throw Failure.assertion("explicit test resources missing")
            }
            let manifest = try Data(contentsOf: URL(fileURLWithPath: framework + "/" + PolicyRuntimeLayout.manifest))
            let source = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
            let layout = try PolicyRuntimeLayout.decode(manifest, source: source)
            let fixture = try Fixture(layout: layout)
            defer { try? fixture.remove() }
            func capture() throws -> PolicyRuntimeTree {
                try PolicyRuntimeTree.capture(root: fixture.framework, owner: geteuid(), layout: layout)
            }
            let mutatedResources: [(String, mode_t)] = [("Versions/3.14/Python", 0o755),
                ("Versions/3.14/lib/python314.zip", 0o644),
                ("Versions/3.14/Resources/ShadowSyncStdlibArchive.json", 0o644)]
            for (relative, mode) in mutatedResources {
                let original = try capture()
                let target = fixture.framework + "/" + relative
                let mutation = relative.hasSuffix("/Python") ? Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,1]) : Data("changed archive resource".utf8)
                try mutation.write(to: URL(fileURLWithPath: target))
                try require(try capture() != original, "content mutation retained identity")
                try refused { try original.revalidate(root: fixture.framework, owner: geteuid(), layout: layout) }
                let changed = try capture()
                let replacement = fixture.path + "/replacement"
                try Data(contentsOf: URL(fileURLWithPath: target)).write(to: URL(fileURLWithPath: replacement))
                try require(chmod(replacement, mode) == 0 && rename(replacement, target) == 0, "replacement setup")
                try require(try capture() != changed, "identical replacement retained identity")
                try refused { try changed.revalidate(root: fixture.framework, owner: geteuid(), layout: layout) }
            }
            try fixture.remove()
        }
        onPass("PUBLISHER-POLICY-T04-content-and-identical-byte-replacement-revoke")
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T05-extra-hardlink-mode-and-symlink-refusals") {
            guard let framework = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_FRAMEWORK"],
                  let sourcePath = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_SOURCE"],
                  framework.hasPrefix("/private/tmp/"), sourcePath.hasPrefix("/private/tmp/") else {
                throw Failure.assertion("explicit test resources missing")
            }
            let manifest = try Data(contentsOf: URL(fileURLWithPath: framework + "/" + PolicyRuntimeLayout.manifest))
            let source = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
            let layout = try PolicyRuntimeLayout.decode(manifest, source: source)
            let fixture = try Fixture(layout: layout)
            defer { try? fixture.remove() }
            func capture() throws -> PolicyRuntimeTree {
                try PolicyRuntimeTree.capture(root: fixture.framework, owner: geteuid(), layout: layout)
            }
            let target = fixture.framework + "/Versions/3.14/Python"
            try Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,1]).write(to: URL(fileURLWithPath: target))
            let extra = fixture.framework + "/unexpected"
            try Data("extra".utf8).write(to: URL(fileURLWithPath: extra))
            try refused { _ = try capture() }
            try require(unlink(extra) == 0, "extra cleanup")
            try require(chmod(target, 0o777) == 0, "mode setup")
            try refused { _ = try capture() }
            try require(chmod(target, 0o755) == 0, "mode restore")
            try require(link(target, extra) == 0, "hardlink setup")
            try refused { _ = try capture() }
            try require(unlink(extra) == 0, "hardlink cleanup")
            let linkPath = fixture.framework + "/Python"
            try require(unlink(linkPath) == 0 && symlink("/outside", linkPath) == 0, "link escape setup")
            try refused { _ = try capture() }
            try require(unlink(linkPath) == 0 && symlink("Versions/Current/Python", linkPath) == 0, "link restore")
            try require(lchmod(linkPath, 0o755) == 0, "link mode restore")
            let alias = fixture.path + "/alias"
            try require(symlink(fixture.framework, alias) == 0, "root alias setup")
            try refused { _ = try PolicyRuntimeTree.capture(root: alias, owner: geteuid(), layout: layout) }
            try fixture.remove()
        }
        onPass("PUBLISHER-POLICY-T05-extra-hardlink-mode-and-symlink-refusals")
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T06-unsupported-and-fat-architecture-refusals") {
            guard let framework = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_FRAMEWORK"],
                  let sourcePath = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_SOURCE"],
                  framework.hasPrefix("/private/tmp/"), sourcePath.hasPrefix("/private/tmp/") else {
                throw Failure.assertion("explicit test resources missing")
            }
            let manifest = try Data(contentsOf: URL(fileURLWithPath: framework + "/" + PolicyRuntimeLayout.manifest))
            let source = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
            let layout = try PolicyRuntimeLayout.decode(manifest, source: source)
            let fixture = try Fixture(layout: layout)
            defer { try? fixture.remove() }
            func capture() throws -> PolicyRuntimeTree {
                try PolicyRuntimeTree.capture(root: fixture.framework, owner: geteuid(), layout: layout)
            }
            let target = fixture.framework + "/Versions/3.14/Python"
            try Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1,1]).write(to: URL(fileURLWithPath: target))
            try Data([0xcf,0xfa,0xed,0xfe,0x07,0,0,1]).write(to: URL(fileURLWithPath: target))
            try refused { _ = try capture() }
            try Data([0xca,0xfe,0xba,0xbe,0,0,0,2]).write(to: URL(fileURLWithPath: target))
            try refused { _ = try capture() }
            try fixture.remove()
        }
        onPass("PUBLISHER-POLICY-T06-unsupported-and-fat-architecture-refusals")
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T07-native-adhoc-unsigned-and-requirement-injection-refusals") {
            guard let framework = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_FRAMEWORK"],
                  let sourcePath = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_SOURCE"],
                  framework.hasPrefix("/private/tmp/"), sourcePath.hasPrefix("/private/tmp/") else {
                throw Failure.assertion("explicit test resources missing")
            }
            let manifest = try Data(contentsOf: URL(fileURLWithPath: framework + "/" + PolicyRuntimeLayout.manifest))
            let source = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
            let layout = try PolicyRuntimeLayout.decode(manifest, source: source)
            let fixture = try Fixture(layout: layout)
            defer { try? fixture.remove() }
            func capture() throws -> PolicyRuntimeTree {
                try PolicyRuntimeTree.capture(root: fixture.framework, owner: geteuid(), layout: layout)
            }
            let target = fixture.framework + "/Versions/3.14/Python"
            try Data([0xca,0xfe,0xba,0xbe,0,0,0,2]).write(to: URL(fileURLWithPath: target))
            // The supplied fixture framework is intentionally ad hoc. Real native
            // Security calls must reject it despite its internally valid layout.
            try refused { _ = try PublisherCodeVerifier.verifiedStatic(path: framework,
                identifier: "com.kleinperkins.shadow-sync.python-runtime", team: nil) }
            try refused { _ = try PublisherCodeVerifier.verifiedStatic(path: fixture.framework,
                identifier: "com.kleinperkins.shadow-sync.python-runtime", team: nil) }
            for invalid in ["", "BAD\" or true", "lowercase1", String(repeating: "A", count: 11)] {
                try refused { _ = try PublisherCodeVerifier.requirement(identifier: "com.kleinperkins.shadow-sync", team: invalid) }
            }
            try refused { _ = try PublisherCodeVerifier.requirement(identifier: "x\" or true", team: nil) }
            _ = try PublisherCodeVerifier.requirement(identifier: "com.kleinperkins.shadow-sync.policy-helper",
                team: "AAAAAAAAAA", codeDirectory: Data(repeating: 1, count: 20))
            try fixture.remove()
        }
        onPass("PUBLISHER-POLICY-T07-native-adhoc-unsigned-and-requirement-injection-refusals")
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T11-native-intended-publisher-requirement") {
            guard let framework = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_FRAMEWORK"],
                  let sourcePath = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_SOURCE"],
                  framework.hasPrefix("/private/tmp/"), sourcePath.hasPrefix("/private/tmp/") else {
                throw Failure.assertion("explicit test resources missing")
            }
            let manifest = try Data(contentsOf: URL(fileURLWithPath: framework + "/" + PolicyRuntimeLayout.manifest))
            let source = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
            let layout = try PolicyRuntimeLayout.decode(manifest, source: source)
            let pinned = try PublisherCodeVerifier.requirement(identifier: ReleaseIdentity.bundleIdentifier,
                team: ReleaseIdentity.publisherTeamIdentifier)
            var expression: CFString?
            try require(SecRequirementCopyString(pinned, [], &expression) == errSecSuccess, "native publisher requirement expression")
            guard let expression else { throw Failure.assertion("missing native requirement") }
            let rendered = expression as String
            try require(rendered.contains("certificate leaf[subject.OU] = ") && rendered.contains(ReleaseIdentity.publisherTeamIdentifier),
                        "intended publisher not bound in native requirement")
            try require(rendered.contains("identifier ") && rendered.contains(ReleaseIdentity.bundleIdentifier), "product identifier absent")
        }
        onPass("PUBLISHER-POLICY-T11-native-intended-publisher-requirement")
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T08-no-production-authority-from-fixtures-or-source-runner") {
            guard let framework = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_FRAMEWORK"],
                  let sourcePath = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_SOURCE"],
                  framework.hasPrefix("/private/tmp/"), sourcePath.hasPrefix("/private/tmp/") else {
                throw Failure.assertion("explicit test resources missing")
            }
            let manifest = try Data(contentsOf: URL(fileURLWithPath: framework + "/" + PolicyRuntimeLayout.manifest))
            let source = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
            let layout = try PolicyRuntimeLayout.decode(manifest, source: source)
            let fixture = try Fixture(layout: layout)
            defer { try? fixture.remove() }
            func capture() throws -> PolicyRuntimeTree {
                try PolicyRuntimeTree.capture(root: fixture.framework, owner: geteuid(), layout: layout)
            }
            let target = fixture.framework + "/Versions/3.14/Python"
            try Data([0xca,0xfe,0xba,0xbe,0,0,0,2]).write(to: URL(fileURLWithPath: target))
            try refused { _ = try PublisherPolicyResources.production(account:
                EffectiveAccount(uid: geteuid(), username: "fixture", homeDirectory: fixture.path)) }
            do { try SelectedRepositoryScopeBinder.withProductionReadPhase(cancellation: CancellationToken()) { _ in }; throw Failure.assertion("test runner became production app") }
            catch SelectedRepositoryScopeError.policyUnavailable {}
            try fixture.remove()
        }
        onPass("PUBLISHER-POLICY-T08-no-production-authority-from-fixtures-or-source-runner")
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T09-replaced-helper-refused-while-suspended-and-reaped") {
            guard let framework = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_FRAMEWORK"],
                  let sourcePath = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_SOURCE"],
                  framework.hasPrefix("/private/tmp/"), sourcePath.hasPrefix("/private/tmp/") else {
                throw Failure.assertion("explicit test resources missing")
            }
            let manifest = try Data(contentsOf: URL(fileURLWithPath: framework + "/" + PolicyRuntimeLayout.manifest))
            let source = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
            let layout = try PolicyRuntimeLayout.decode(manifest, source: source)
            let fixture = try Fixture(layout: layout)
            defer { try? fixture.remove() }
            func capture() throws -> PolicyRuntimeTree {
                try PolicyRuntimeTree.capture(root: fixture.framework, owner: geteuid(), layout: layout)
            }
            let target = fixture.framework + "/Versions/3.14/Python"
            try Data([0xca,0xfe,0xba,0xbe,0,0,0,2]).write(to: URL(fileURLWithPath: target))
            let executable = fixture.path + "/executable"
            guard let testExecutable = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_PUBLISHER_EXECUTABLE"],
                  testExecutable.hasPrefix("/private/tmp/") else {
                throw Failure.assertion("qualified publisher execution fixture missing")
            }
            try FileManager.default.copyItem(atPath: testExecutable, toPath: executable)
            try require(chmod(executable, 0o755) == 0, "executable fixture mode")
            let executableSnapshot = try PublisherExecutableSnapshot.capture(path: executable, owner: geteuid())
            try require(try PublisherExecutableSnapshot.capture(path: executable, owner: geteuid()) == executableSnapshot,
                        "stable executable snapshot")
            let marker = fixture.path + "/executed-marker"
            // Replacement after earlier publisher validation but before the runner
            // establishes its own pathname baseline must never reach script code.
            let swapped = fixture.path + "/swapped-executable"
            try FileManager.default.copyItem(atPath: testExecutable, toPath: swapped)
            try require(chmod(swapped, 0o755) == 0 && rename(swapped, executable) == 0, "replace executable fixture")
            let directory = open(fixture.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
            try require(directory >= 0, "suspended test scratch")
            defer { close(directory) }
            let account = EffectiveAccount(uid: geteuid(), username: "fixture", homeDirectory: fixture.path)
            var observedChild: pid_t = 0
            var replacedIdentityRefused = false
            do {
                _ = try ClosedProcessRunner().run(command: ClosedProcessCommand(executable: executable,
                    arguments: ["--mark"]),
                    environment: ClosedProcessRunner.environment(account: account), workingDirectoryDescriptor: directory,
                    account: account, timeout: 1, cancellation: CancellationToken(), validateSuspendedChild: { pid in
                        observedChild = pid
                        let current = try PublisherExecutableSnapshot.capture(path: executable, owner: geteuid())
                        guard current == executableSnapshot else {
                            replacedIdentityRefused = true
                            throw PublisherPolicyError.unavailable
                        }
                    })
                throw Failure.assertion("replaced helper admitted")
            } catch PublisherPolicyError.unavailable {}
            try require(observedChild > 0 && replacedIdentityRefused
                && !FileManager.default.fileExists(atPath: marker), "unverified child ran or exact replacement refusal missing")
            var status: Int32 = 0
            errno = 0
            try require(waitpid(observedChild, &status, WNOHANG) == -1 && errno == ECHILD, "refused child not reaped")
            try fixture.remove()
        }
        onPass("PUBLISHER-POLICY-T09-replaced-helper-refused-while-suspended-and-reaped")
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T10-live-child-publisher-and-code-hash-refusal-before-execution") {
            guard let framework = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_FRAMEWORK"],
                  let sourcePath = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_SOURCE"],
                  framework.hasPrefix("/private/tmp/"), sourcePath.hasPrefix("/private/tmp/") else {
                throw Failure.assertion("explicit test resources missing")
            }
            let manifest = try Data(contentsOf: URL(fileURLWithPath: framework + "/" + PolicyRuntimeLayout.manifest))
            let source = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
            let layout = try PolicyRuntimeLayout.decode(manifest, source: source)
            let fixture = try Fixture(layout: layout)
            defer { try? fixture.remove() }
            func capture() throws -> PolicyRuntimeTree {
                try PolicyRuntimeTree.capture(root: fixture.framework, owner: geteuid(), layout: layout)
            }
            let target = fixture.framework + "/Versions/3.14/Python"
            try Data([0xca,0xfe,0xba,0xbe,0,0,0,2]).write(to: URL(fileURLWithPath: target))
            let marker = fixture.path + "/executed-marker"
            let directory = open(fixture.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
            try require(directory >= 0, "suspended test scratch")
            defer { close(directory) }
            let account = EffectiveAccount(uid: geteuid(), username: "fixture", homeDirectory: fixture.path)
            var status: Int32 = 0
            var signatureChild: pid_t = 0
            var guestValidated = false, expectedPublisherRefused = false
            do {
                _ = try ClosedProcessRunner().run(command: ClosedProcessCommand(executable: "/bin/sh",
                    arguments: ["-c", "printf executed > '\(marker)'"]),
                    environment: ClosedProcessRunner.environment(account: account), workingDirectoryDescriptor: directory,
                    account: account, timeout: 1, cancellation: CancellationToken(), validateSuspendedChild: { pid in
                        signatureChild = pid
                        var live: SecCode?
                        guard SecCodeCopyGuestWithAttributes(nil,
                            [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary, [], &live) == errSecSuccess,
                              let live, SecCodeCheckValidity(live, .noNetworkAccess, nil) == errSecSuccess else {
                            throw Failure.assertion("native suspended guest lookup unavailable")
                        }
                        guestValidated = true
                        do {
                            try PublisherCodeVerifier.suspendedChild(pid, expected: PublisherCodeVerifier.Identity(
                                team: "AAAAAAAAAA", identifier: "com.kleinperkins.shadow-sync.policy-helper",
                                codeDirectory: Data(repeating: 1, count: 20)))
                        } catch PublisherPolicyError.unavailable {
                            expectedPublisherRefused = true
                            throw PublisherPolicyError.unavailable
                        }
                    })
                throw Failure.assertion("wrong publisher child admitted")
            } catch PublisherPolicyError.unavailable {}
            try require(signatureChild > 0 && guestValidated && expectedPublisherRefused
                && !FileManager.default.fileExists(atPath: marker), "wrong publisher test did not reach exact native rejection")
            errno = 0
            try require(waitpid(signatureChild, &status, WNOHANG) == -1 && errno == ECHILD, "wrong publisher child not reaped")
            try fixture.remove()
        }
        onPass("PUBLISHER-POLICY-T10-live-child-publisher-and-code-hash-refusal-before-execution")
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T12-bulk-record-bounds-and-missing-attribute-refusals") {
            func put<T>(_ value: T, at offset: Int, into bytes: inout [UInt8]) {
                withUnsafeBytes(of: value) { bytes.replaceSubrange(offset..<(offset + $0.count), with: $0) }
            }
            func record(directory: Bool) -> [UInt8] {
                var b = [UInt8](repeating: 0, count: directory ? 112 : 120)
                put(UInt32(b.count), at: 0, into: &b)
                put(UInt32(0xa2078c0b), at: 4, into: &b)
                put(UInt32(directory ? 0 : 0x201), at: 16, into: &b)
                put(Int32(directory ? 72 : 84), at: 28, into: &b)
                put(UInt32(8), at: 32, into: &b); put(Int32(17), at: 36, into: &b)
                put(UInt32(directory ? 2 : 1), at: 40, into: &b)
                put(Int64(123), at: 44, into: &b); put(Int64(456), at: 52, into: &b)
                put(Int64(789), at: 60, into: &b); put(Int64(12), at: 68, into: &b)
                put(UInt32(501), at: 76, into: &b); put(UInt32(20), at: 80, into: &b)
                put(UInt32(0o755), at: 84, into: &b); put(UInt64(12345), at: 92, into: &b)
                if !directory { put(UInt32(1), at: 100, into: &b); put(Int64(24), at: 104, into: &b) }
                b.replaceSubrange((directory ? 100 : 112)..<(directory ? 108 : 120), with: Array("fixture\0".utf8))
                return b
            }
            func decode(_ b: [UInt8], offset: Int = 0) throws -> PolicyRuntimeBulkDirectory.Entry {
                try b.withUnsafeBytes { try PolicyRuntimeBulkDirectory.decode($0, offset: offset) }
            }
            let valid = record(directory: false), directory = record(directory: true)
            let file = try decode(valid)
            try require(file.name == "fixture" && file.length == 120 && file.regularFile?.st_size == 24
                && file.regularFile?.st_mode == 0o100755 && file.regularFile?.st_ino == 12345,
                "valid packed regular metadata differs")
            try require(try decode(directory).regularFile == nil && decode(directory).name == "fixture",
                        "directory must retain no-follow stat path")
            for end in 0..<valid.count { try refused { _ = try decode(Array(valid.prefix(end))) } }
            for (offset, value): (Int, UInt32) in [(0, 0), (0, 119), (0, 128), (8, 1), (12, 1), (20, 1),
                (16, 0), (16, 1), (16, 0x200), (16, 0x202), (24, 5), (28, 0), (28, UInt32.max),
                (28, 80), (28, 85), (32, 0), (32, 1), (32, 9), (32, 257), (40, 0), (40, 4),
                (84, 0x10000), (100, 65536)] {
                var b = valid; put(value, at: offset, into: &b)
                try refused { _ = try decode(b) }
            }
            for bit in 0..<32 where PolicyRuntimeBulkDirectory.common & (UInt32(1) << bit) != 0 && bit != 29 {
                var b = valid; put(PolicyRuntimeBulkDirectory.common & ~(UInt32(1) << bit), at: 4, into: &b)
                try refused { _ = try decode(b) }
            }
            for offset in [52, 68] {
                for n: Int64 in [-1, 1_000_000_000] {
                    var b = valid; put(n, at: offset, into: &b); try refused { _ = try decode(b) }
                }
            }
            for (offset, value): (Int, UInt8) in [(112, 0), (113, 47), (113, 92), (113, 127), (119, 1)] {
                var b = valid; b[offset] = value; try refused { _ = try decode(b) }
            }
            try refused { _ = try decode(valid, offset: -1) }
            try refused { _ = try decode([0] + valid, offset: 1) }
            var shifted = [UInt8](repeating: 0, count: 8); shifted += valid
            try require(try decode(shifted, offset: 8).name == "fixture", "aligned subsequent record")
        }
        onPass("PUBLISHER-POLICY-T12-bulk-record-bounds-and-missing-attribute-refusals")
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T13-native-bulk-stat-full-inventory-parity") {
            guard let framework = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_FRAMEWORK"],
                  let sourcePath = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_SOURCE"],
                  framework.hasPrefix("/private/tmp/"), sourcePath.hasPrefix("/private/tmp/") else {
                throw Failure.assertion("explicit test resources missing")
            }
            let layout = try PolicyRuntimeLayout.decode(Data(contentsOf: URL(fileURLWithPath: framework + "/" + PolicyRuntimeLayout.manifest)),
                source: Data(contentsOf: URL(fileURLWithPath: sourcePath)))
            var compared: Set<String> = [], regular = 0
            var pool = PolicyRuntimeBulkDirectory.Pool()
            var active: Set<UInt> = [], storage: Set<UInt> = []
            var scans = 0, reused = 0, pendingParents = 0, highWater = 0
            func walk(_ fd: Int32, prefix: String) throws {
                var reader: PolicyRuntimeBulkDirectory? = pool.take()
                let address = reader!.testingStorageAddress
                try require(reader!.testingIsReset && active.insert(address).inserted,
                            "checked-out bulk scratch is stale or aliases active parent")
                if !storage.insert(address).inserted { reused += 1 }
                scans += 1; highWater = max(highWater, active.count)
                defer { pool.put(&reader); active.remove(address) }
                while let entry = try reader!.next(fd: fd) {
                    try require(reader!.testingStorageAddress == address, "bulk refill unexpectedly copied scratch")
                    let path = prefix.isEmpty ? entry.name : prefix + "/" + entry.name
                    try require(compared.insert(path).inserted && compared.count <= 4096, "bulk duplicates or overflow")
                    var reference = stat()
                    try require(fstatat(fd, entry.name, &reference, AT_SYMLINK_NOFOLLOW) == 0, "reference no-follow metadata")
                    if let value = entry.regularFile {
                        try require(PolicyRuntimeTree.Node(value, acl: "") == PolicyRuntimeTree.Node(reference, acl: ""),
                                    "bulk metadata differs from independent stat predicate")
                        regular += 1
                    } else {
                        try require(reference.st_mode & S_IFMT != S_IFREG, "missing regular-file attributes")
                    }
                    if reference.st_mode & S_IFMT == S_IFDIR {
                        let child = openat(fd, entry.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        try require(child >= 0, "parity child directory")
                        defer { close(child) }
                        let pending = reader!.testingPendingCount
                        if pending > 0 { pendingParents += 1 }
                        try walk(child, prefix: path)
                        try require(reader!.testingPendingCount == pending && reader!.testingStorageAddress == address,
                                    "recursive child changed pending parent batch")
                    }
                }
                try require(reader!.testingStorageAddress == address, "bulk EOF unexpectedly copied scratch")
            }
            let fd = Darwin.open(framework, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try require(fd >= 0, "parity root"); defer { close(fd) }
            try walk(fd, prefix: "")
            try require(compared == Set(layout.entries.keys) && compared.count == 158 && regular == 124,
                        "complete packaged runtime parity")
            try require(scans == 22 && highWater == 7 && storage.count == highWater && reused == scans - highWater
                && pendingParents > 0 && active.isEmpty, "bulk scratch recursion/reuse coverage changed")
            print("METRIC policy-runtime bulk-stat-parity-entries=\(compared.count) regular=\(regular)")
        }
        onPass("PUBLISHER-POLICY-T13-native-bulk-stat-full-inventory-parity")
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T14-bulk-revalidation-drift-refusals") {
            guard let framework = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_FRAMEWORK"],
                  let sourcePath = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_SOURCE"],
                  framework.hasPrefix("/private/tmp/"), sourcePath.hasPrefix("/private/tmp/") else {
                throw Failure.assertion("explicit test resources missing")
            }
            let layout = try PolicyRuntimeLayout.decode(Data(contentsOf: URL(fileURLWithPath: framework + "/" + PolicyRuntimeLayout.manifest)),
                source: Data(contentsOf: URL(fileURLWithPath: sourcePath)))
            let fixture = try Fixture(layout: layout); defer { try? fixture.remove() }
            func tree() throws -> PolicyRuntimeTree { try PolicyRuntimeTree.capture(root: fixture.framework, owner: geteuid(), layout: layout) }
            func reject(_ prior: PolicyRuntimeTree) throws { try refused { try prior.revalidate(root: fixture.framework, owner: geteuid(), layout: layout) } }
            let target = fixture.framework + "/Versions/3.14/Python"
            var prior = try tree(); try prior.revalidate(root: fixture.framework, owner: geteuid(), layout: layout)
            try require(chmod(target, 0o644) == 0, "drift mode"); try reject(prior)
            try require(chmod(target, 0o755) == 0, "restore mode")
            prior = try tree()
            let alias = fixture.path + "/extra-hardlink"
            try require(link(target, alias) == 0, "external hardlink"); try reject(prior)
            try require(unlink(alias) == 0, "remove owned hardlink")
            prior = try tree()
            let extra = fixture.framework + "/unexpected"
            try Data("fixture".utf8).write(to: URL(fileURLWithPath: extra), options: .withoutOverwriting)
            try reject(prior); try require(unlink(extra) == 0, "remove owned extra")
            prior = try tree()
            let retained = fixture.path + "/retained-file"
            try require(rename(target, retained) == 0, "missing file"); try reject(prior)
            try require(rename(retained, target) == 0, "restore missing file")
            prior = try tree()
            let linkPath = fixture.framework + "/Python"
            try require(unlink(linkPath) == 0 && symlink("missing", linkPath) == 0 && lchmod(linkPath, 0o755) == 0, "link drift")
            try reject(prior)
            try fixture.remove()
        }
        onPass("PUBLISHER-POLICY-T14-bulk-revalidation-drift-refusals")

        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T15-install-inventory-preserves-sealed-links-and-modes") {
            try withBundleFixture { fixture, app, layout in
                let original = try BundleArtifactIdentity.testingInspect(bundlePath: app, layout: layout)
                try require(original.inventory.filter { $0.hasPrefix("l\u{0}") }.count == PolicyRuntimeLayout.links.count,
                            "reviewed links missing from canonical inventory")
                let copy = fixture.path + "/staged.app"
                try FileManager.default.copyItem(atPath: app, toPath: copy)
                try InstallationLifecycle.testingSyncPublisherBundle(copy, layout: layout)
                let copied = try BundleArtifactIdentity.testingInspect(bundlePath: copy, layout: layout)
                try require(original == copied, "signed layout changed during bundle copy")
                var info = stat()
                try require(lstat(copy + "/Contents/Helpers/ShadowSyncLifecycleCoordinator", &info) == 0
                    && info.st_mode & 0o7777 == 0o755, "coordinator executable mode changed")
            }
        }
        onPass("PUBLISHER-POLICY-T15-install-inventory-preserves-sealed-links-and-modes")
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T16-install-extra-links-and-permission-drift-refuse") {
            try withBundleFixture { _, app, layout in
                func inspect() throws { _ = try BundleArtifactIdentity.testingInspect(bundlePath: app, layout: layout) }
                let extra = app + "/Contents/Resources/unexpected"
                try Data("extra".utf8).write(to: URL(fileURLWithPath: extra))
                try refused { try inspect() }; try require(unlink(extra) == 0, "extra cleanup")
                try require(symlink("ShadowSync.icns", extra) == 0, "unknown link setup")
                try refused { try inspect() }; try require(unlink(extra) == 0, "link cleanup")
                let helper = app + "/Contents/Helpers/ShadowSyncLifecycleCoordinator"
                try require(chmod(helper, 0o700) == 0, "mode drift setup")
                try refused { try inspect() }; try require(chmod(helper, 0o755) == 0, "mode restore")
                // Revalidation must catch drift after the initial inventory,
                // including modes that are outside the code-signature seal.
                for relative in ["Contents/Helpers/ShadowSyncLifecycleCoordinator", "Contents/Helpers"] {
                    let retained = try PublisherBundleLayout.testing(bundlePath: app, layout: layout)
                    try retained.revalidate()
                    try require(chmod(app + "/" + relative, 0o777) == 0, "late mode drift")
                    try refused { try retained.revalidate() }
                    try require(chmod(app + "/" + relative, 0o755) == 0, "late mode restore")
                }
                let retained = try PublisherBundleLayout.testing(bundlePath: app, layout: layout)
                try Data("late extra".utf8).write(to: URL(fileURLWithPath: extra))
                try refused { try retained.revalidate() }
                try require(unlink(extra) == 0, "late extra cleanup")
                let link = app + "/" + PublisherBundleLayout.frameworkRelative + "/Python"
                try require(unlink(link) == 0 && symlink("/outside", link) == 0 && lchmod(link, 0o755) == 0, "escaped link setup")
                try refused { try inspect() }
            }
        }
        onPass("PUBLISHER-POLICY-T16-install-extra-links-and-permission-drift-refuse")
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T17-install-required-resources-and-quarantine") {
            try withBundleFixture { _, app, layout in
                let original = try BundleArtifactIdentity.testingInspect(bundlePath: app, layout: layout)
                let quarantine = Data("0081;00000000;Fixture;".utf8)
                try quarantine.withUnsafeBytes { bytes in
                    try require(setxattr(app, "com.apple.quarantine", bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW) == 0,
                                "quarantine setup")
                }
                try require(try BundleArtifactIdentity.testingInspect(bundlePath: app, layout: layout) == original,
                            "quarantine changed sealed inventory")
                try require(getxattr(app, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) == quarantine.count,
                            "quarantine removed")
                let helper = app + "/Contents/Helpers/ShadowSyncLifecycleCoordinator"
                try require(unlink(helper) == 0, "missing helper setup")
                try refused { _ = try BundleArtifactIdentity.testingInspect(bundlePath: app, layout: layout) }
            }
        }
        onPass("PUBLISHER-POLICY-T17-install-required-resources-and-quarantine")
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T18-install-layout-does-not-grant-publisher-authority") {
            try withBundleFixture { _, app, layout in
                _ = try BundleArtifactIdentity.testingInspect(bundlePath: app, layout: layout)
                try refused { _ = try BundleArtifactIdentity.inspect(bundlePath: app, requireProduction: true) }
                try refused { _ = try PublisherBundleLayout.captureIfPresent(app) }
            }
        }
        onPass("PUBLISHER-POLICY-T18-install-layout-does-not-grant-publisher-authority")

        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T19-install-stapled-ticket-preservation-and-refusals") {
            try withBundleFixture { fixture, app, layout in
                let unstapled = try PublisherBundleLayout.testing(bundlePath: app, layout: layout)
                let path = app + "/" + PublisherBundleLayout.ticketRelative
                let bytes = Data("synthetic notarization ticket; no publisher authority".utf8)
                try bytes.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
                try require(chmod(path, 0o644) == 0, "ticket mode")
                try refused { try unstapled.revalidate() }
                let original = try BundleArtifactIdentity.testingInspect(bundlePath: app, layout: layout)
                let retained = try PublisherBundleLayout.testing(bundlePath: app, layout: layout)
                try retained.revalidate()
                let copy = fixture.path + "/stapled.app"
                try FileManager.default.copyItem(atPath: app, toPath: copy)
                try InstallationLifecycle.testingSyncPublisherBundle(copy, layout: layout)
                try require(try BundleArtifactIdentity.testingInspect(bundlePath: copy, layout: layout) == original,
                            "staging changed the ticket or signed layout")
                try refused { _ = try PublisherBundleLayout.captureIfPresent(app) }
                try Data("changed".utf8).write(to: URL(fileURLWithPath: path))
                try refused { try retained.revalidate() }
                try bytes.write(to: URL(fileURLWithPath: path))
                try require(chmod(path, 0o755) == 0, "executable ticket setup")
                try refused { _ = try BundleArtifactIdentity.testingInspect(bundlePath: app, layout: layout) }
                try require(chmod(path, 0o644) == 0, "ticket mode restore")
                try Data().write(to: URL(fileURLWithPath: path))
                try refused { _ = try BundleArtifactIdentity.testingInspect(bundlePath: app, layout: layout) }
                try require(unlink(path) == 0 && symlink("Info.plist", path) == 0, "ticket alias setup")
                try refused { _ = try BundleArtifactIdentity.testingInspect(bundlePath: app, layout: layout) }
            }
        }
        onPass("PUBLISHER-POLICY-T19-install-stapled-ticket-preservation-and-refusals")
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T20-bulk-sibling-reset-multirefill-and-copy-isolation") {
            var entries: [String: PolicyRuntimeLayout.Entry] = [:]
            for name in ["large", "small", "empty"] {
                entries[name] = .init(kind: .directory, mode: 0o755, target: nil)
            }
            var largeNames: Set<String> = []
            for index in 0..<900 {
                let name = String(format: "item-%04d-", index) + String(repeating: "x", count: 120)
                largeNames.insert(name)
                entries["large/" + name] = .init(kind: .file, mode: 0o644, target: nil)
            }
            entries["small/only"] = .init(kind: .file, mode: 0o644, target: nil)
            let fixture = try Fixture(layout: PolicyRuntimeLayout(entries: entries))
            defer { try? fixture.remove() }
            var pool = PolicyRuntimeBulkDirectory.Pool()
            var reader: PolicyRuntimeBulkDirectory? = pool.take()
            let address = reader!.testingStorageAddress
            func collect(_ name: String, expected: Set<String>, multi: Bool = false) throws {
                try require(reader!.testingIsReset && reader!.testingStorageAddress == address, "sibling scratch not fully reset/reused")
                let fd = Darwin.open(fixture.framework + "/" + name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                try require(fd >= 0, "sibling directory open"); defer { close(fd) }
                var names: Set<String> = [], batches: Set<Int> = []
                while let entry = try reader!.next(fd: fd) {
                    try require(names.insert(entry.name).inserted && reader!.testingStorageAddress == address,
                                "sibling duplicate or COW allocation")
                    batches.insert(reader!.testingTotalCount)
                }
                try require(names == expected && (!multi || batches.count > 1), "sibling stale tail, count or refill differs")
                try require(try reader!.next(fd: fd) == nil, "sibling EOF not stable")
                pool.put(&reader); try require(reader == nil, "returned scratch remains checked out")
                reader = pool.take()
            }
            try collect("large", expected: largeNames, multi: true)
            try collect("small", expected: ["only"])
            try collect("empty", expected: [])
            try collect("large", expected: largeNames, multi: true)
            try collect("empty", expected: [])
            try collect("small", expected: ["only"])
            let fd = Darwin.open(fixture.framework + "/large", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try require(fd >= 0, "alias directory open"); defer { close(fd) }
            let first = try reader!.next(fd: fd)
            var alias = reader!
            let pending = alias.testingPendingCount
            try require(first != nil && pending > 0, "alias fixture lacks pending batch")
            pool.put(&reader); reader = pool.take()
            try require(reader!.testingIsReset && reader!.testingStorageAddress != alias.testingStorageAddress
                && alias.testingStorageAddress == address && alias.testingPendingCount == pending,
                "reset mutated copied pending reader or failed COW isolation")
            let second = try alias.next(fd: fd)
            try require(second != nil && second!.name != first!.name && largeNames.contains(second!.name)
                && alias.testingPendingCount == pending - 1, "copied pending batch was cleared")
            pool.put(&reader)
            try fixture.remove()
        }
        onPass("PUBLISHER-POLICY-T20-bulk-sibling-reset-multirefill-and-copy-isolation")
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T21-bulk-throw-unwind-clears-scratch-and-descriptors") {
            let layout = PolicyRuntimeLayout(entries: ["child": .init(kind: .directory, mode: 0o755, target: nil),
                "child/é": .init(kind: .file, mode: 0o644, target: nil)])
            let fixture = try Fixture(layout: layout); defer { try? fixture.remove() }
            var pool = PolicyRuntimeBulkDirectory.Pool(), addresses: Set<UInt> = []
            var closed: [Int32] = [], active: Set<UInt> = [], enteredChild = false
            func walk(_ path: String) throws {
                let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                try require(fd >= 0, "throw directory open")
                defer { close(fd); closed.append(fd) }
                var reader: PolicyRuntimeBulkDirectory? = pool.take()
                let address = reader!.testingStorageAddress
                try require(reader!.testingIsReset && active.insert(address).inserted, "throw active scratch alias")
                addresses.insert(address)
                defer { pool.put(&reader); active.remove(address) }
                while let entry = try reader!.next(fd: fd) {
                    try require(entry.name == "child", "throw fixture unexpected entry")
                    enteredChild = true
                    try walk(path + "/" + entry.name)
                }
            }
            try refused { try walk(fixture.framework) }
            try require(enteredChild && addresses.count == 2 && active.isEmpty && closed.count == 2,
                        "throw fixture did not unwind both active frames")
            for fd in closed { errno = 0; try require(fcntl(fd, F_GETFD) == -1 && errno == EBADF, "throw descriptor leaked") }
            var first: PolicyRuntimeBulkDirectory? = pool.take(), second: PolicyRuntimeBulkDirectory? = pool.take()
            try require(first!.testingIsReset && second!.testingIsReset
                && first!.testingStorageAddress != second!.testingStorageAddress
                && addresses == [first!.testingStorageAddress, second!.testingStorageAddress], "throw scratch reset/COW differs")
            pool.put(&first); pool.put(&second)
            // A separate invocation-local pool has no active storage in common.
            var fresh = PolicyRuntimeBulkDirectory.Pool()
            var next: PolicyRuntimeBulkDirectory? = fresh.take()
            try require(next!.testingIsReset && !addresses.contains(next!.testingStorageAddress), "fresh invocation retained old scratch")
            fresh.put(&next)
            try fixture.remove()
        }
        onPass("PUBLISHER-POLICY-T21-bulk-throw-unwind-clears-scratch-and-descriptors")
        try RuntimeFixtureSession.withCase("PUBLISHER-POLICY-T22-bulk-recursive-multibatch-physical-drift-refusals") {
            guard let framework = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_FRAMEWORK"],
                  let sourcePath = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_SOURCE"],
                  framework.hasPrefix("/private/tmp/"), sourcePath.hasPrefix("/private/tmp/") else {
                throw Failure.assertion("explicit test resources missing")
            }
            let original = try PolicyRuntimeLayout.decode(
                Data(contentsOf: URL(fileURLWithPath: framework + "/" + PolicyRuntimeLayout.manifest)),
                source: Data(contentsOf: URL(fileURLWithPath: sourcePath)))
            var entries = original.entries
            // Root needs multiple native batches while nested siblings retain
            // pending parent records. The direct reader case proves refills.
            for index in 0..<400 {
                entries[String(format: "root-%04d-", index) + String(repeating: "x", count: 120)] =
                    .init(kind: .file, mode: 0o644, target: nil)
            }
            for index in 0..<12 {
                let name = String(format: "sibling-%02d", index)
                entries[name] = .init(kind: .directory, mode: 0o755, target: nil)
                entries[name + "/nested"] = .init(kind: .directory, mode: 0o755, target: nil)
                entries[name + "/nested/file"] = .init(kind: .file, mode: 0o644, target: nil)
            }
            let layout = PolicyRuntimeLayout(entries: entries)
            func verify(_ mutation: (Fixture, String) throws -> Void) throws {
                let fixture = try Fixture(layout: layout); defer { try? fixture.remove() }
                let tree = try PolicyRuntimeTree.capture(root: fixture.framework, owner: geteuid(), layout: layout)
                try tree.revalidate(root: fixture.framework, owner: geteuid(), layout: layout)
                try require(tree.nodes.count == entries.count + 1, "recursive inventory omitted entries")
                try mutation(fixture, fixture.framework + "/sibling-11/nested/file")
                try refused { try tree.revalidate(root: fixture.framework, owner: geteuid(), layout: layout) }
                try fixture.remove()
            }
            try verify { fixture, target in
                let replacement = fixture.path + "/replacement"
                try Data(contentsOf: URL(fileURLWithPath: target)).write(to: URL(fileURLWithPath: replacement))
                try require(chmod(replacement, 0o644) == 0 && rename(replacement, target) == 0, "recursive inode replacement")
            }
            try verify { _, target in try require(chmod(target, 0o600) == 0, "recursive mode drift") }
            try verify { fixture, target in try require(link(target, fixture.path + "/hardlink") == 0, "recursive link-count drift") }
            try verify { _, target in try Data("changed metadata".utf8).write(to: URL(fileURLWithPath: target)) }
            try verify { _, target in try require(unlink(target) == 0, "recursive missing entry") }
            try verify { _, target in try Data("extra".utf8).write(to: URL(fileURLWithPath: target + "-extra")) }
            try verify { fixture, _ in
                let link = fixture.framework + "/Python"
                try require(unlink(link) == 0 && symlink("missing", link) == 0 && lchmod(link, 0o755) == 0,
                            "recursive symlink drift")
            }
            try verify { fixture, _ in
                let ancestor = fixture.framework + "/sibling-11/nested"
                try require(rename(ancestor, fixture.path + "/old-ancestor") == 0 && mkdir(ancestor, 0o755) == 0
                    && chmod(ancestor, 0o755) == 0, "recursive ancestor replacement")
                try Data("fixture".utf8).write(to: URL(fileURLWithPath: ancestor + "/file"))
                try require(chmod(ancestor + "/file", 0o644) == 0, "recursive replacement mode")
            }
            // Use the established qualified chmod fixture, then clear only
            // this owned ACL before identity-checked fixture removal.
            let aclFixture = try Fixture(layout: layout)
            let aclTarget = aclFixture.framework + "/sibling-11/nested/file"
            defer {
                if let empty = acl_init(0) {
                    _ = acl_set_link_np(aclTarget, ACL_TYPE_EXTENDED, empty)
                    acl_free(UnsafeMutableRawPointer(empty))
                }
                try? aclFixture.remove()
            }
            let retained = try PolicyRuntimeTree.capture(root: aclFixture.framework, owner: geteuid(), layout: layout)
            try retained.revalidate(root: aclFixture.framework, owner: geteuid(), layout: layout)
            let directory = open(aclFixture.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            try require(directory >= 0, "ACL drift scratch open"); defer { close(directory) }
            let account = EffectiveAccount(uid: geteuid(), username: "fixture", homeDirectory: aclFixture.path)
            let changed = try ClosedProcessRunner(outputLimit: 4096).run(
                command: ClosedProcessCommand(executable: "/bin/chmod", arguments: ["+a", "everyone deny delete", aclTarget]),
                environment: ClosedProcessRunner.environment(account: account), workingDirectoryDescriptor: directory,
                account: account, timeout: 2, cancellation: CancellationToken())
            try require(changed.status == 0 && !changed.timedOut && !changed.cancelled
                && !changed.stdoutTruncated && !changed.stderrTruncated, "ACL drift setup failed")
            errno = 0
            try require(waitpid(changed.processID, nil, WNOHANG) == -1 && errno == ECHILD, "ACL drift child not reaped")
            try refused { try retained.revalidate(root: aclFixture.framework, owner: geteuid(), layout: layout) }
        }
        onPass("PUBLISHER-POLICY-T22-bulk-recursive-multibatch-physical-drift-refusals")
    }


    private static func withBundleFixture(_ body: (Fixture, String, PolicyRuntimeLayout) throws -> Void) throws {
        guard let framework = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_FRAMEWORK"],
              let source = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_SOURCE"],
              framework.hasPrefix("/private/tmp/"), source.hasPrefix("/private/tmp/") else {
            throw Failure.assertion("explicit test resources missing")
        }
        let layout = try PolicyRuntimeLayout.decode(
            Data(contentsOf: URL(fileURLWithPath: framework + "/" + PolicyRuntimeLayout.manifest)),
            source: Data(contentsOf: URL(fileURLWithPath: source)))
        let fixture = try Fixture(layout: layout); defer { try? fixture.remove() }
        let app = fixture.path + "/ShadowSync.app"
        for relative in PublisherBundleLayout.testingDirectories.sorted() where relative != PublisherBundleLayout.frameworkRelative {
            let path = relative.isEmpty ? app : app + "/" + relative
            try require(mkdir(path, 0o755) == 0 && chmod(path, 0o755) == 0, "bundle fixture directory")
        }
        try require(rename(fixture.framework, app + "/" + PublisherBundleLayout.frameworkRelative) == 0, "embed fixture framework")
        for relative in PublisherBundleLayout.testingExecutables.union(PublisherBundleLayout.testingResources) {
            let path = app + "/" + relative
            try Data("fixture".utf8).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
            try require(chmod(path, PublisherBundleLayout.testingExecutables.contains(relative) ? 0o755 : 0o644) == 0,
                        "bundle fixture file mode")
        }
        let info: [String: String] = [
            "CFBundleIdentifier": ReleaseIdentity.bundleIdentifier, "CFBundleExecutable": "ShadowSync",
            "CFBundleShortVersionString": "0.10.0", "CFBundleVersion": "15", "LSMinimumSystemVersion": "26.0",
            "ShadowSyncReleaseSchema": ReleaseIdentity.schemaName, "ShadowSyncArchitecture": "arm64",
            "ShadowSyncBuildMode": "production", "ShadowSyncSourceRevision": String(repeating: "a", count: 40),
            "ShadowSyncSourceInputSHA256": String(repeating: "b", count: 64),
            "ShadowSyncReleaseContractSHA256": String(repeating: "c", count: 64),
        ]
        try Data(contentsOf: URL(fileURLWithPath: framework + "/" + PolicyRuntimeLayout.manifest))
            .write(to: URL(fileURLWithPath: app + "/" + PublisherBundleLayout.frameworkRelative + "/" + PolicyRuntimeLayout.manifest))
        try Data(contentsOf: URL(fileURLWithPath: source))
            .write(to: URL(fileURLWithPath: app + "/Contents/Resources/policy-runtime-source.json"))
        let bytes = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try bytes.write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
        try body(fixture, app, layout)
        try fixture.remove()
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure.assertion(message) }
    }
    private static func refused(_ body: () throws -> Void) throws {
        do { try body(); throw Failure.assertion("unsafe resources accepted") }
        catch PublisherPolicyError.unavailable {}
        catch PolicyAuthorityFileError.unavailable {}
    }
    private final class Fixture {
        let path: String, framework: String
        let device: Int32, inode: UInt64
        private var removed = false
        init(layout: PolicyRuntimeLayout) throws {
            var template = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-publisher-policy-") + "XXXXXX").utf8CString)
            guard let created = mkdtemp(&template) else { throw Failure.assertion("fixture create") }
            path = String(cString: created); framework = path + "/Python.framework"
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFDIR,
                  info.st_mode & 0o777 == 0o700 else { throw Failure.assertion("fixture identity") }
            device = info.st_dev; inode = info.st_ino
            do {
                try require(mkdir(framework, 0o755) == 0 && chmod(framework, 0o755) == 0, "framework create")
                for (name, entry) in layout.entries.sorted(by: { $0.key < $1.key }) {
                    let full = framework + "/" + name
                    switch entry.kind {
                    case .directory:
                        try require(mkdir(full, 0o755) == 0 && chmod(full, 0o755) == 0, "fixture directory")
                    case .file:
                        let bytes = name == PolicyRuntimeLayout.interpreter || name == "Versions/3.14/Python"
                            ? Data([0xcf,0xfa,0xed,0xfe,0x0c,0,0,1]) : Data("fixture".utf8)
                        try bytes.write(to: URL(fileURLWithPath: full), options: .withoutOverwriting)
                        try require(chmod(full, mode_t(entry.mode)) == 0, "fixture file mode")
                    case .symlink:
                        try require(symlink(entry.target!, full) == 0 && lchmod(full, 0o755) == 0, "fixture link")
                    }
                }
            } catch {
                try? remove()
                throw error
            }
        }
        func remove() throws {
            if removed { return }
            var info = stat()
            try require(lstat(path, &info) == 0 && info.st_dev == device && info.st_ino == inode
                && info.st_uid == geteuid() && info.st_mode & S_IFMT == S_IFDIR, "refuse changed cleanup root")
            try FileManager.default.removeItem(atPath: path); removed = true
        }
    }
}
#endif
