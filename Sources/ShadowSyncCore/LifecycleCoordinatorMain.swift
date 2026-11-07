import Foundation

/// Executable bootstrap for the source-free lifecycle authority. Verification
/// does not initialize state or authorize replacement. The enclosing install,
/// migration and update transactions retain their separate admission gates.
public enum LifecycleCoordinatorMain {
    public static func run(arguments: [String]) -> Int32 {
        if let result = CommandCustodian.dispatchLifecycle(arguments) { return result }
        guard arguments.count == 2 else { return usage() }
        switch arguments[1] {
        case "--help":
            print("ShadowSyncLifecycleCoordinator --verify-distribution")
            return 0
        case "--verify-distribution": break
        default: return usage()
        }
        #if SHADOW_SYNC_TESTING
        // A test build must not resolve a real account/state path or authenticate
        // itself as a production installer, even if separately signed.
        FileHandle.standardError.write(Data("Testing coordinators cannot verify production distributions.\n".utf8))
        return 78
        #else
        do {
            let publisher = try LifecyclePublisher.current()
            try publisher.revalidate()
            print("ShadowSync distribution publisher verified; installation has not run.")
            return 0
        } catch {
            // No raw paths, identity details or caller-controlled error text.
            FileHandle.standardError.write(Data("ShadowSync distribution verification failed.\n".utf8))
            return 1
        }
        #endif
    }
    private static func usage() -> Int32 {
        FileHandle.standardError.write(Data("ShadowSync lifecycle coordinator arguments are invalid.\n".utf8))
        return 64
    }
}
