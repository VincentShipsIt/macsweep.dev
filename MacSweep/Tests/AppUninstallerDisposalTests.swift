import Testing
import Foundation
@testable import MacSweepCore

/// Coverage for the app-uninstall disposal path (#120): the running-app guard,
/// disposal accounting, and leftover discovery. `AppUninstaller`'s running-check
/// and trash hooks are injected so the guard/accounting assertions are
/// deterministic and never write to the user's Trash; `LeftoverScanner` takes
/// injected locations so it scans a fixture Library tree, never the real one.
/// (The SafetyChecker gates themselves are covered in AppUninstallerModuleTests.)
final class AppUninstallerDisposalTests {

    private let temp: TempTestDirectory

    init() throws {
        temp = try TempTestDirectory(prefix: "MacSweepUninstallTests")
    }

    // MARK: - Fixtures

    /// Spy trasher recording every disposed URL; throws for paths in `failing`.
    private final class TrashSpy: @unchecked Sendable {
        var trashed: [URL] = []
        var failing: Set<String> = []

        func trash(_ url: URL) throws {
            if failing.contains(url.lastPathComponent) {
                throw CocoaError(.fileWriteNoPermission)
            }
            trashed.append(url)
        }
    }

    /// Apps live under a ~/Applications-shaped bundle path so the #81
    /// bundle-removal gate admits them (and the /Applications writability probe
    /// doesn't fire for a nonexistent fixture); leftovers under a real leftover
    /// root path shape so the #76 leftover gate admits them. Nothing is ever
    /// written to those locations — the injected trash spy intercepts disposal.
    private func makeApp(
        named name: String,
        bundleID: String? = nil,
        bundleSize: Int64 = 1_000,
        leftovers: [AppLeftover] = []
    ) -> InstalledApp {
        var app = InstalledApp(
            id: bundleID ?? "com.example.\(name.lowercased())",
            name: name,
            bundlePath: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Applications/\(name).app"),
            version: "1.0",
            bundleSize: bundleSize,
            icon: nil,
            lastUsed: nil
        )
        app.leftovers = leftovers
        return app
    }

    private func makeLeftover(named name: String, size: Int64) -> AppLeftover {
        AppLeftover(
            id: UUID(),
            path: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Preferences/\(name)"),
            size: size,
            type: .preferences
        )
    }

    private func makeUninstaller(spy: TrashSpy, running: Bool = false) -> AppUninstaller {
        var uninstaller = AppUninstaller()
        uninstaller.isAppRunning = { _ in running }
        uninstaller.trashItem = { try spy.trash($0) }
        return uninstaller
    }

    // MARK: - Guards

