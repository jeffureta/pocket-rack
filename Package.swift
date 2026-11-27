// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PocketRack",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "PocketRackCore",
            targets: ["PocketRackCore"]
        ),
        .executable(
            name: "pocketrack-cli",
            targets: ["PocketRackCLI"]
        ),
    ],
    targets: [
        .target(
            name: "PocketRackCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "PocketRackCLI",
            dependencies: ["PocketRackCore"]
        ),
        .testTarget(
            name: "PocketRackCoreTests",
            dependencies: ["PocketRackCore"]
        ),
    ]
)
