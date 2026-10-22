import Foundation
import Testing

@testable import MacSweepCore

final class BraveLiveCleanupTests {
    @Test func runningBraveSkipsAndOfflineCleanupPreservesSessionStores() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/MacSweepBraveSessionFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let module = BraveFixtureModule(basePath: root, isRunning: true)
        for name in ["Cache", "Service Worker", "Local Storage", "Session Storage"] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: directory.appendingPathComponent("fixture.bin"))
        }
        for name in ["Cookies", "Login Data"] {
            try Data("login preserved".utf8).write(to: root.appendingPathComponent(name))
        }
        let items = try await module.scan()
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.cleanupReviewReason == BrowserLiveCleanupCapability.braveDetail })
        do {
            _ = try await module.clean(items: items, dryRun: false)
            Issue.record("Running Brave must remain protected")
        } catch { #expect(error.localizedDescription.contains("Brave stays open")) }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Cache/fixture.bin").path))
        let offline = BraveFixtureModule(basePath: root, isRunning: false)
        let result = try await offline.clean(items: try await offline.scan(), dryRun: false)
        #expect(result.itemsProcessed == 2)
        for name in ["Cookies", "Login Data"] {
            #expect(try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) == "login preserved")
        }
        for name in ["Local Storage", "Session Storage"] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(name)/fixture.bin").path))
        }
    }
}

private struct BraveFixtureModule: BrowserModule {
    let id = "browser-brave"
    let name = "Brave"
    let description = "fixture"
    let icon = "shield"
    let browserName = "Brave"
    let bundleID = "dev.macsweep.test.brave"
    let basePath: URL
    let isRunning: Bool
    var cachePaths: [URL] { [basePath.appendingPathComponent("Cache")] }
    var serviceWorkerPaths: [URL] { [basePath.appendingPathComponent("Service Worker")] }
    var localStoragePaths: [URL] { [basePath.appendingPathComponent("Local Storage")] }
    func scan() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []
        for path in cachePaths + serviceWorkerPaths {
            if let item = await scanPath(path, category: "Cache") { items.append(item) }
        }
        return items
    }
    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        try await cleanBrowserItems(items, dryRun: dryRun)
    }
}
