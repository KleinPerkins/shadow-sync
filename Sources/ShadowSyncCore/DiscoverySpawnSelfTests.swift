#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

public enum DiscoverySpawnSelfTestRunner {
    private enum Failure: Error { case assertion(String) }

    public static func runAll(onPass: (String) -> Void) throws {
        let first = "DISCOVERY-SPAWN-T01-ordinary-mapping-and-borrowed-descriptors"
        let second = "DISCOVERY-SPAWN-T02-trace-source-collides-with-gate-target"
        let third = "DISCOVERY-SPAWN-T03-partial-allocation-refusal-and-cleanup"
        try RuntimeFixtureSession.withCase(first) { try mapping(collision: false, caseID: first) }
        onPass(first)
        try RuntimeFixtureSession.withCase(second) { try mapping(collision: true, caseID: second) }
        onPass(second)
        try RuntimeFixtureSession.withCase(third) {
            try partialAllocationFailure()
            let identity = try ProcessIdentity.capture(processID: getpid(), generation: RunIdentity.make())
            var refused = false
            do { _ = try OwnedDirectChild(adoptingSpawnedChild: getpid(), identity: identity) }
            catch ProcessOwnershipError.identityMismatch { refused = true }
            try require(refused, "self PID was not refused before signal/reap authority")
        }
        onPass(third)
        try RuntimeFixtureSession.withCase("DISCOVERY-SPAWN-T04-qualified-exec-normal-exit") { try mapping(collision: false, caseID: "DISCOVERY-SPAWN-T04-qualified-exec-normal-exit", transition: "exit") }
        onPass("DISCOVERY-SPAWN-T04-qualified-exec-normal-exit")
        try RuntimeFixtureSession.withCase("DISCOVERY-SPAWN-T05-qualified-exec-term") { try mapping(collision: false, caseID: "DISCOVERY-SPAWN-T05-qualified-exec-term", transition: "term") }
        onPass("DISCOVERY-SPAWN-T05-qualified-exec-term")
        try RuntimeFixtureSession.withCase("DISCOVERY-SPAWN-T06-unqualified-exec-signal-refusal") { try mapping(collision: false, caseID: "DISCOVERY-SPAWN-T06-unqualified-exec-signal-refusal", transition: "strict") }
        onPass("DISCOVERY-SPAWN-T06-unqualified-exec-signal-refusal")
        try RuntimeFixtureSession.withCase("DISCOVERY-SPAWN-T07-qualified-exec-kill") { try mapping(collision: false, caseID: "DISCOVERY-SPAWN-T07-qualified-exec-kill", transition: "kill") }
        onPass("DISCOVERY-SPAWN-T07-qualified-exec-kill")
        try RuntimeFixtureSession.withCase("DISCOVERY-SPAWN-T08-qualified-graph-expired-resume") { try mapping(collision: false, caseID: "DISCOVERY-SPAWN-T08-qualified-graph-expired-resume", transition: "expired") }
        onPass("DISCOVERY-SPAWN-T08-qualified-graph-expired-resume")
        try RuntimeFixtureSession.withCase("DISCOVERY-SPAWN-T09-graph-fault-survives-natural-exit") { try mapping(collision: false, caseID: "DISCOVERY-SPAWN-T09-graph-fault-survives-natural-exit", transition: "fault-exit") }
        onPass("DISCOVERY-SPAWN-T09-graph-fault-survives-natural-exit")
        try RuntimeFixtureSession.withCase("DISCOVERY-SPAWN-T10-stale-exec-observation-revalidates") {
            try mapping(collision: false, caseID: "DISCOVERY-SPAWN-T10-stale-exec-observation-revalidates", transition: "stale")
        }
        onPass("DISCOVERY-SPAWN-T10-stale-exec-observation-revalidates")
        try RuntimeFixtureSession.withCase("DISCOVERY-SPAWN-T11-closed-read-command-contract") { try commandContract() }
        onPass("DISCOVERY-SPAWN-T11-closed-read-command-contract")
        try RuntimeFixtureSession.withCase("DISCOVERY-SPAWN-T12-reject-command-before-candidate-access") { try commandRefusal() }
        onPass("DISCOVERY-SPAWN-T12-reject-command-before-candidate-access")
        try RuntimeFixtureSession.withCase("DISCOVERY-SPAWN-T13-preflight-stage-ceilings") { try preflightTimeline("ceilings") }
        onPass("DISCOVERY-SPAWN-T13-preflight-stage-ceilings")
        try RuntimeFixtureSession.withCase("DISCOVERY-SPAWN-T14-late-preflight-keeps-outer-deadlines") { try preflightTimeline("late") }
        onPass("DISCOVERY-SPAWN-T14-late-preflight-keeps-outer-deadlines")
        try RuntimeFixtureSession.withCase("DISCOVERY-SPAWN-T15-preflight-refuses-expired-and-future-budget") { try preflightTimeline("expired") }
        onPass("DISCOVERY-SPAWN-T15-preflight-refuses-expired-and-future-budget")
        try RuntimeFixtureSession.withCase("DISCOVERY-SPAWN-T16-preflight-preserves-short-cleanup") { try preflightTimeline("cleanup") }
        onPass("DISCOVERY-SPAWN-T16-preflight-preserves-short-cleanup")
        try RuntimeFixtureSession.withCase("DISCOVERY-SPAWN-T17-preflight-refuses-malformed-parent") { try preflightTimeline("malformed") }
        onPass("DISCOVERY-SPAWN-T17-preflight-refuses-malformed-parent")
        try RuntimeFixtureSession.withCase("DISCOVERY-SPAWN-T18-preflight-consumes-short-command-budget") { try preflightTimeline("short") }
        onPass("DISCOVERY-SPAWN-T18-preflight-consumes-short-command-budget")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure.assertion(message) }
    }

    /// Pure timeline checks deliberately use a synthetic monotonic instant. No
    /// sleeps, process launch, filesystem access or test-only timeout relaxation
    /// can turn a refreshed deadline into an apparently successful preflight.
    private static func preflightTimeline(_ mode: String) throws {
        let start: UInt64 = 1_000_000_000_000
        let seconds: TimeInterval = mode == "short" ? 0.1 : 15
        let command = try DiscoveryGitCommand(arguments: ["--no-replace-objects", "--no-lazy-fetch",
            "symbolic-ref", "--quiet", "--short", "HEAD"],
            captureTransportConfiguration: false, timeoutSeconds: seconds)
        let parent = try CustodyBudget.make(kind: .discoveryGit, workSeconds: seconds,
            termSeconds: mode == "cleanup" ? 0 : 2,
            killSeconds: mode == "cleanup" ? 0 : 2,
            receiptSeconds: mode == "cleanup" ? 0 : 1, now: start)
        func refused(_ original: CustodyBudget, at now: UInt64) throws {
            for stage in DiscoveryGitCommand.Preflight.allCases {
                do {
                    _ = try original.discoveryPreflight(stage, command: command, now: now)
                    throw Failure.assertion("invalid original timeline admitted a preflight")
                } catch CustodyProtocolError.invalidBudget {}
            }
        }
        if mode == "expired" {
            try refused(parent, at: start - 1)
            try refused(parent, at: parent.work)
            try refused(parent, at: parent.receipt + 1)
            return
        }
        if mode == "malformed" {
            func value(work: UInt64, term: UInt64, kill: UInt64, receipt: UInt64) throws -> CustodyBudget {
                try CustodyBudget(wire: .object(["issued": .unsigned(start), "work": .unsigned(work),
                    "term": .unsigned(term), "kill": .unsigned(kill), "receipt": .unsigned(receipt)]))
            }
            try refused(value(work: parent.work, term: parent.work - 1,
                              kill: parent.kill, receipt: parent.receipt), at: start)
            try refused(value(work: parent.work, term: parent.term,
                              kill: parent.term - 1, receipt: parent.receipt), at: start)
            try refused(value(work: parent.work, term: parent.term,
                              kill: parent.kill, receipt: parent.kill - 1), at: start)
            try refused(value(work: parent.work + 1, term: parent.term,
                              kill: parent.kill, receipt: parent.receipt), at: start)
            try refused(value(work: parent.work, term: parent.term + 1,
                              kill: parent.kill, receipt: parent.receipt), at: start)
            return
        }
        if mode == "cleanup" {
            // Exercise early stages: checking only near outer work expiry would
            // hide accidentally restored cleanup grace behind endpoint caps.
            for grace in [(0.0, 0.0, 0.0), (0.1, 0.2, 0.05)] {
                let shortened = try CustodyBudget.make(kind: .discoveryGit, workSeconds: seconds,
                    termSeconds: grace.0, killSeconds: grace.1, receiptSeconds: grace.2, now: start)
                for now in [start, start + (shortened.work - start) / 2, shortened.work - 1] {
                    for stage in DiscoveryGitCommand.Preflight.allCases {
                        let result = try shortened.discoveryPreflight(stage, command: command, now: now)
                        try require(result.term - result.work == shortened.term - shortened.work
                            && result.kill - result.term == shortened.kill - shortened.term
                            && result.receipt - result.kill == shortened.receipt - shortened.kill,
                            "preflight regained shortened caller cleanup grace")
                        try require(result.work <= shortened.work && result.term <= shortened.term
                            && result.kill <= shortened.kill && result.receipt <= shortened.receipt,
                            "short cleanup exceeded original endpoint")
                    }
                }
            }
            return
        }
        let now: UInt64
        switch mode {
        case "ceilings": now = start + (parent.work - start) / 2
        case "late": now = parent.work - 1
        case "short": now = start + (parent.work - start) / 2
        default: throw Failure.assertion("unknown timeline fixture")
        }
        for stage in DiscoveryGitCommand.Preflight.allCases {
            let result = try parent.discoveryPreflight(stage, command: command, now: now)
            try require(result.issued == now && result.work <= parent.work
                && result.term <= parent.term && result.kill <= parent.kill
                && result.receipt <= parent.receipt, "preflight extended an original deadline")
            try require(result.term - result.work <= parent.term - parent.work
                && result.kill - result.term <= parent.kill - parent.term
                && result.receipt - result.kill <= parent.receipt - parent.kill,
                "preflight extended an original cleanup interval")
            try result.validate(kind: stage.kind, permittedWorkSeconds: stage.workSeconds, now: now)
            if mode == "ceilings" {
                let maximum = try CustodyBudget.make(kind: stage.kind, workSeconds: stage.workSeconds, now: now)
                try require(result == maximum, "late stage could not use its remaining bounded work")
            } else {
                try require(result.work == parent.work && result.term == parent.term
                    && result.kill == parent.kill && result.receipt == parent.receipt,
                    "shorter original timeline was not retained exactly")
            }
            // Starting another preflight cannot renew the enclosing transaction.
            let final = try parent.discoveryPreflight(stage, command: command, now: parent.work - 1)
            try require(final.work == parent.work && final.receipt <= parent.receipt,
                        "later preflight renewed the transaction")
        }
    }

    private static func commandContract() throws {
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        let home = try fixture.makeHome()
        let account = try EffectiveAccount.isolated(homeDirectory: home)
        let prefix = ["--no-replace-objects", "--no-lazy-fetch"]
        let origin = ["remote", "get-url", "--all", "origin"]
        let commands = [origin, ["worktree", "list", "--porcelain", "-z"], ["ls-files", "-v", "-z"],
            ["for-each-ref", "--format=%(refname)%00%(objectname)%00%(objecttype)%00%(*objectname)%00%(*objecttype)%00",
             "refs/heads/main", "refs/remotes/origin/main"],
            ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"],
            ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
            ["symbolic-ref", "--quiet", "--short", "HEAD"],
            ["rev-parse", "--verify", "HEAD^{commit}"],
            ["rev-parse", "--verify", "refs/heads/fixture/topic^{commit}"],
            ["rev-parse", "--verify", "refs/remotes/origin/fixture/topic^{commit}"],
            ["merge-base", "--is-ancestor", String(repeating: "a", count: 40), String(repeating: "b", count: 40)],
            ["merge-base", "--is-ancestor", String(repeating: "a", count: 64), String(repeating: "b", count: 64)]]
        let environment = ["HOME": home, "USER": account.username, "LOGNAME": account.username,
            "PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0",
            "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false", "GIT_OPTIONAL_LOCKS": "0",
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "include.path", "GIT_CONFIG_VALUE_0": "/dev/fd/197"]
        for args in commands {
            for seconds in [0.1, 5.0, 15.0] {
                let trace = args == origin
                let command = try DiscoveryGitCommand(arguments: prefix + args,
                    captureTransportConfiguration: trace, timeoutSeconds: seconds)
                try require(command.arguments == prefix + args && command.workSeconds == seconds,
                    "closed discovery adapter changed an existing command or work limit")
                var expected = environment
                if trace {
                    expected["GIT_TRACE2_EVENT"] = "9"
                    expected["GIT_TRACE2_CONFIG_PARAMS"] = "remote.origin.uploadpack,core.sshcommand"
                }
                try require(command.environment(account: account) == expected
                    && command.capturesTransportConfiguration == trace,
                    "closed discovery environment or transport trace changed")
            }
        }
        try require(DiscoveryGitCommand.stdoutLimit == 1_048_576
            && DiscoveryGitCommand.stderrLimit == 262_144 && DiscoveryGitCommand.traceLimit == 262_144,
            "discovery output limits changed")
    }

    private final class AdmissionObservation: @unchecked Sendable {
        private let mutex = NSLock()
        private var count = 0
        func observed() { mutex.lock(); count += 1; mutex.unlock() }
        var total: Int { mutex.lock(); defer { mutex.unlock() }; return count }
    }

    private static func commandRefusal() throws {
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        let observed = AdmissionObservation()
        let home = try fixture.makeHome()
        let account = try EffectiveAccount.isolated(homeDirectory: home)
        let probe = DiscoveryGitProbe(account: account, observer: { _ in observed.observed() },
            candidateObserver: { _, _ in observed.observed() }, processObserver: { _ in observed.observed() })
        // No repository exists. The real entrypoint must produce the command
        // refusal before its admission observer, descriptor allocation, candidate
        // opening or spawn. A later filesystem error does not pass this case.
        let candidate = RepositoryCandidate(id: "fixture-owner/absent", displayName: "Fixture",
            path: fixture.root + "/must-not-open", rawOrigin: "https://github.com/fixture-owner/absent.git")
        let prefix = ["--no-replace-objects", "--no-lazy-fetch"]
        let oid = String(repeating: "a", count: 40)
        let status = prefix + ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"]
        let origin = prefix + ["remote", "get-url", "--all", "origin"]
        let forbidden = [
            ["merge", "--ff-only", "--no-overwrite-ignore", "--no-autostash", oid],
            ["update-ref", "refs/heads/main", oid, oid], ["worktree", "remove", "--force", "fixture"],
            ["worktree", "prune", "--dry-run", "--verbose", "--expire=now"],
            ["reset", "--hard"], ["push", "origin", "main"], ["pull"], ["clean", "-fd"],
            ["checkout", "main"], ["switch", "main"], ["stash"], ["rebase", "main"],
            ["fetch", "origin"], ["ls-remote", "--symref", "origin", "HEAD"],
            ["-c", "core.sshCommand=fixture", "status"], ["--git-dir=fixture", "status"],
            ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
            ["rev-parse", "--verify", "refs/heads/main^{commit}\0--help"],
            ["rev-parse", "--verify", "HEAD:fixture^{commit}"],
            ["merge-base", "--is-ancestor", oid, "--help"],
            ["merge-base", "--is-ancestor", oid, String(repeating: "a", count: 64)],
            ["merge-base", "--is-ancestor", String(repeating: "١", count: 40), oid],
            ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all", "--", "fixture"],
        ]
        var inputs = forbidden.map { (prefix + $0, false, 5.0) }
        inputs += [(Array(status.dropFirst()), false, 5), (["-c", "shadowSync.m1TestRoot=true"] + status, false, 5),
            (origin, false, 5), (status, true, 5), ([], false, 5)]
        inputs += [Double.nan, Double.infinity, -Double.infinity, -1, 0, 0.099, 15.001].map { (status, false, $0) }
        for (arguments, trace, timeout) in inputs {
            do {
                _ = try probe.run(candidate: candidate, arguments: arguments,
                    timeoutSeconds: timeout, captureTransportConfiguration: trace)
                throw Failure.assertion("discovery admitted an invalid command")
            } catch GitSafetyError.unsafeRepository(let reason) {
                try require(reason == "Git command is outside the closed discovery command set",
                    "discovery refusal occurred after the command boundary")
            }
        }
        try require(observed.total == 0, "refused command reached candidate/process admission")
    }

    private static func mapping(collision: Bool, caseID: String, transition: String? = nil) throws {
        let graph = transition == nil || transition == "strict" ? nil : try CommandGraphSelfTests.fixtureGraph()
        let executable = transition == nil ? discoveryFixtureGitExecutable : "/usr/bin/git"
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        let directory = try fixture.openDirectory()
        let input = try fixture.openNull()
        let output = try fixture.pipe()
        let error = try fixture.pipe()
        let trace = try fixture.pipe()
        let gate = try fixture.pipe()
        let traceSource: Int32
        if collision {
            // Reserve an unused descriptor rather than replacing a descriptor
            // belonging to another thread, framework or test.
            traceSource = try fixture.retain(trace[1], minimum: 197)
            try require(traceSource == 197, "collision fixture destination is occupied")
        } else {
            traceSource = trace[1]
            try require(traceSource != 197, "ordinary fixture unexpectedly collides")
        }
        let environment = [
            "HOME": fixture.root, "PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "include.path",
            "GIT_CONFIG_VALUE_0": "/dev/fd/197", "GIT_TRACE2_EVENT": String(discoveryTraceDescriptor),
            "GIT_TRACE2_CONFIG_PARAMS": "core.sshcommand",
        ]
        let streams = try StreamDrain([output[0], error[0], trace[0]])
        let anchor = try spawnDiscoveryGitFixture(
            arguments: ["config", "--get", "core.sshcommand"], environment: environment,
            directoryDescriptor: directory, inputDescriptor: input,
            outputDescriptor: output[1], errorDescriptor: error[1],
            traceDescriptor: traceSource, startGateDescriptor: gate[0],
            streamsDrained: { streams.pump() }, useQualifiedLauncherFixture: transition != nil
        )
        let writers = Set([output[1], error[1], trace[1], traceSource, gate[0], gate[1]])
        defer {
            // The original anchor, readers and fixture survive all assertions.
            // Close owned writer copies before EOF/drain can be established.
            for descriptor in writers { fixture.closeOwned(descriptor) }
            RuntimeFixtureSession.drain(anchor)
        }
        for descriptor in [directory, input, output[1], error[1], traceSource, gate[0]] {
            try require(fcntl(descriptor, F_GETFD) >= 0, "spawn closed a caller-owned descriptor")
        }
        for descriptor in writers where transition == nil || descriptor != gate[1] { fixture.closeOwned(descriptor) }
        if let graph { try graph.validateSuspended(anchor) }
        let registry = try RuntimeFixtureSession.current()
        var owner: OwnedDirectChild?
        if collision || transition != nil { owner = try anchor.transfer(expectedExecutable: executable,
            generation: RunIdentity.make(), reapPolicy: .afterGroupDrain, qualifiedGraph: graph) }
        if transition != nil { try require(owner!.prepareGraphSignal() == .ready, "pre-probe graph validation failed") }
        if RuntimeFixtureSession.guardianProbeTarget() == caseID {
            fputs("GUARDIAN PROBE \(caseID)\n", stdout); fflush(stdout)
            while registry.snapshot().reason == nil { usleep(1_000) }
            if let owner { try require(!owner.send(SIGCONT), "cancelled discovery original resumed") }
            RuntimeFixtureSession.drain(anchor)
            try require(anchor.unexecutedProof() != nil && streams.pump(), "cancelled discovery spawn did not drain")
            let proof = try JSONSerialization.data(withJSONObject: [
                "schema": "shadow-sync-discovery-spawn-probe/v1", "case": caseID,
                "reason": registry.snapshot().reason!.rawValue,
                "never_resumed": true, "streams_eof": true,
            ], options: [.sortedKeys])
            FileHandle.standardOutput.write(Data("DISCOVERY SPAWN PROOF ".utf8) + proof + Data([10]))
            return
        }
        if owner == nil { owner = try anchor.transfer(expectedExecutable: executable,
            generation: RunIdentity.make(), reapPolicy: .afterGroupDrain, qualifiedGraph: graph) }
        let original = owner!
        try require(original.prepareGraphSignal() == .ready, "graph signal preparation failed")
        if transition == "expired" {
            try require(!original.resume(before: MonotonicDeadline(uptimeNanoseconds: 0)), "expired graph validation resumed target")
            fixture.closeOwned(gate[1]); RuntimeFixtureSession.drain(anchor)
            try require(anchor.unexecutedProof() != nil && streams.pump(), "expired original did not drain unexecuted")
            try fixture.remove(); return
        }
        try require(original.send(SIGCONT), "discovery original resume refused")
        if let transition {
            let deadline = MonotonicDeadline(seconds: 5)
            var transitioned = false
            while !deadline.hasExpired {
                _ = streams.pump()
                if let observed = try? ProcessIdentity.capture(processID: anchor.processID, generation: original.identity.generation),
                   observed.executablePath == discoveryFixtureGitExecutable,
                   observed.sameOriginalChild(as: original.identity) { transitioned = true; break }
                usleep(1_000)
            }
            try require(transitioned, "original launcher did not execute the expected developer Git")
            try require(!original.identity.isCurrent(), "fixture did not establish a changed executable identity")
            if transition == "strict" {
                try require(!original.send(SIGTERM), "unqualified owner accepted an executable transition")
            } else {
                try require(original.prepareGraphSignal() == .ready, "qualified graph observation unavailable")
                if transition == "stale" {
                    original.testingRestoreOriginalGraphObservation()
                    try require(!original.send(SIGTERM) && !original.hasGraphFault,
                                "qualified exec race was signalled or poisoned")
                    try require(original.prepareGraphSignal() == .ready && original.send(SIGTERM),
                                "qualified exec could not revalidate and cancel")
                }
                if transition == "fault-exit" {
                    original.testingRejectQualifiedGraphObservation()
                    try require(!original.send(SIGTERM) && original.hasGraphFault, "positive graph fault did not close signals")
                }
                if transition == "term" || transition == "kill" {
                    try require(original.send(transition == "term" ? SIGTERM : SIGKILL), "qualified original signal refused")
                }
            }
            fixture.closeOwned(gate[1])
        }
        let deadline = MonotonicDeadline(seconds: 5)
        while !deadline.hasExpired {
            if case .reaped = original.reapAfterGroupDrain(streamsDrained: streams.pump()) { break }
            usleep(10_000)
        }
        try require(original.observation == .reaped(transition == "term" || transition == "stale" ? SIGTERM : transition == "kill" ? SIGKILL : 0), "discovery child failed or exceeded fixture deadline")
        if transition == "fault-exit" {
            try require(original.hasGraphFault && !original.graphRetirementPermitted,
                        "natural exit erased a positive graph fault")
        }
        RuntimeFixtureSession.drain(anchor)
        try require(streams.pump() && streams.failure == nil, "invalid or oversized fixture output")
        try require(!original.send(SIGTERM) && !original.send(SIGKILL), "reaped original accepted a signal")
        if transition == "term" || transition == "kill" || transition == "stale" {
            try require(streams.bytes(error[0]).isEmpty, "cancelled Git emitted unexpected stderr")
            try fixture.remove(); return
        }
        try require(streams.bytes(output[0]) == Data("fixture-sentinel\n".utf8), "discovery stdout changed")
        try require(streams.bytes(error[0]).isEmpty, "unexpected discovery stderr")
        try require(String(decoding: streams.bytes(trace[0]), as: UTF8.self).contains("fixture-sentinel"),
                    "discovery lost its configuration trace")
        try require(waitpid(anchor.processID, nil, WNOHANG) == -1 && errno == ECHILD,
                    "discovery child was not reaped")
        try fixture.remove()
    }

    private static func partialAllocationFailure() throws {
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        let directory = try fixture.openDirectory()
        let input = try fixture.openNull()
        // Reserve three slots, then free only the first two. The third remains
        // our sentinel. An invalid third source forces failure after two copies;
        // no process-wide descriptor limit or foreign descriptor is modified.
        let first = try fixture.retain(input, minimum: 256)
        let second = try fixture.retain(input, minimum: first + 1)
        let sentinel = try fixture.retain(input, minimum: second + 1)
        fixture.closeOwned(first); fixture.closeOwned(second)
        var refused = false
        do {
            let anchor = try spawnDiscoveryGitFixture(
                arguments: ["--version"], environment: ["PATH": "/usr/bin:/bin"],
                directoryDescriptor: directory, inputDescriptor: input,
                outputDescriptor: input, errorDescriptor: -1,
                traceDescriptor: input, startGateDescriptor: input, streamsDrained: { true }
            )
            RuntimeFixtureSession.drain(anchor)
        } catch SecureStateError.systemCall(let operation, let code) {
            refused = operation == "retain discovery spawn source" && code == EBADF
        }
        try require(refused, "invalid remap source was not refused before spawn")
        try require(fcntl(first, F_GETFD) == -1 && errno == EBADF,
                    "first retained source leaked on partial failure")
        try require(fcntl(second, F_GETFD) == -1 && errno == EBADF,
                    "second retained source leaked on partial failure")
        for descriptor in [directory, input, sentinel] {
            try require(fcntl(descriptor, F_GETFD) >= 0, "failure closed a caller-owned descriptor")
        }
        try fixture.remove()
    }

    /// Read-zero EOF is required on every stream. Per-pass work and retained
    /// bytes are bounded independently; overflow remains a failed assertion.
    private final class StreamDrain: @unchecked Sendable {
        private let lock = NSLock()
        private let descriptors: [Int32]
        private var output: [Int32: Data] = [:]
        private var eof = Set<Int32>()
        private var problem: String?
        init(_ descriptors: [Int32]) throws {
            self.descriptors = descriptors
            for fd in descriptors {
                let flags = fcntl(fd, F_GETFL)
                try require(flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
                            "nonblocking discovery stream setup failed")
                output[fd] = Data()
            }
        }
        func pump() -> Bool {
            lock.lock(); defer { lock.unlock() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            for fd in descriptors where !eof.contains(fd) {
                for _ in 0..<32 {
                    let count = Darwin.read(fd, &bytes, bytes.count)
                    if count == 0 { eof.insert(fd); break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        if errno != EAGAIN && errno != EWOULDBLOCK { problem = "discovery stream read failed" }
                        break
                    }
                    let room = max(0, 131_072 - output[fd]!.count)
                    output[fd]!.append(contentsOf: bytes.prefix(min(room, count)))
                    if count > room { problem = "discovery stream overflow" }
                }
            }
            return eof.count == descriptors.count
        }
        var failure: String? { lock.lock(); defer { lock.unlock() }; return problem }
        func bytes(_ descriptor: Int32) -> Data {
            lock.lock(); defer { lock.unlock() }; return output[descriptor]!
        }
    }

    private final class Fixture {
        let root: String
        private let device: dev_t
        private let inode: ino_t
        private var owned = Set<Int32>()
        private var removed = false

        init() throws {
            var template = Array((try RuntimeFixtureSession.fixturePrefix("shadow-sync-discovery-spawn.") + "XXXXXX").utf8CString)
            guard let value = mkdtemp(&template) else {
                throw SecureStateError.systemCall("create discovery fixture", errno)
            }
            root = String(cString: value)
            var identity = stat()
            guard lstat(root, &identity) == 0 else {
                throw SecureStateError.systemCall("inspect discovery fixture", errno)
            }
            device = identity.st_dev; inode = identity.st_ino
            do {
                try FileManager.default.createDirectory(atPath: root + "/.git/objects",
                                                        withIntermediateDirectories: true)
                try FileManager.default.createDirectory(atPath: root + "/.git/refs",
                                                        withIntermediateDirectories: true)
                try Data("ref: refs/heads/main\n".utf8).write(to: URL(fileURLWithPath: root + "/.git/HEAD"))
                try Data("[core]\nrepositoryformatversion = 0\nbare = false\nsshCommand = fixture-sentinel\n".utf8)
                    .write(to: URL(fileURLWithPath: root + "/.git/config"))
            } catch { try? remove(); throw error }
        }
        deinit { for descriptor in owned { Darwin.close(descriptor) } }
        func makeHome() throws -> String {
            let home = root + "/home"
            guard Darwin.mkdir(home, 0o700) == 0 else {
                throw SecureStateError.systemCall("create discovery fixture home", errno)
            }
            return home
        }
        func openDirectory() throws -> Int32 {
            try own(Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        }
        func openNull() throws -> Int32 { try own(Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)) }
        func retain(_ descriptor: Int32, minimum: Int32) throws -> Int32 {
            try own(fcntl(descriptor, F_DUPFD_CLOEXEC, minimum))
        }
        private func own(_ descriptor: Int32) throws -> Int32 {
            guard descriptor >= 0 else { throw SecureStateError.systemCall("fixture descriptor", errno) }
            owned.insert(descriptor); return descriptor
        }
        func pipe() throws -> [Int32] {
            var pair: [Int32] = [-1, -1]
            guard Darwin.pipe(&pair) == 0 else { throw SecureStateError.systemCall("fixture pipe", errno) }
            for descriptor in pair { owned.insert(descriptor) }
            for descriptor in pair {
                try require(fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0, "fixture close-on-exec failed")
            }
            return pair
        }
        func closeOwned(_ descriptor: Int32) {
            if owned.remove(descriptor) != nil { Darwin.close(descriptor) }
        }
        func remove() throws {
            if removed { return }
            var current = stat()
            try require(lstat(root, &current) == 0 && current.st_dev == device && current.st_ino == inode
                && current.st_uid == geteuid() && (current.st_mode & S_IFMT) == S_IFDIR
                && (current.st_mode & 0o777) == 0o700, "fixture cleanup identity changed")
            for descriptor in Array(owned) { closeOwned(descriptor) }
            try FileManager.default.removeItem(atPath: root)
            removed = true
        }
    }
}
#endif
