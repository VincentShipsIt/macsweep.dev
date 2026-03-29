// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacSweep",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MacSweepCore", targets: ["MacSweepCore"]),
        .executable(name: "macsweep", targets: ["MacSweepCLI"])
    ],
    targets: [
        .target(
            name: "MacSweepCore",
            path: "Sources/Core"
        ),
        .target(
            name: "MacSweepCLIKit",
            dependencies: ["MacSweepCore"],
            path: "Sources/CLIKit"
        ),
        .executableTarget(
            name: "MacSweepCLI",
            dependencies: ["MacSweepCLIKit"],
            path: "Sources/CLI"
        ),
        .testTarget(
            name: "MacSweepTests",
            dependencies: ["MacSweepCore", "MacSweepCLIKit"],
            path: "Tests"
        )
    ]
)
