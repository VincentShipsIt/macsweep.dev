// swift-tools-version: 6.2
import PackageDescription

// MARK: - Running the tests
//
// The suite is written against swift-testing (`import Testing`), which SwiftPM
// only auto-discovers at tools-version 6.0+. How you run it depends on the host:
//
//   * Full Xcode (e.g. CI's macos runner): plain `swift test` just works.
//   * Command Line Tools only (no Xcode.app): CLT bundles Testing.framework but
//     NOT the `xctest` host tool, so SwiftPM's default `.xctest`-bundle path
//     silently no-ops. Use `Scripts/test.sh`, which passes `--disable-xctest`
//     (build a standalone swift-testing runner instead of a bundle) plus the CLT
//     framework search path and rpaths inline so they reach that runner product.
//
// Flags are intentionally NOT baked into the test target here: target-scoped
// unsafeFlags never reach the synthesized `*PackageTests` runner, so they'd
// compile a bundle that never executes — a silent-pass footgun. Keeping them out
// means plain `swift test` on a CLT-only host fails loudly instead.

let package = Package(
    name: "MacSweep",
    platforms: [
        .macOS(.v26)
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
    ],
    // Keep targets in Swift 5 language mode. The tools-version is 6.2 — required
    // both for SwiftPM's swift-testing test runner and for the `.macOS(.v26)`
    // platform, which PackageDescription only exposes at 6.2+. The language mode
    // stays at .v5: the existing sources are not audited for Swift 6 strict
    // concurrency and must keep compiling as-is.
    swiftLanguageModes: [.v5]
)
