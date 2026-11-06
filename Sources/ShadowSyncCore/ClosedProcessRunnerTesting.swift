#if SHADOW_SYNC_TESTING
import Foundation

/// Per-instance, source-owned interleavings. Never selected by production argv,
/// environment, persisted data or a caller-supplied executable command protocol.
struct ClosedProcessRunnerTestingHooks {
    var beforeSpawn: (() throws -> Void)?
    var afterSpawn: (() -> Void)?
    var beforeTransfer: ((OwnedSpawnAnchor) throws -> Void)?
    var rejectTransfer = false
    var afterTransfer: ((OwnedSpawnAnchor, OwnedDirectChild) throws -> Void)?
    var beforeResume: ((OwnedSpawnAnchor, OwnedDirectChild) throws -> Void)?
    var afterResume: ((OwnedSpawnAnchor, OwnedDirectChild?, Bool) throws -> Void)?
    var duringDrain: ((OwnedDirectChild?, Int, Int, Bool, Bool) throws -> Void)?
}
#endif
