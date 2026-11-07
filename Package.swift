// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ShadowSync",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "ShadowSync", targets: ["ShadowSyncApp"]),
        .executable(name: "ShadowSyncLifecycleCoordinator", targets: ["ShadowSyncLifecycleCoordinator"]),
        .library(name: "ShadowSyncCatalog", targets: ["ShadowSyncCatalog"]),
    ],
    targets: [
        .target(
            name: "ShadowSyncCatalog",
            path: "Sources/ShadowSyncCatalog"
        ),
        .target(
            name: "ShadowSyncCore",
            dependencies: ["ShadowSyncCatalog"],
            path: "Sources/ShadowSyncCore",
            linkerSettings: [.linkedLibrary("bsm")]
        ),
        .executableTarget(
            name: "ShadowSyncApp",
            dependencies: ["ShadowSyncCatalog", "ShadowSyncCore"],
            path: "Sources/ShadowSyncApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(
            name: "ShadowSyncLifecycleCoordinator",
            dependencies: ["ShadowSyncCore"],
            path: "Sources/ShadowSyncLifecycleCoordinator"
        ),
        .executableTarget(
            name: "ShadowSyncSelfTest",
            dependencies: ["ShadowSyncCatalog", "ShadowSyncCore"],
            path: "Tests/ShadowSyncSelfTests",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "ShadowSyncCompileTests",
            dependencies: ["ShadowSyncCatalog", "ShadowSyncCore"],
            path: "Tests/ShadowSyncCompileTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
