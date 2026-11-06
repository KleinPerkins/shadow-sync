#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

public enum PolicyTransportSelfTestRunner {
    private enum Failure: Error { case assertion(String) }
    private static let binding = String(repeating: "b", count: 64)
    private static let policy = String(repeating: "c", count: 64)
    private static let module = String(repeating: "d", count: 64)

    public static func runAll(onPass: (String) -> Void) throws {
        guard let interpreter = ProcessInfo.processInfo.environment["SHADOW_SYNC_TEST_POLICY_PYTHON"],
              interpreter.hasPrefix("/"), !interpreter.contains("\n"), !interpreter.contains("\0") else {
            throw Failure.assertion("qualified test interpreter is required")
        }
        let paths = ["/synthetic-policy-target/private-a", "/synthetic-policy-target/private-b"]
        try RuntimeFixtureSession.withCase("POLICY-TRANSPORT-T01-native-isolation-and-bound-response") {
            let fixture = try Fixture(interpreter: interpreter)
            defer { try? fixture.remove() }
            var authorityReads = 0
            let audit = CommandAudit()
            let result = try fixture.transport(mode: "valid", authority: { authorityReads += 1 })
                .classify(candidates: paths, scratchDescriptor: fixture.directory, timeout: 2,
                          cancellation: CancellationToken(), audit: audit)
            try require(result.count == 2 && result[0].allowsCandidateAccess
                && !result[1].allowsCandidateAccess && authorityReads == 2, "allow/deny or revalidation")
            try require(audit.invocations.count == 1
                && audit.invocations[0].arguments == ["isolated-policy-classification"]
                && audit.invocations[0].spawnArguments.prefix(5) == [interpreter, "-I", "-S", "-B", "-c"]
                && !audit.invocations[0].spawnArguments.joined().contains("private-a"), "private argv")
            try fixture.remove()
        }
        onPass("POLICY-TRANSPORT-T01-native-isolation-and-bound-response")
        try RuntimeFixtureSession.withCase("POLICY-TRANSPORT-T02-whole-request-before-authority") {
            let fixture = try Fixture(interpreter: interpreter)
            defer { try? fixture.remove() }
            for bad in [[], ["relative"], ["/valid", "/bad/../value"], ["/same", "/same"]] {
                var reads = 0
                let audit = CommandAudit()
                try refuse {
                    _ = try fixture.transport(mode: "valid", authority: { reads += 1 })
                        .classify(candidates: bad, scratchDescriptor: -1, timeout: 2,
                                  cancellation: CancellationToken(), audit: audit)
                }
                try require(reads == 0 && audit.invocations.isEmpty, "invalid batch reached authority or process")
            }
            try fixture.remove()
        }
        onPass("POLICY-TRANSPORT-T02-whole-request-before-authority")
        try RuntimeFixtureSession.withCase("POLICY-TRANSPORT-T03-before-and-after-authority-drift") {
            let fixture = try Fixture(interpreter: interpreter)
            defer { try? fixture.remove() }
            for failAt in [1, 2] {
                var reads = 0
                let audit = CommandAudit()
                try refuse {
                    _ = try fixture.transport(mode: "valid", authority: {
                        reads += 1
                        if reads == failAt { throw Failure.assertion("private authority fixture") }
                    }).classify(candidates: paths, scratchDescriptor: fixture.directory, timeout: 2,
                                cancellation: CancellationToken(), audit: audit)
                }
                try require(reads == failAt && audit.invocations.count == failAt - 1,
                            "authority mismatch did not close at the expected boundary")
            }
            try fixture.remove()
        }
        onPass("POLICY-TRANSPORT-T03-before-and-after-authority-drift")
        try RuntimeFixtureSession.withCase("POLICY-TRANSPORT-T04-process-and-protocol-refusals") {
            let fixture = try Fixture(interpreter: interpreter)
            defer { try? fixture.remove() }
            for mode in ["stderr", "nonzero", "wrong_nonce", "wrong_digest", "partial", "duplicate", "invalid_policy", "noise"] {
                try refuse {
                    _ = try fixture.transport(mode: mode).classify(candidates: paths,
                        scratchDescriptor: fixture.directory, timeout: 2, cancellation: CancellationToken())
                }
            }
            try fixture.remove()
        }
        onPass("POLICY-TRANSPORT-T04-process-and-protocol-refusals")
        try RuntimeFixtureSession.withCase("POLICY-TRANSPORT-T05-output-bounds") {
            let fixture = try Fixture(interpreter: interpreter)
            defer { try? fixture.remove() }
            for mode in ["overflow", "stderr_overflow"] {
                try refuse {
                    _ = try fixture.transport(mode: mode).classify(candidates: paths,
                        scratchDescriptor: fixture.directory, timeout: 2, cancellation: CancellationToken())
                }
            }
            try fixture.remove()
        }
        onPass("POLICY-TRANSPORT-T05-output-bounds")
        try RuntimeFixtureSession.withCase("POLICY-TRANSPORT-T06-cancellation-and-deadline") {
            let fixture = try Fixture(interpreter: interpreter)
            defer { try? fixture.remove() }
            let cancelled = CancellationToken(); cancelled.cancel()
            let cancelledAudit = CommandAudit()
            var cancelledReads = 0
            try refuse {
                _ = try fixture.transport(mode: "valid", authority: { cancelledReads += 1 })
                    .classify(candidates: paths, scratchDescriptor: fixture.directory, timeout: 2,
                              cancellation: cancelled, audit: cancelledAudit)
            }
            try require(cancelledReads == 0 && cancelledAudit.invocations.isEmpty, "cancelled admission spawned")
            let started = DispatchTime.now().uptimeNanoseconds
            try refuse {
                _ = try fixture.transport(mode: "sleep").classify(candidates: paths,
                    scratchDescriptor: fixture.directory, timeout: 0.1, cancellation: CancellationToken())
            }
            let during = CancellationToken()
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { during.cancel(); done.signal() }
            try refuse {
                _ = try fixture.transport(mode: "sleep").classify(candidates: paths,
                    scratchDescriptor: fixture.directory, timeout: 2, cancellation: during)
            }
            try require(done.wait(timeout: .now() + 2) == .success
                && DispatchTime.now().uptimeNanoseconds - started < 5_000_000_000,
                "cancellation or timeout did not settle")
            try fixture.remove()
        }
        onPass("POLICY-TRANSPORT-T06-cancellation-and-deadline")
        try RuntimeFixtureSession.withCase("POLICY-TRANSPORT-T07-closed-time-budget") {
            let fixture = try Fixture(interpreter: interpreter)
            defer { try? fixture.remove() }
            for timeout in [0, -1, 2.1, Double.infinity, Double.nan] {
                let audit = CommandAudit()
                try refuse {
                    _ = try fixture.transport(mode: "valid").classify(candidates: paths,
                        scratchDescriptor: fixture.directory, timeout: timeout,
                        cancellation: CancellationToken(), audit: audit)
                }
                try require(audit.invocations.isEmpty, "invalid budget spawned")
            }
            try fixture.remove()
        }
        onPass("POLICY-TRANSPORT-T07-closed-time-budget")
        try RuntimeFixtureSession.withCase("POLICY-TRANSPORT-T08-sealed-fd9-keeps-legacy-contract") {
            let fixture = try Fixture(interpreter: interpreter)
            defer { try? fixture.remove() }
            let bytes = Data("sealed-resource-fixture".utf8)
            let sealed = try ClosedProcessInput(data: bytes, directory: fixture.directory, owner: geteuid())
            let input = try ClosedProcessInput(data: Data("request".utf8), directory: fixture.directory, owner: geteuid())
            func direct(_ command: ClosedProcessCommand, _ audit: CommandAudit) throws -> ProcessResult {
                try ClosedProcessRunner(audit: audit).run(command: command,
                    environment: ClosedProcessRunner.environment(account: fixture.account),
                    workingDirectoryDescriptor: fixture.directory, account: fixture.account,
                    timeout: 2, cancellation: CancellationToken())
            }
            let echoed = try direct(ClosedProcessCommand(executable: "/bin/cat", arguments: ["/dev/fd/9"],
                inheritedReadSnapshotDescriptor: sealed.descriptor, standardInputDescriptor: input.descriptor), CommandAudit())
            try require(echoed.succeeded && echoed.stdout == bytes && echoed.stderr.isEmpty,
                        "sealed fd9 transfer")
            for command in [
                ClosedProcessCommand(executable: "/bin/cat", arguments: [], inheritedReadDescriptor: sealed.descriptor),
                ClosedProcessCommand(executable: "/bin/cat", arguments: [], inheritedReadDescriptor: sealed.descriptor,
                                     inheritedReadSnapshotDescriptor: sealed.descriptor),
                ClosedProcessCommand(executable: "/bin/cat", arguments: [], inheritedReadSnapshotDescriptor: input.descriptor,
                                     standardInputDescriptor: input.descriptor),
            ] {
                let audit = CommandAudit(); var refused = false
                do { _ = try direct(command, audit) } catch { refused = true }
                try require(refused && audit.invocations.isEmpty, "descriptor mode ambiguity reached spawn")
            }
            try fixture.remove()
        }
        onPass("POLICY-TRANSPORT-T08-sealed-fd9-keeps-legacy-contract")
    }

