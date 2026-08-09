// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexProviderManager",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ProviderCore", targets: ["ProviderCore"]),
        .executable(name: "CodexProviderManager", targets: ["ProviderManagerApp"]),
        .executable(name: "IntegrationProbe", targets: ["IntegrationProbe"])
    ],
    targets: [
        .target(
            name: "ProviderCore",
            path: "Sources/ProviderCore",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "ProviderManagerApp",
            dependencies: ["ProviderCore"],
            path: "App",
            resources: [.process("../Resources")]
        ),
        .executableTarget(
            name: "IntegrationProbe",
            dependencies: ["ProviderCore"],
            path: "Tools/IntegrationProbe",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "ProviderCoreTests",
            dependencies: ["ProviderCore"],
            path: "Tests/ProviderCoreTests"
        )
    ]
)
