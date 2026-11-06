#if SHADOW_SYNC_TESTING
import Darwin
import Foundation

/// Testing adapter for this function's own suspended spawn. There is no API to
/// register a PID or a preexisting anchor, and no generic command entrypoint.
enum RuntimeFixtureSpawn {
    static func spawn(
        registry: RuntimeFixtureCustody,
        executable: String,
        actions: inout posix_spawn_file_actions_t?,
        attributes: inout posix_spawnattr_t?,
        arguments: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        environment: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        streamsDrained: @escaping @Sendable () -> Bool,
        cooperativeStop: (@Sendable () -> Void)? = nil,
        beforeRegistration: (() -> Void)? = nil
    ) throws -> OwnedSpawnAnchor {
        let registries = try RuntimeFixtureSession.registrationRegistries(for: registry)
        var reservations: [(RuntimeFixtureCustody, RuntimeFixtureCustody.Ticket)] = []
        do {
            for participant in registries {
                reservations.append((participant, try participant.reserveSpawn(now: DispatchTime.now().uptimeNanoseconds)))
            }
        } catch {
            for (participant, ticket) in reservations { try? participant.spawnFailed(ticket) }
            throw error
        }
        let participants = reservations
        guard participants.allSatisfy({ $0.0.permitsSpawn($0.1, now: DispatchTime.now().uptimeNanoseconds) }) else {
            for (participant, ticket) in participants { try participant.spawnFailed(ticket) }
            throw RuntimeFixtureCustody.Failure.admissionClosed
        }
        let anchor: OwnedSpawnAnchor
        do {
            anchor = try OwnedSpawnAnchor.spawn(executable: executable, actions: &actions,
                attributes: &attributes, arguments: arguments, environment: environment)
        } catch {
            for (participant, ticket) in participants { try participant.spawnFailed(ticket) }
            throw error
        }
        // This test barrier models cancellation crossing a successful syscall.
        // The unreleased reservation and this exact anchor remain retained.
        beforeRegistration?()
        let installed = anchor.testingInstallRuntimeResumeGate({ action in
            func resume(_ index: Int) -> Bool {
                guard index < participants.count else { return action() }
                let (participant, ticket) = participants[index]
                return participant.performResume(ticket, now: DispatchTime.now().uptimeNanoseconds) { resume(index + 1) }
            }
            return resume(0)
        }, requestDrain: {
            for (participant, ticket) in participants {
                participant.requestDrain(ticket, now: DispatchTime.now().uptimeNanoseconds)
            }
        }, retired: { participants.allSatisfy { $0.0.isRetired($0.1) } })
        do {
            guard installed else { throw RuntimeFixtureCustody.Failure.invalidTicket }
            for (participant, ticket) in participants {
                try participant.register(ticket) { directive in
                    anchor.testingRuntimeStep(directive, streamsDrained: streamsDrained(), cooperativeStop: cooperativeStop)
                }
            }
        } catch {
            // Registration cannot normally fail for this private ticket. If it
            // does, preserve original custody until actual cleanup; never throw
            // away a successful spawn because metadata bookkeeping failed.
            for (participant, _) in participants { participant.cancel(.assertion, now: DispatchTime.now().uptimeNanoseconds) }
            while true {
                _ = anchor.killSuspended()
                if case .reaped = anchor.poll() { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            for (participant, ticket) in participants { try? participant.spawnFailed(ticket) }
            throw error
        }
        for (participant, _) in participants { participant.tick(now: DispatchTime.now().uptimeNanoseconds) }
        return anchor
    }
}
#endif
