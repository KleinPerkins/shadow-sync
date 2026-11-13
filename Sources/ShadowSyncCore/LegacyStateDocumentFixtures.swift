#if SHADOW_SYNC_TESTING
import Foundation

enum LegacyStateDocumentFixtures {
    struct Failure: Error { let message: String }
    private static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure(message: message) }
    }
    private static func bytes(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func record(_ id: String = "owner/example") -> [String: Any] {
        ["repositoryID": id, "canonicalRoot": "/tmp/legacy-observation/../example",
         "rootIdentity": ["device": 0, "inode": 1],
         "commonDirectoryIdentity": ["device": 2, "inode": 3], "updatedAt": "opaque historical value"]
    }
    private static func authority(_ records: [[String: Any]]? = nil) -> [String: Any] {
        ["schema": LegacyStateDocumentObserver.authoritySchema, "revision": 0, "records": records ?? [record()]]
    }
    private static func entry(_ id: String = "owner/example", root: String = "fixture-root",
                              components: [String] = ["example"]) -> [String: Any] {
        ["repositoryID": id, "locator": ["governedRoot": root, "components": components]]
    }
    private static func selection(_ entries: [[String: Any]]? = nil) -> [String: Any] {
        ["schema": LegacyStateDocumentObserver.selectionSchema,
         "documentID": "abcdef00-0000-4000-8000-000000000001", "revision": 1, "entries": entries ?? [entry()]]
    }
    private static func refuses(_ input: Data) throws {
        let result = LegacyStateDocumentObserver.observe(input)
        guard case .refused(let retained) = result else { throw Failure(message: "legacy observation accepted malformed data") }
        try check(retained == input && result.originalBytes == input, "refusal changed original bytes")
    }
    private static func accepts(_ input: Data, authority expectedAuthority: Bool) throws {
        let result = LegacyStateDocumentObserver.observe(input)
        switch result {
        case .authority: try check(expectedAuthority, "wrong observation kind")
        case .selection: try check(!expectedAuthority, "wrong observation kind")
        case .refused: throw Failure(message: "legacy observation refused source-shaped fixture")
        }
        try check(result.originalBytes == input, "observation changed original bytes")
    }
    static func authorityValues() throws {
        var r = record("owner/z"); r["rootIdentity"] = ["device": Int64.max, "inode": 0]
        let input = try bytes(authority([r, record("owner/a")]))
        guard case .authority(let observed) = LegacyStateDocumentObserver.observe(input) else {
            throw Failure(message: "source authority document refused")
        }
        try check(observed.revision == 0 && observed.records.map(\.repositoryID) == ["owner/z", "owner/a"], "authority order/revision changed")
        try check(observed.records[0].canonicalRoot == "/tmp/legacy-observation/../example"
            && observed.records[0].updatedAt == "opaque historical value"
            && observed.records[0].rootIdentity.device == UInt64(Int64.max), "authority source semantics changed")
        try accepts(try bytes(authority([])), authority: true)
        var a = authority(); a["revision"] = Int64.max
        try accepts(try bytes(a), authority: true)
    }
    static func selectionValues() throws {
        let local = "local-" + String(repeating: "a", count: 64)
        let input = try bytes(selection([entry(local, components: ["a", "b", "c", "d"])]))
        guard case .selection(let observed) = LegacyStateDocumentObserver.observe(input) else {
            throw Failure(message: "source selection document refused")
        }
        try check(observed.revision == 1 && observed.entries[0].repositoryID == local
            && observed.entries[0].components == ["a", "b", "c", "d"], "selection values changed")
        var s = selection([]); s["revision"] = UInt64.max
        try accepts(try bytes(s), authority: false)
    }
    static func originalBytes() throws {
        for (object, isAuthority) in [(authority(), true), (selection(), false)] {
            let compact = String(decoding: try bytes(object), as: UTF8.self)
            // Valid JSON formatting/escape choices are not canonicalized away.
            let input = Data((" \n\t" + compact.replacingOccurrences(of: "owner/", with: "owner\\u002f") + "\r\n ").utf8)
            try accepts(input, authority: isAuthority)
        }
        let decomposed = "e\u{301}"
        let input = try bytes(selection([entry(components: [decomposed])]))
        guard case .selection(let observed) = LegacyStateDocumentObserver.observe(input) else { throw Failure(message: "decomposed component refused") }
        try check(Array(observed.entries[0].components[0].utf8) == Array(decomposed.utf8), "raw component was normalized")
        try check(observed.originalBytes == input, "decomposed original changed")
        let longDecomposed = String(repeating: "e\u{301}", count: 86)
        let root = "e\u{301}"
        let longInput = try bytes(selection([entry(root: root, components: [longDecomposed])]))
        guard case .selection(let longObserved) = LegacyStateDocumentObserver.observe(longInput) else {
            throw Failure(message: "historical normalized component length refused")
        }
        try check(longDecomposed.utf8.count == 258
            && longDecomposed.precomposedStringWithCanonicalMapping.utf8.count == 172,
            "normalized length fixture lost boundary")
        try check(Array(longObserved.entries[0].components[0].utf8) == Array(longDecomposed.utf8)
            && Array(longObserved.entries[0].governedRoot.utf8) == Array(root.utf8)
            && longObserved.originalBytes == longInput, "historical comparison rewrote raw values")
    }
    static func schemas() throws {
        for original in [authority(), selection()] {
            for schema in ["shadow-sync-repository-authorities/v1", "shadow-sync-repository-selection-preferences/v1",
                           "dev-main-sync-repository-authorities/v2", "dev-main-sync-repository-selection-preferences/v2", "unknown/v1"] {
                var changed = original; changed["schema"] = schema; try refuses(try bytes(changed))
            }
            var changed = original; changed["schema"] = true; try refuses(try bytes(changed))
        }
    }
    static func closedFields() throws {
        for original in [authority(), selection()] {
            var unknown = original; unknown["future"] = ["retained": true]; try refuses(try bytes(unknown))
            for key in original.keys {
                var missing = original; missing.removeValue(forKey: key); try refuses(try bytes(missing))
            }
        }
        for key in record().keys {
            var r = record(); r.removeValue(forKey: key); try refuses(try bytes(authority([r])))
        }
        var r = record(); r["future"] = 1; try refuses(try bytes(authority([r])))
        r = record(); r["rootIdentity"] = ["device": 1, "inode": 2, "future": 3]; try refuses(try bytes(authority([r])))
        r = record(); r["commonDirectoryIdentity"] = ["inode": 2]; try refuses(try bytes(authority([r])))
        var e = entry(); e["future"] = 1; try refuses(try bytes(selection([e])))
        e = entry(); e["locator"] = ["governedRoot": "fixture-root", "components": ["a"], "future": 1]
        try refuses(try bytes(selection([e])))
        e = entry(); e.removeValue(forKey: "repositoryID"); try refuses(try bytes(selection([e])))
        e = entry(); e["locator"] = ["components": ["a"]]; try refuses(try bytes(selection([e])))
    }
    static func duplicateKeys() throws {
        for object in [authority(), selection()] {
            let original = String(decoding: try bytes(object), as: UTF8.self)
            for (key, extra) in [("schema", "\"schema\":null,"), ("schema", "\"sch\\u0065ma\":null,"),
                                 ("repositoryID", "\"repositoryID\":null,")] {
                let changed = original.replacingOccurrences(of: "\"\(key)\":", with: extra + "\"\(key)\":")
                try refuses(Data(changed.utf8))
            }
        }
        for (object, key) in [(authority(), "device"), (authority(), "inode"), (selection(), "governedRoot"), (selection(), "components")] {
            let original = String(decoding: try bytes(object), as: UTF8.self)
            try refuses(Data(original.replacingOccurrences(of: "\"\(key)\":", with: "\"\(key)\":null,\"\(key)\":").utf8))
        }
    }
    static func integerShapes() throws {
        for original in [authority(), selection()] {
            let text = String(decoding: try bytes(original), as: UTF8.self)
            let token = original["revision"] as! Int
            for invalid in ["true", "false", "null", "-1", "1.0", "1e0", "01", "18446744073709551616", "\"1\""] {
                try refuses(Data(text.replacingOccurrences(of: "\"revision\":\(token)", with: "\"revision\":\(invalid)").utf8))
            }
        }
        for value in [true, false, -1, "1", NSNull(), UInt64.max] as [Any] {
            var r = record(); r["rootIdentity"] = ["device": value, "inode": 2]
            try refuses(try bytes(authority([r])))
            r = record(); r["commonDirectoryIdentity"] = ["device": 2, "inode": value]
            try refuses(try bytes(authority([r])))
        }
        var a = authority(); a["revision"] = UInt64.max; try refuses(try bytes(a))
        var s = selection(); s["revision"] = 0; try refuses(try bytes(s))
    }
    static func authorityRecords() throws {
        for id in ["Owner/example", "owner", "owner/example/other", "owner/..", "owner/ex ample", "local-" + String(repeating: "a", count: 64)] {
            try refuses(try bytes(authority([record(id)])))
        }
        for value in ["relative", "", "/tmp/a\n", "/tmp/a\r", "/tmp/a\0", 1] as [Any] {
            var r = record(); r["canonicalRoot"] = value; try refuses(try bytes(authority([r])))
        }
        for value in ["", 1, NSNull()] as [Any] {
            var r = record(); r["updatedAt"] = value; try refuses(try bytes(authority([r])))
        }
        try refuses(try bytes(authority([record(), record()])))
        var a = authority(); a["records"] = ["not-a-record"]; try refuses(try bytes(a))
        var r = record(); r["rootIdentity"] = [1, 2]; try refuses(try bytes(authority([r])))
    }
    static func selectionLocators() throws {
        for components in [[], ["."], [".."], [".hidden"], ["a/b"], ["a\\b"], ["a\0"], ["a\n"],
                           ["a", "b", "c", "d", "e"], [String(repeating: "a", count: 256)]] {
            try refuses(try bytes(selection([entry(components: components)])))
        }
        for root in ["", "/absolute", "a\\b", "a\0", "a\n", String(repeating: "a", count: 129)] {
            try refuses(try bytes(selection([entry(root: root)])))
        }
        // Root is a historical lexical policy key, not a resolved filesystem path.
        try accepts(try bytes(selection([entry(root: "policy/key", components: [String(repeating: "a", count: 255)])])), authority: false)
        try accepts(try bytes(selection([entry(root: String(repeating: "a", count: 128))])), authority: false)
        for id in ["Owner/example", "owner", "owner/a..b", "owner/ex ample", "local-ab", "local-" + String(repeating: "A", count: 64)] {
            try refuses(try bytes(selection([entry(id)])))
        }
        var s = selection(); s["documentID"] = "ABCDEF00-0000-4000-8000-000000000001"; try refuses(try bytes(s))
        s["documentID"] = "not-a-uuid"; try refuses(try bytes(s))
        var e = entry(); e["locator"] = ["governedRoot": "fixture-root", "components": [1]]
        try refuses(try bytes(selection([e])))
    }
    static func selectionInvariants() throws {
        try accepts(try bytes(selection([entry("owner/a", components: ["a"]), entry("owner/z", components: ["z"])])), authority: false)
        try refuses(try bytes(selection([entry("owner/z", components: ["z"]), entry("owner/a", components: ["a"])])))
        try refuses(try bytes(selection([entry("owner/a", components: ["a"]), entry("owner/a", components: ["b"])])))
        try refuses(try bytes(selection([entry("owner/a"), entry("owner/b")])))
        try refuses(try bytes(selection([entry("owner/a", components: ["e\u{301}"]), entry("owner/b", components: ["é"])])))
        try refuses(try bytes(selection([entry("owner/a", root: "e\u{301}"), entry("owner/b", root: "é")])))
        try accepts(try bytes(selection([entry("owner/a", root: "e\u{301}", components: ["a"]),
            entry("owner/b", root: "é", components: ["b"])])), authority: false)
        try refuses(try bytes(selection([entry(components: [String(repeating: "e\u{301}", count: 128)])])))
        // Root syntax kept its historical raw-byte bound, unlike components.
        try refuses(try bytes(selection([entry(root: String(repeating: "e\u{301}", count: 43))])))
    }
    static func sourceBounds() throws {
        for (object, isAuthority) in [(authority(), true), (selection(), false)] {
            var input = try bytes(object)
            input.append(Data(repeating: 32, count: LegacyStateDocumentObserver.maximumBytes - input.count))
            try accepts(input, authority: isAuthority)
            input.append(32); try refuses(input)
        }
        let records = (0..<257).map { record(String(format: "owner/repo%03d", $0)) }
        let entries = (0..<257).map { entry(String(format: "owner/repo%03d", $0), components: ["repo\($0)"]) }
        try accepts(try bytes(authority(records)), authority: true)
        try accepts(try bytes(selection(entries)), authority: false)
        let array = Data(("[" + Array(repeating: "0", count: 257).joined(separator: ",") + "]").utf8)
        for profile in [PolicyWireParser.Profile.wire, .configuration, .bundleLayout, .discoveryCustody] {
            var parser = try PolicyWireParser(array, profile: profile)
            do { _ = try parser.parse() }
            catch is PolicyProtocolError { continue }
            throw Failure(message: "existing parser profile array bound widened")
        }
    }
    static func opaqueRefusals() throws {
        for input in [Data(), Data([0xff]), Data([0, 1, 2]), Data("null".utf8), Data("[]".utf8),
                      Data("{\"opaque\":\"preserve me\"}".utf8), Data("{\"schema\":\"unknown/v9\",\"future\":[true]}".utf8)] {
            try refuses(input)
        }
    }
}
#endif