    private static func require(_ condition: Bool, _ text: String) throws {
        if !condition { throw Failure.assertion(text) }
    }
    private static func refuse(_ operation: () throws -> Void) throws {
        do { try operation(); throw Failure.assertion("unsafe response accepted") }
        catch PolicyHelperError.unavailable {
            try require(String(describing: PolicyHelperError.unavailable)
                == "Repository policy classification is unavailable.", "unsafe diagnostic")
        }
    }

    private final class Fixture {
        let path: String
        let directory: Int32
        let account: EffectiveAccount
        let identity: FileIdentity
        let interpreter: String
        private var removed = false

        init(interpreter: String) throws {
            self.interpreter = interpreter
            var template = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-policy-transport-") + "XXXXXX").utf8CString)
            guard let value = mkdtemp(&template) else { throw Failure.assertion("fixture create") }
            path = String(cString: value)
            directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var info = stat()
            guard directory >= 0, fstat(directory, &info) == 0,
                  info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
                throw Failure.assertion("fixture identity")
            }
            identity = FileIdentity(info)
            account = EffectiveAccount(uid: geteuid(), username: "fixture", homeDirectory: path)
        }

        func transport(mode: String, authority: @escaping () throws -> Void = {}) -> PolicyHelperTransport {
            let code = """
            import json,sys,time
            def run_sealed(contract):
                if contract != b'fixture-contract': raise ValueError()
                if not sys.flags.isolated or not sys.flags.no_site or not sys.flags.dont_write_bytecode: raise ValueError()
                request=json.load(sys.stdin)
                mode='\(mode)'
                if mode=='sleep': time.sleep(10)
                if mode=='nonzero': return 2
                if mode=='overflow': sys.stdout.write('x'*65537); return 0
                if mode=='stderr_overflow': sys.stderr.write('x'*65537); return 0
                result={'schema':'shadow-sync-policy-batch-response/v1','nonce':request['nonce'],
                        'binding_sha256':request['binding_sha256'],'policy_sha256':'\(policy)',
                        'module_sha256':'\(module)','results':[
                            {'index':i,'matched':i==1,'kind':'exact_root' if i==1 else 'none','policy_valid':True}
                            for i,_ in enumerate(request['candidates'])]}
                if mode=='stderr': sys.stderr.write('private fixture diagnostic')
                if mode=='wrong_nonce': result['nonce']='a'*32
                if mode=='wrong_digest': result['policy_sha256']='e'*64
                if mode=='partial': result['results']=result['results'][:1]
                if mode=='duplicate': result['results'][1]=result['results'][0]
                if mode=='invalid_policy': result['results'][1].update(kind='invalid_policy',policy_valid=False)
                if mode=='noise': sys.stdout.write('debug')
                print(json.dumps(result,separators=(',',':')))
                return 0
            """
            return PolicyHelperTransport(interpreter: interpreter, adapter: Data(code.utf8),
                contract: Data("fixture-contract".utf8), bindingSHA256: binding,
                policySHA256: policy, moduleSHA256: module, account: account,
                revalidateAuthority: authority, validateSuspendedChild: { _ in })
        }

        func remove() throws {
            if removed { return }
            var named = stat(); var opened = stat()
            try require(lstat(path, &named) == 0 && fstat(directory, &opened) == 0
                && FileIdentity(named).matchesStableNode(identity)
                && FileIdentity(opened).matchesStableNode(identity), "fixture changed before cleanup")
            try require(rmdir(path) == 0, "sealed snapshots left a named file")
            close(directory); removed = true
        }
    }
}
#endif
