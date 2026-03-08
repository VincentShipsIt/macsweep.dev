// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacSweep",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacSweep", targets: ["MacSweep"])
    ],
    targets: [
        .executableTarget(
            name: "MacSweep",
            path: "Sources",
            resources: [
                .process("Info.plist")
            ]
        ),
        .testTarget(
            name: "MacSweepTests",
            dependencies: ["MacSweep"],
            path: "Tests"
        )
    ]
)