    @Test func uninstallRefusesRunningApp() async throws {
        let spy = TrashSpy()
        let uninstaller = makeUninstaller(spy: spy, running: true)
        let app = makeApp(named: "Running")

        await #expect(throws: UninstallError.self) {
            try await uninstaller.uninstall(app)
        }
        #expect(spy.trashed.isEmpty, "Nothing may be disposed once the running guard fires")
    }

    @Test func uninstallThrowsWhenBundleCannotBeRemoved() async throws {
        let spy = TrashSpy()
        spy.failing = ["Stuck.app"]
        let uninstaller = makeUninstaller(spy: spy)
        let app = makeApp(named: "Stuck", leftovers: [makeLeftover(named: "stuck.plist", size: 10)])

        await #expect(throws: UninstallError.self) {
            try await uninstaller.uninstall(app)
        }
        #expect(spy.trashed.isEmpty, "Leftovers must not be disposed when the bundle removal fails")
    }

    // MARK: - Accounting

    @Test func uninstallDisposesBundleAndLeftovers() async throws {
        let spy = TrashSpy()
        let uninstaller = makeUninstaller(spy: spy)
        let leftovers = [
            makeLeftover(named: "com.example.demo.plist", size: 200),
            makeLeftover(named: "com.example.demo.extras.plist", size: 300),
        ]
        let app = makeApp(named: "Demo", bundleSize: 1_000, leftovers: leftovers)

        let result = try await uninstaller.uninstall(app)

        #expect(result.itemsProcessed == 3)
        #expect(result.bytesFreed == 1_500)
        #expect(result.errors.isEmpty)
        #expect(spy.trashed.count == 3)
        #expect(spy.trashed.first?.lastPathComponent == "Demo.app")
    }

    @Test func uninstallWithoutLeftoversKeepsThem() async throws {
        let spy = TrashSpy()
        let uninstaller = makeUninstaller(spy: spy)
        let app = makeApp(named: "Solo", bundleSize: 500, leftovers: [makeLeftover(named: "solo.plist", size: 100)])

        let result = try await uninstaller.uninstall(app, includeLeftovers: false)

        #expect(result.itemsProcessed == 1)
        #expect(result.bytesFreed == 500)
        #expect(spy.trashed.map(\.lastPathComponent) == ["Solo.app"])
    }

    @Test func uninstallCollectsLeftoverErrorsWithoutAborting() async throws {
        let spy = TrashSpy()
        spy.failing = ["broken.plist"]
        let uninstaller = makeUninstaller(spy: spy)
        let leftovers = [
            makeLeftover(named: "broken.plist", size: 100),
            makeLeftover(named: "ok.plist", size: 50),
        ]
        let app = makeApp(named: "Partial", bundleSize: 1_000, leftovers: leftovers)

        let result = try await uninstaller.uninstall(app)

        // Bundle + the one removable leftover; the failure is surfaced, not fatal.
        #expect(result.itemsProcessed == 2)
        #expect(result.bytesFreed == 1_050)
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.path.lastPathComponent == "broken.plist")
    }

    // MARK: - LeftoverScanner (fixture Library tree)

    private func makeFixtureLibrary() throws -> [(URL, AppLeftover.LeftoverType)] {
        let preferences = temp.appendingPathComponent("Library/Preferences")
        let appSupport = temp.appendingPathComponent("Library/Application Support")
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return [(preferences, .preferences), (appSupport, .applicationSupport)]
    }

    @Test func findLeftoversMatchesBundleIDAndAppName() async throws {
        let locations = try makeFixtureLibrary()
        try Data(repeating: 0, count: 64).write(to: locations[0].0.appendingPathComponent("com.example.demo.plist"))
        try FileManager.default.createDirectory(
            at: locations[1].0.appendingPathComponent("Demo"), withIntermediateDirectories: true)
        try Data(repeating: 0, count: 4096).write(to: locations[1].0.appendingPathComponent("Demo/state.bin"))
        try Data(repeating: 0, count: 64).write(to: locations[0].0.appendingPathComponent("com.other.tool.plist"))

        let app = makeApp(named: "Demo")
        let leftovers = await LeftoverScanner(leftoverLocations: locations).findLeftovers(for: app, among: [app])

        let names = Set(leftovers.map(\.path.lastPathComponent))
        #expect(names.contains("com.example.demo.plist"))
        #expect(names.contains("Demo"))
        #expect(!names.contains("com.other.tool.plist"))
    }

    @Test func findLeftoversDoesNotAssignInstalledCanaryDataToStableApp() async throws {
        let locations = try makeFixtureLibrary()
        for name in [
            "com.vendor.app.plist",
            "com.vendor.app.helper.plist",
            "com.vendor.app.canary.plist",
            "com.vendor.app.beta.plist",
        ] {
            try Data(repeating: 0, count: 64).write(to: locations[0].0.appendingPathComponent(name))
        }

        let stable = makeApp(named: "Vendor App", bundleID: "com.vendor.app")
        let canary = makeApp(named: "Vendor App Canary", bundleID: "com.vendor.app.canary")
        let beta = makeApp(named: "Vendor App Beta", bundleID: "com.vendor.app.beta")
        let scanner = LeftoverScanner(leftoverLocations: locations)

        let stableNames = Set((await scanner.findLeftovers(for: stable, among: [stable, canary, beta]))
            .map(\.path.lastPathComponent))
        let canaryNames = Set((await scanner.findLeftovers(for: canary, among: [stable, canary, beta]))
            .map(\.path.lastPathComponent))
        let betaNames = Set((await scanner.findLeftovers(for: beta, among: [stable, canary, beta]))
            .map(\.path.lastPathComponent))

        #expect(stableNames == ["com.vendor.app.plist", "com.vendor.app.helper.plist"])
        #expect(canaryNames == ["com.vendor.app.canary.plist"])
        #expect(betaNames == ["com.vendor.app.beta.plist"])
    }

    @Test func findOrphanedLeftoversSkipsInstalledApps() async throws {
        let locations = try makeFixtureLibrary()
        // > 1KB so the orphan-size floor doesn't drop the fixtures.
        try Data(repeating: 0, count: 8_192).write(to: locations[0].0.appendingPathComponent("com.gone.app.plist"))
        try Data(repeating: 0, count: 8_192).write(to: locations[0].0.appendingPathComponent("com.installed.app.plist"))

        let orphans = await LeftoverScanner(leftoverLocations: locations)
            .findOrphanedLeftovers(installedBundleIDs: ["com.installed.app"])

        let names = Set(orphans.map(\.path.lastPathComponent))
        #expect(names.contains("com.gone.app.plist"))
        #expect(!names.contains("com.installed.app.plist"))
    }
}
