#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

public enum M5SelfTestRunner {
    public static func runAll(
        testRoot: String,
        onPass: (String) -> Void = { _ in }
    ) throws -> [String] {
        _ = try TestIsolation.validateRoot(testRoot)
        let tests: [(String, () throws -> Void)] = [
            ("m5-secure-log-open-success", {
                try testSecureLogOpenSuccess(root: testRoot)
            }),
            ("m5-secure-log-open-refusals", {
                try testSecureLogOpenRefusals(root: testRoot)
            }),
            ("m5-secure-log-open-identity-change", {
                try testSecureLogIdentityChange(root: testRoot)
            }),
            ("m5-secure-log-open-default-app-failure", {
                try testSecureLogOpenFailure(root: testRoot)
            }),
        ]
        var completed: [String] = []
        for (name, test) in tests {
            do {
                try test()
                completed.append(name)
                onPass(name)
            } catch {
                throw M5SelfTestError.failed(name, String(describing: error))
            }
        }
        return completed
    }

    private static func testSecureLogOpenSuccess(root: String) throws {
        let fixture = try M5TemporaryDirectory(parent: root, label: "log-success")
        let state = try SecureStateDirectory.testingCreateDirectory(.isolated(root: fixture.path))
        try write(Data("safe log\n".utf8), state: state)
        var openedPath: String?
        try CurrentLogOpener.testingOpen(state: state) { url in
            openedPath = url.path
            return true
        }
        try check(
            openedPath == fixture.path + "/state/shadow-sync/latest.log",
            "validated log opener received the wrong path"
        )
    }

    private static func testSecureLogOpenRefusals(root: String) throws {
        try refusalFixture(root: root, label: "log-symlink") { state, fixture in
            let target = fixture.path + "/target.log"
            try Data("target\n".utf8).write(to: URL(fileURLWithPath: target))
            guard chmod(target, 0o600) == 0,
                  symlink(target, state.path + "/latest.log") == 0 else {
                throw M5SelfTestError.systemCall("prepare symlink log", errno)
            }
        }
        try refusalFixture(root: root, label: "log-hardlink") { state, fixture in
            try write(Data("linked\n".utf8), state: state)
            guard link(
                state.path + "/latest.log",
                fixture.path + "/second-link"
            ) == 0 else {
                throw M5SelfTestError.systemCall("prepare hardlinked log", errno)
            }
        }
        try refusalFixture(
            root: root,
            label: "log-wrong-owner",
            expectedUID: geteuid() &+ 1
        ) { state, _ in
            try write(Data("owned\n".utf8), state: state)
        }
        try refusalFixture(root: root, label: "log-nonregular") { state, _ in
            guard mkdir(state.path + "/latest.log", 0o700) == 0 else {
                throw M5SelfTestError.systemCall("prepare nonregular log", errno)
            }
        }
        try refusalFixture(
            root: root,
            label: "log-oversize",
            maximumBytes: 8
        ) { state, _ in
            try write(Data("123456789".utf8), state: state)
        }
    }

    private static func refusalFixture(
        root: String,
        label: String,
        expectedUID: uid_t? = nil,
        maximumBytes: Int64 = CurrentLogOpener.maximumBytes,
        prepare: (SecureStateDirectory, M5TemporaryDirectory) throws -> Void
    ) throws {
        let fixture = try M5TemporaryDirectory(parent: root, label: label)
        let state = try SecureStateDirectory.testingCreateDirectory(.isolated(root: fixture.path))
        try prepare(state, fixture)
        var openerCalls = 0
        do {
            try CurrentLogOpener.testingOpen(
                state: state,
                expectedUID: expectedUID,
                maximumBytes: maximumBytes
            ) { _ in
                openerCalls += 1
                return true
            }
            throw M5SelfTestError.message("\(label) was accepted")
        } catch is M5SelfTestError {
            throw errorFromCurrentCatch()
        } catch {
            try check(openerCalls == 0, "\(label) reached the default-app opener")
        }
    }

    private static func testSecureLogIdentityChange(root: String) throws {
        let fixture = try M5TemporaryDirectory(parent: root, label: "log-change")
        let state = try SecureStateDirectory.testingCreateDirectory(.isolated(root: fixture.path))
        try write(Data("original\n".utf8), state: state)
        var openerCalls = 0
        do {
            try CurrentLogOpener.testingOpen(state: state) { _ in
                openerCalls += 1
                let current = state.path + "/latest.log"
                let moved = state.path + "/prior.log"
                guard rename(current, moved) == 0 else {
                    return false
                }
                let replacement = Data("replacement\n".utf8)
                do {
                    try replacement.write(to: URL(fileURLWithPath: current))
                    guard chmod(current, 0o600) == 0 else {
                        return false
                    }
                } catch {
                    return false
                }
                return true
            }
            throw M5SelfTestError.message("changed log identity was accepted")
        } catch is M5SelfTestError {
            throw errorFromCurrentCatch()
        } catch {
            try check(openerCalls == 1, "identity-change fixture did not reach opener")
        }
    }

    private static func testSecureLogOpenFailure(root: String) throws {
        let fixture = try M5TemporaryDirectory(parent: root, label: "log-open-failure")
        let state = try SecureStateDirectory.testingCreateDirectory(.isolated(root: fixture.path))
        try write(Data("safe log\n".utf8), state: state)
        var openerCalls = 0
        do {
            try CurrentLogOpener.testingOpen(state: state) { _ in
                openerCalls += 1
                return false
            }
            throw M5SelfTestError.message("default-app open failure was accepted")
        } catch is M5SelfTestError {
            throw errorFromCurrentCatch()
        } catch let error as CurrentLogOpenError {
            try check(error.description.contains("did not open"), "wrong open-failure result")
            try check(openerCalls == 1, "default-app opener call count changed")
        }
    }

    private static func write(
        _ data: Data,
        state: SecureStateDirectory
    ) throws {
        let descriptor = try state.openRegularFile(
            named: "latest.log",
            flags: O_WRONLY | O_TRUNC,
            create: true
        )
        defer { close(descriptor) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw M5SelfTestError.systemCall("write log fixture", errno)
                }
                offset += count
            }
        }
    }

    private static func check(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw M5SelfTestError.message(message)
        }
    }

    private static func errorFromCurrentCatch() -> M5SelfTestError {
        .message("an expected refusal assertion escaped its fixture")
    }
}

private final class M5TemporaryDirectory {
    let path: String

    init(parent: String, label: String) throws {
        path = parent + "/m5-\(label)-\(RunIdentity.make())"
        guard mkdir(path, 0o700) == 0 else {
            throw M5SelfTestError.systemCall("mkdir \(label)", errno)
        }
    }

    deinit {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private enum M5SelfTestError: Error, CustomStringConvertible {
    case failed(String, String)
    case message(String)
    case systemCall(String, Int32)

    var description: String {
        switch self {
        case let .failed(name, detail):
            return "\(name): \(detail)"
        case let .message(detail):
            return detail
        case let .systemCall(name, code):
            return "\(name): \(String(cString: strerror(code)))"
        }
    }
}
#endif
