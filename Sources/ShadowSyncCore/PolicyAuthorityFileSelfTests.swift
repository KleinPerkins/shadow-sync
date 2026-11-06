#if SHADOW_SYNC_TESTING
import CryptoKit
import Darwin
import Foundation

public enum PolicyAuthorityFileSelfTestRunner {
    private enum Failure: Error { case assertion(String) }

    public static func runAll(onPass: (String) -> Void) throws {
        try RuntimeFixtureSession.withCase("POLICY-AUTHORITY-T01-stable-bounded-snapshot") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let data = Data("policy-authority-fixture\n".utf8)
            let path = try fixture.file("valid", data)
            let snapshot = try PolicyAuthorityFile.read(path: path, owner: geteuid(), maximumBytes: 128)
            try require(snapshot.bytes == data && snapshot.sha256 == SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined(), "snapshot bytes or digest")
            try snapshot.revalidate()
            try fixture.remove()
        }
        onPass("POLICY-AUTHORITY-T01-stable-bounded-snapshot")
        try RuntimeFixtureSession.withCase("POLICY-AUTHORITY-T02-invalid-locators-and-bounds") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let data = Data("policy-authority-fixture\n".utf8)
            let path = try fixture.file("valid", data)
            for bad in ["", "/", "relative", path + "/", fixture.path + "//valid",
                        fixture.path + "/./valid", fixture.path + "/x/../valid",
                        path + "\0", path + "\n", path + "\\suffix",
                        "/" + String(repeating: "a", count: 4096)] {
                try refuse { _ = try PolicyAuthorityFile.read(path: bad, owner: geteuid(), maximumBytes: 128) }
            }
            for size in [0, -1, 1_048_577] {
                try refuse { _ = try PolicyAuthorityFile.read(path: path, owner: geteuid(), maximumBytes: size) }
            }
            try fixture.remove()
        }
        onPass("POLICY-AUTHORITY-T02-invalid-locators-and-bounds")
        try RuntimeFixtureSession.withCase("POLICY-AUTHORITY-T03-empty-oversized-and-maximum") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let data = Data("policy-authority-fixture\n".utf8)
            for size in [0, 129] {
                let bad = try fixture.file("size-\(size)", Data(repeating: 65, count: size))
                try refuse { _ = try PolicyAuthorityFile.read(path: bad, owner: geteuid(), maximumBytes: 128) }
            }
            let largest = try fixture.file("maximum", Data(repeating: 66, count: 1_048_576))
            try require(try PolicyAuthorityFile.read(path: largest, owner: geteuid(), maximumBytes: 1_048_576)
                .bytes.count == 1_048_576, "maximum snapshot")
            try fixture.remove()
        }
        onPass("POLICY-AUTHORITY-T03-empty-oversized-and-maximum")
        try RuntimeFixtureSession.withCase("POLICY-AUTHORITY-T04-write-permissions-and-hardlinks") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let data = Data("policy-authority-fixture\n".utf8)
            let path = try fixture.file("valid", data)
            let mode = try fixture.file("mode", data)
            for permissions: mode_t in [0o620, 0o602] {
                try require(chmod(mode, permissions) == 0, "mode fixture")
                try refuse { _ = try PolicyAuthorityFile.read(path: mode, owner: geteuid(), maximumBytes: 128) }
            }
            try require(chmod(mode, 0o600) == 0, "restore mode fixture")
            let linked = fixture.path + "/linked"
            try require(link(path, linked) == 0, "hardlink fixture")
            try refuse { _ = try PolicyAuthorityFile.read(path: linked, owner: geteuid(), maximumBytes: 128) }
            try require(unlink(linked) == 0, "remove hardlink fixture")
            try fixture.remove()
        }
        onPass("POLICY-AUTHORITY-T04-write-permissions-and-hardlinks")
        try RuntimeFixtureSession.withCase("POLICY-AUTHORITY-T05-symlink-directory-and-fifo-refusal") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let data = Data("policy-authority-fixture\n".utf8)
            let path = try fixture.file("valid", data)
            let symbolic = fixture.path + "/symbolic"
            try require(symlink(path, symbolic) == 0, "symlink fixture")
            let fifo = fixture.path + "/fifo"
            try require(mkfifo(fifo, 0o600) == 0, "fifo fixture")
            let start = DispatchTime.now().uptimeNanoseconds
            for bad in [symbolic, fifo, fixture.path] {
                try refuse { _ = try PolicyAuthorityFile.read(path: bad, owner: geteuid(), maximumBytes: 128) }
            }
            try require(DispatchTime.now().uptimeNanoseconds - start < 2_000_000_000,
                        "nonregular input blocked")
            try fixture.remove()
        }
        onPass("POLICY-AUTHORITY-T05-symlink-directory-and-fifo-refusal")
        try RuntimeFixtureSession.withCase("POLICY-AUTHORITY-T06-ancestor-symlink-and-permissions") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let data = Data("policy-authority-fixture\n".utf8)
            let directory = fixture.path + "/parent"
            try require(mkdir(directory, 0o700) == 0, "parent fixture")
            let nested = try fixture.file("parent/input", data)
            let alias = fixture.path + "/alias"
            try require(symlink(directory, alias) == 0, "ancestor symlink fixture")
            try refuse { _ = try PolicyAuthorityFile.read(path: alias + "/input", owner: geteuid(), maximumBytes: 128) }
            for permissions: mode_t in [0o770, 0o707, 0o1777] {
                try require(chmod(directory, permissions) == 0, "ancestor mode fixture")
                try refuse { _ = try PolicyAuthorityFile.read(path: nested, owner: geteuid(), maximumBytes: 128) }
            }
            try require(chmod(directory, 0o700) == 0, "restore ancestor mode")
            try fixture.remove()
        }
        onPass("POLICY-AUTHORITY-T06-ancestor-symlink-and-permissions")
        try RuntimeFixtureSession.withCase("POLICY-AUTHORITY-T07-content-and-inode-replacement") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let data = Data("policy-authority-fixture\n".utf8)
            let path = try fixture.file("valid", data)
            let mutable = try fixture.file("mutable", data)
            let before = try PolicyAuthorityFile.read(path: mutable, owner: geteuid(), maximumBytes: 128)
            try Data("changed-policy\n".utf8).write(to: URL(fileURLWithPath: mutable))
            try refuse { try before.revalidate() }
            let replacement = try fixture.file("replacement", data)
            let sameBytes = try PolicyAuthorityFile.read(path: path, owner: geteuid(), maximumBytes: 128)
            try require(rename(replacement, path) == 0, "replace inode fixture")
            try refuse { try sameBytes.revalidate() }
            try fixture.remove()
        }
        onPass("POLICY-AUTHORITY-T07-content-and-inode-replacement")
        try RuntimeFixtureSession.withCase("POLICY-AUTHORITY-T08-parent-replacement-around-same-file") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let data = Data("policy-authority-fixture\n".utf8)
            let directory = fixture.path + "/parent"
            try require(mkdir(directory, 0o700) == 0, "parent fixture")
            let nested = try fixture.file("parent/input", data)
            let oldParent = fixture.path + "/previous-parent"
            let beforeParent = try PolicyAuthorityFile.read(path: nested, owner: geteuid(), maximumBytes: 128)
            var original = stat(), moved = stat()
            try require(lstat(nested, &original) == 0, "original inode fixture")
            try require(rename(directory, oldParent) == 0 && mkdir(directory, 0o700) == 0,
                        "parent replacement fixture")
            try require(rename(oldParent + "/input", nested) == 0 && lstat(nested, &moved) == 0,
                        "preserve payload inode fixture")
            try require(original.st_ino == moved.st_ino && original.st_dev == moved.st_dev,
                        "payload inode changed unexpectedly")
            try refuse { try beforeParent.revalidate() }
            try fixture.remove()
        }
        onPass("POLICY-AUTHORITY-T08-parent-replacement-around-same-file")
        try RuntimeFixtureSession.withCase("POLICY-AUTHORITY-T09-file-acl-mutation-grants") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let data = Data("policy-authority-fixture\n".utf8)
            let aclFile = try fixture.file("acl-file", data)
            for permission in ["write", "append", "delete", "writeattr", "writeextattr", "writesecurity", "chown"] {
                try fixture.setACL(aclFile, rule: "everyone allow \(permission)")
                var info = stat()
                try require(lstat(aclFile, &info) == 0 && info.st_mode & 0o777 == 0o600,
                            "ACL must leave POSIX mode unchanged")
                try refuse { _ = try PolicyAuthorityFile.read(path: aclFile, owner: geteuid(), maximumBytes: 128) }
                try fixture.clearACL(aclFile)
            }
            try fixture.remove()
        }
        onPass("POLICY-AUTHORITY-T09-file-acl-mutation-grants")
        try RuntimeFixtureSession.withCase("POLICY-AUTHORITY-T10-parent-acl-mutation-grants") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let data = Data("policy-authority-fixture\n".utf8)
            let directory = fixture.path + "/parent"
            try require(mkdir(directory, 0o700) == 0, "parent fixture")
            let nested = try fixture.file("parent/input", data)
            for permission in ["add_file", "add_subdirectory", "delete_child", "delete", "writesecurity"] {
                try fixture.setACL(directory, rule: "everyone allow \(permission)")
                try refuse { _ = try PolicyAuthorityFile.read(path: nested, owner: geteuid(), maximumBytes: 128) }
                try fixture.clearACL(directory)
            }
            try fixture.remove()
        }
        onPass("POLICY-AUTHORITY-T10-parent-acl-mutation-grants")
        try RuntimeFixtureSession.withCase("POLICY-AUTHORITY-T11-safe-acls-and-acl-drift") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let data = Data("policy-authority-fixture\n".utf8)
            let directory = fixture.path + "/parent"
            try require(mkdir(directory, 0o700) == 0, "parent fixture")
            let nested = try fixture.file("parent/input", data)
            let aclFile = try fixture.file("acl-file", data)
            try fixture.setACL(directory, rule: "everyone deny delete")
            try fixture.setACL(aclFile, rule: "everyone allow read,readattr,readextattr,readsecurity")
            try PolicyAuthorityFile.read(path: nested, owner: geteuid(), maximumBytes: 128).revalidate()
            try PolicyAuthorityFile.read(path: aclFile, owner: geteuid(), maximumBytes: 128).revalidate()
            let stableParent = try PolicyAuthorityFile.read(path: nested, owner: geteuid(), maximumBytes: 128)
            try fixture.clearACL(directory)
            try refuse { try stableParent.revalidate() }
            let stableFile = try PolicyAuthorityFile.read(path: aclFile, owner: geteuid(), maximumBytes: 128)
            try fixture.clearACL(aclFile)
            try refuse { try stableFile.revalidate() }
            try fixture.remove()
        }
        onPass("POLICY-AUTHORITY-T11-safe-acls-and-acl-drift")
        try RuntimeFixtureSession.withCase("POLICY-AUTHORITY-T12-byte-separated-ancestor-validation") {
            let fixture = try Fixture()
            defer { try? fixture.remove() }
            let data = Data("policy-authority-fixture\n".utf8)
            let unicodeDirectory = fixture.path + "/unicode-parent"
            try require(mkdir(unicodeDirectory, 0o700) == 0, "unicode parent fixture")
            let unicodeFile = try fixture.file("unicode-parent/\u{301}input", data)
            try require(try PolicyAuthorityFile.read(path: unicodeFile, owner: geteuid(), maximumBytes: 128).bytes == data,
                        "valid combining-mark filename refused")
            let unicodeAlias = fixture.path + "/unicode-alias"
            try require(symlink(unicodeDirectory, unicodeAlias) == 0, "unicode symlink fixture")
            try refuse { _ = try PolicyAuthorityFile.read(path: unicodeAlias + "/\u{301}input", owner: geteuid(), maximumBytes: 128) }
            try require(chmod(unicodeDirectory, 0o777) == 0, "unicode parent mode")
            try refuse { _ = try PolicyAuthorityFile.read(path: unicodeFile, owner: geteuid(), maximumBytes: 128) }
            try require(chmod(unicodeDirectory, 0o700) == 0, "restore unicode parent mode")
            let unicodeBackslash = try fixture.file("back\\\u{301}slash", data)
            try refuse { _ = try PolicyAuthorityFile.read(path: unicodeBackslash, owner: geteuid(), maximumBytes: 128) }
            try fixture.remove()
        }
        onPass("POLICY-AUTHORITY-T12-byte-separated-ancestor-validation")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.assertion(message) }
    }

    private static func refuse(_ operation: () throws -> Void) throws {
        do { try operation(); throw Failure.assertion("unsafe authority file accepted") }
        catch PolicyAuthorityFileError.unavailable {
            try require(String(describing: PolicyAuthorityFileError.unavailable)
                == "Repository policy configuration is unavailable.", "private diagnostic")
        }
    }

    private final class Fixture {
        let path: String
        let device: Int32
        let inode: UInt64
        private var removed = false
        private var aclPaths: Set<String> = []

        init() throws {
            var template = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-policy-authority-") + "XXXXXX").utf8CString)
            guard let result = mkdtemp(&template) else { throw Failure.assertion("fixture create") }
            path = String(cString: result)
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == geteuid(),
                  info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else {
                throw Failure.assertion("fixture identity")
            }
            device = info.st_dev; inode = info.st_ino
        }

        func file(_ name: String, _ data: Data) throws -> String {
            let result = path + "/" + name
            try data.write(to: URL(fileURLWithPath: result), options: .withoutOverwriting)
            try require(chmod(result, 0o600) == 0, "fixture file mode")
            return result
        }

        func setACL(_ target: String, rule: String) throws {
            // Test-owned paths and fixed rule literals only. No shell or host
            // configuration is involved; the command completes before testing.
            try require(target.hasPrefix(path + "/"), "ACL fixture escaped root")
            aclPaths.insert(target)
            let directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw Failure.assertion("ACL scratch open") }
            defer { close(directory) }
            let account = EffectiveAccount(uid: geteuid(), username: "fixture-account", homeDirectory: path)
            let result = try ClosedProcessRunner(outputLimit: 4096).run(
                command: ClosedProcessCommand(executable: "/bin/chmod", arguments: ["+a", rule, target]),
                environment: ClosedProcessRunner.environment(account: account),
                workingDirectoryDescriptor: directory, account: account,
                timeout: 2, cancellation: CancellationToken())
            try require(result.status == 0 && !result.timedOut && !result.cancelled
                && !result.stdoutTruncated && !result.stderrTruncated, "ACL fixture creation")
            try require(waitpid(result.processID, nil, WNOHANG) == -1 && errno == ECHILD,
                        "ACL fixture child was not reaped")
        }

        func clearACL(_ target: String) throws {
            guard let empty = acl_init(0) else { throw Failure.assertion("empty ACL fixture") }
            defer { acl_free(UnsafeMutableRawPointer(empty)) }
            try require(acl_set_link_np(target, ACL_TYPE_EXTENDED, empty) == 0,
                        "ACL fixture clear")
            aclPaths.remove(target)
        }

        func remove() throws {
            if removed { return }
            var info = stat()
            try require(lstat(path, &info) == 0 && info.st_dev == device && info.st_ino == inode
                && info.st_uid == geteuid() && info.st_mode & S_IFMT == S_IFDIR,
                "refuse changed cleanup root")
            for target in aclPaths.sorted() { try clearACL(target) }
            try FileManager.default.removeItem(atPath: path)
            removed = true
        }
    }
}
#endif
