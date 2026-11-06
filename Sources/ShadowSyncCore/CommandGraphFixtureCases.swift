#if SHADOW_SYNC_TESTING
import Foundation
import Security

enum CommandGraphSelfTests {
    private enum Failure: Error { case assertion }
    static func fixtureData() throws -> Data {
        let tools = try CommandGraphCatalog.Adapter.discoveryGit.paths.map { path -> PolicyWireValue in
            var code: SecStaticCode?, info: CFDictionary?
            guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
                  SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let values = info as? [String: Any], let hash = values[kSecCodeInfoUnique as String] as? Data else { throw Failure.assertion }
            return .object(["path": .string(path), "cdhash": .string(hash.map { String(format: "%02x", $0) }.joined())])
        }
        return try CustodyWire.encode(.object(["schema": .string("shadow-sync-command-graphs/v1"), "graphs": .array([
            .object(["adapter": .string("discovery-git/v1"), "architecture": .string("arm64"),
                     "system_build": .string("25Fixture"), "qualification_sha256": .string(String(repeating: "e", count: 64)),
                     "tools": .array(tools)])
        ])]), maximum: 65_536)
    }
    static func fixtureGraph() throws -> QualifiedCommandGraph {
        try QualifiedCommandGraph.testing(fixtureData(), kind: .discoveryGit, build: "25Fixture")
    }
    static func run(_ mode: String) throws {
        let data = try fixtureData()
        var parsed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var graphs = parsed["graphs"] as! [[String: Any]]
        var graph = graphs[0]
        var tools = graph["tools"] as! [[String: Any]]
        switch mode {
        case "valid":
            let catalog = try CommandGraphCatalog.decode(data)
            guard catalog.entries.count == 1,
                  try catalog.entry(kind: .discoveryGit, systemBuild: "25Fixture").tools.map(\.path) == CommandGraphCatalog.Adapter.discoveryGit.paths else { throw Failure.assertion }
            let launcher = try PublisherExecutableSnapshot.captureSystemGitLauncher()
            let strict = try? PublisherExecutableSnapshot.capture(path: "/usr/bin/git", owner: 0)
            guard (launcher.file.links == 1) == (strict != nil) else { throw Failure.assertion }
            _ = try fixtureGraph(); return
        case "unknown-build", "unknown-kind":
            do {
                _ = try QualifiedCommandGraph.testing(data, kind: mode == "unknown-kind" ? .launchctlRead : .discoveryGit,
                    build: mode == "unknown-build" ? "25Unknown" : "25Fixture")
            } catch { return }
            throw Failure.assertion
        case "empty":
            let empty = Data("{\"graphs\":[],\"schema\":\"shadow-sync-command-graphs/v1\"}".utf8)
            guard try CommandGraphCatalog.decode(empty).entries.isEmpty else { throw Failure.assertion }
            do { _ = try QualifiedCommandGraph.testing(empty, kind: .discoveryGit, build: "25Fixture") }
            catch { return }
            throw Failure.assertion
        case "wrong-cdhash": tools[1]["cdhash"] = String(repeating: "f", count: 40)
        case "wrong-path": tools[1]["path"] = "/bin/sh"
        case "missing-tool": tools.removeLast()
        case "wrong-architecture": graph["architecture"] = "x86_64"
        case "unknown-adapter": graph["adapter"] = "shell/v1"
        case "missing-receipt": graph["qualification_sha256"] = String(repeating: "0", count: 64)
        case "extra-key": graph["allow_any_tool"] = true
        case "duplicate-entry": graphs.append(graph)
        case "duplicate-key":
            let invalid = Data("{\"graphs\":[],\"graphs\":[],\"schema\":\"shadow-sync-command-graphs/v1\"}".utf8)
            do { _ = try CommandGraphCatalog.decode(invalid) } catch { return }
            throw Failure.assertion
        default: throw Failure.assertion
        }
        graph["tools"] = tools; graphs[0] = graph; parsed["graphs"] = graphs
        let modified = try JSONSerialization.data(withJSONObject: parsed, options: [.sortedKeys, .withoutEscapingSlashes])
        do { _ = try QualifiedCommandGraph.testing(modified, kind: .discoveryGit, build: "25Fixture") }
        catch { return }
        throw Failure.assertion
    }
}
#endif
