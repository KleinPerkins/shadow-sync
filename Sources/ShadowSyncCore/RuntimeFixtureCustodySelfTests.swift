#if SHADOW_SYNC_TESTING
import Foundation

public enum RuntimeFixtureCustodySelfTestRunner {
    private struct Failure: Error { let message: String }
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    private static func refuses(_ body: () throws -> Void) throws {
        do { try body() } catch is RuntimeFixtureCustody.Failure { return }
        throw Failure(message: "unsafe transition was accepted")
    }
    private static func registry(_ cases: [String] = ["first", "second"], capacity: Int = 4) throws -> RuntimeFixtureCustody {
        try RuntimeFixtureCustody(cases: cases, now: 100, deadline: 200,
                                  graceNanoseconds: 10, capacity: capacity)
    }
    private static func settle(_ r: RuntimeFixtureCustody, at now: UInt64 = 110) throws {
        let until = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        repeat {
            r.tick(now: now)
            if r.snapshot().cleanupComplete { return }
            Thread.sleep(forTimeInterval: 0.001)
        } while DispatchTime.now().uptimeNanoseconds < until
        throw Failure(message: "fixture callback did not settle")
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0, cancelled = 0, escalated = 0
        var reaped = false
        func step(_ d: RuntimeFixtureCustody.Directive) -> RuntimeFixtureCustody.ChildState {
            lock.lock(); defer { lock.unlock() }
            calls += 1; if d.reason != nil { cancelled += 1 }; if d.escalate { escalated += 1 }
            return reaped ? .reaped : .retained
        }
        func complete() { lock.lock(); reaped = true; lock.unlock() }
        func counts() -> [Int] { lock.lock(); defer { lock.unlock() }; return [calls, cancelled, escalated] }
    }
    public static func runAll(onPass: (String) -> Void = { _ in }) throws -> [String] {
        let tests: [(String, () throws -> Void)] = [
            ("runtime-custody-independent-fixture-drain", {
                let r = try registry(); try r.beginCase("first", now: 101)
                let first = try r.reserveSpawn(now: 102)
                try r.register(first) { d in d.reason == nil ? .retained : .reaped }
                var signalled = false
                r.requestDrain(first, now: 103)
                try check(!r.performResume(first, now: 104) { signalled = true; return true }
                    && !signalled, "draining original reached resume syscall")
                try settle(r, at: 114)
                try check(r.isRetired(first) && r.snapshot().reason == nil,
                          "normal cleanup cancelled the whole case")
                let second = try r.reserveSpawn(now: 115)
                try r.register(second) { _ in .reaped }
                try check(r.performResume(second, now: 116) { true }, "next original lost admission")
                try settle(r, at: 117)
                try r.closeCase("first", now: 118)
                try r.finishCase("first", assertionPassed: true, now: 119)
                try r.beginCase("second", now: 120)
                try r.finishCase("second", assertionPassed: true, now: 121)
                try r.finish(now: 122)
                try check(r.snapshot().succeeded && r.snapshot().reaped == 2, "normal drain lost accounting")
            }),
            ("runtime-custody-closing-case-retains-crossing-spawn", {
                let r = try registry(); try r.beginCase("first", now: 101)
                let crossing = try r.reserveSpawn(now: 102)
                try r.closeCase("first", now: 103)
                try check(!r.permitsSpawn(crossing, now: 104) && !r.permitsResume(now: 104)
                    && !r.isRetired(crossing), "case close abandoned pending original")
                try refuses { _ = try r.reserveSpawn(now: 104) }
                try refuses { try r.finishCase("first", assertionPassed: true, now: 105) }
                try r.register(crossing) { d in d.reason == nil ? .retained : .reaped }
                try check(!r.performResume(crossing, now: 106) { true }, "crossing original resumed")
                try settle(r, at: 114)
                try check(r.isRetired(crossing) && r.snapshot().reaped == 1, "crossing cleanup not retained")
                try r.finishCase("first", assertionPassed: true, now: 115)
                try r.beginCase("second", now: 116)
                try r.finishCase("second", assertionPassed: true, now: 117)
                try r.finish(now: 118)
                try check(r.snapshot().succeeded, "next case admission did not reopen")
            }),
            ("runtime-custody-closed-fixture-namespace", {
                let nonce = String(repeating: "a", count: 32)
                for prefix in ["shadow-sync-m2.", "shadow-sync-m4.", "shadow-sync-self-tests.", "shadow-sync-custody-anchor-",
                               "shadow-sync-m6-self.", "shadow-sync-custody-leases.", "shadow-sync-custody-catalog.",
                               "shadow-sync-fresh-state.", "shadow-sync-registry.", "shadow-sync-state-admission."] {
                    try check(try RuntimeFixtureSession.fixturePrefix(prefix, namespace: nonce)
                        == "/private/tmp/" + prefix + nonce + ".", "attempt namespace changed")
                    try check(try RuntimeFixtureSession.fixturePrefix(prefix, namespace: nil)
                        == "/private/tmp/" + prefix, "legacy fixture fallback changed")
                    for invalid in ["", ".", "../escape", String(repeating: "a", count: 31),
                                    String(repeating: "a", count: 33), String(repeating: "A", count: 32),
                                    String(repeating: "g", count: 32), nonce + "\n"] {
                        try refuses { _ = try RuntimeFixtureSession.fixturePrefix(prefix, namespace: invalid) }
                    }
                }
                try refuses { _ = try RuntimeFixtureSession.fixturePrefix("unowned/", namespace: nonce) }
            }),
            ("runtime-custody-closed-contract", {
                for cases in [[], ["a", "a"], ["a\nb"]] {
                    try refuses { _ = try registry(cases) }
                }
                try refuses { _ = try RuntimeFixtureCustody(cases: ["a"], now: 100, deadline: 100) }
                try refuses { _ = try registry(capacity: 257) }
            }),
            ("runtime-custody-complete-roster", {
                let r = try registry(); try refuses { try r.beginCase("second", now: 101) }
                try r.beginCase("first", now: 101); try r.finishCase("first", assertionPassed: true, now: 102)
                try refuses { try r.finish(now: 103) }
                try r.beginCase("second", now: 104); try r.finishCase("second", assertionPassed: true, now: 105)
                try r.finish(now: 106); try check(r.snapshot().succeeded, "complete roster refused")
                r.cancel(.callerLost, now: 107)
                try check(r.snapshot().succeeded, "terminal success changed after completion")
                try refuses { _ = try r.reserveSpawn(now: 108) }
            }),
            ("runtime-custody-inflight-cancel-retention", {
                let r = try registry(); try r.beginCase("first", now: 101)
                let t = try r.reserveSpawn(now: 102); r.cancel(.callerLost, now: 103)
                try check(!r.permitsSpawn(t, now: 104) && !r.permitsResume(now: 104), "cancel left admission open")
                try check(!r.snapshot().cleanupComplete, "pending syscall vanished")
                let state = State(); try r.register(t, step: state.step)
                r.tick(now: 104); state.complete(); try settle(r, at: 114)
                try refuses { try r.finishCase("first", assertionPassed: true, now: 115) }
                try check(r.snapshot().passedCases.isEmpty && r.snapshot().reaped == 1, "cancel counted pass or lost child")
                try refuses { try r.beginCase("second", now: 116) }
            }),
            ("runtime-custody-ticket-authority", {
                let r = try registry(capacity: 1), other = try registry()
                try r.beginCase("first", now: 101); try other.beginCase("first", now: 101)
                let t = try r.reserveSpawn(now: 102)
                try refuses { _ = try r.reserveSpawn(now: 103) }
                try refuses { try other.spawnFailed(t) }
                try check(r.snapshot().reservations == 1, "foreign registry consumed reservation")
                try r.spawnFailed(t); try refuses { try r.spawnFailed(t) }
                try refuses { try r.register(t) { _ in .reaped } }
                try check(r.snapshot().failedSpawns == 1, "failed spawn accounted twice")
            }),
            ("runtime-custody-blocked-owner-independent-control", {
                let r = try registry(); try r.beginCase("first", now: 101)
                let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
                let t = try r.reserveSpawn(now: 102)
                try r.register(t) { _ in started.signal(); _ = release.wait(timeout: .now() + 2); return .reaped }
                r.tick(now: 103)
                guard started.wait(timeout: .now() + 1) == .success else { release.signal(); throw Failure(message: "callback did not start") }
                defer { release.signal() }
                r.cancel(.transport, now: 104); r.tick(now: 120)
                try check(r.snapshot().reason == .transport && r.snapshot().callbacks == 1, "control waited on owner or callback duplicated")
                try refuses { _ = try r.reserveSpawn(now: 121) }
                release.signal(); try settle(r, at: 122)
                try check(r.snapshot().reaped == 1 && !r.snapshot().succeeded, "pending callback became success")
            }),
            ("runtime-custody-deadline-and-escalation", {
                let r = try registry(); try r.beginCase("first", now: 101)
                let state = State(), t = try r.reserveSpawn(now: 102); try r.register(t, step: state.step)
                r.tick(now: 200)
                let until = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
                while state.counts()[1] == 0 && DispatchTime.now().uptimeNanoseconds < until { Thread.sleep(forTimeInterval: 0.001) }
                try check(r.snapshot().reason == .deadline && !r.permitsResume(now: 201), "deadline not closed")
                r.cancel(.callerLost, now: 202); try check(r.snapshot().reason == .deadline, "first reason overwritten")
                while state.counts()[2] == 0 && DispatchTime.now().uptimeNanoseconds < until { r.tick(now: 211); Thread.sleep(forTimeInterval: 0.001) }
                try check(state.counts()[2] > 0 && r.snapshot().children == 1, "escalation lost retained child")
                state.complete(); try settle(r, at: 212)
            }),
            ("runtime-custody-ownership-failure-pending", {
                let r = try registry(); try r.beginCase("first", now: 101)
                let t = try r.reserveSpawn(now: 102); try r.register(t) { _ in .ownershipFailure }
                r.cancel(.cancelled, now: 103); r.tick(now: 115)
                Thread.sleep(forTimeInterval: 0.01)
                try check(r.snapshot().children == 1 && r.snapshot().reaped == 0 && !r.snapshot().cleanupComplete, "unknown ownership became cleanup")
                try refuses { try r.finishCase("first", assertionPassed: false, now: 116) }
            }),
            ("runtime-custody-assertion-failure-closes-admission", {
                let r = try registry(); try r.beginCase("first", now: 101)
                try refuses { try r.finishCase("first", assertionPassed: false, now: 102) }
                try check(r.snapshot().cleanupComplete && !r.snapshot().succeeded, "failed assertion became success")
                try refuses { try r.beginCase("second", now: 103) }
            })
        ]
        var passed: [String] = []
        for (name, body) in tests {
            try RuntimeFixtureSession.withCase(name) { try body() }
            passed.append(name); onPass(name)
        }
        return passed
    }
}
#endif
