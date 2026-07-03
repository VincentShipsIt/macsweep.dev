import Testing
import Foundation
@testable import MacSweepCore

final class BrowserModuleTests {

    let testDirectory: URL

    // swift-testing creates a fresh instance per @Test: init() is the per-test
    // setUp, deinit is the per-test tearDown. Each instance gets a UUID-scoped
    // temp dir so parallel test execution can't collide.
    init() throws {
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSweepTests-\(UUID().uuidString)")

        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: testDirectory)
    }

    /// A cache directory larger than the 1KB threshold.
    private func makeCacheFixture(named name: String) throws -> URL {
        let dir = testDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 4096).write(to: dir.appendingPathComponent("cached.bin"))
        return dir
    }

    // MARK: - Shared scanPath (#115: all six browsers must report lastModified)

    @Test func scanPathComputesLastModifiedForEveryBrowser() async throws {
        // One shared implementation now backs all six modules; exercising it
        // through several conforming types guards against a per-browser copy
        // reappearing with the old `lastModified: nil` divergence.
        let modules: [any BrowserModule] = [
            ChromeModule(), SafariModule(), FirefoxModule(),
            BraveModule(), ArcModule(), EdgeModule()
        ]

        for (index, module) in modules.enumerated() {
            let fixture = try makeCacheFixture(named: "cache-\(index)")
            let item = try #require(await module.scanPath(fixture, category: "Cache"))

            #expect(item.lastModified != nil, "\(module.browserName) must report lastModified")
            #expect(item.size > 1024)
            #expect(item.type == .directory)
            #expect(item.module == module.id)
            #expect(item.moduleName == "\(module.browserName) Cache")
        }
    }

    @Test func scanPathReturnsNilForMissingDirectory() async {
        let missing = testDirectory.appendingPathComponent("does-not-exist")
        let item = await ChromeModule().scanPath(missing, category: "Cache")
        #expect(item == nil)
    }

    @Test func scanPathSkipsTinyDirectories() async throws {
        // An empty directory sizes to 0 bytes — below the 1KB threshold. (Any
        // file, however small, still allocates a full filesystem block.)
        let dir = testDirectory.appendingPathComponent("tiny")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let item = await ChromeModule().scanPath(dir, category: "Cache")
        #expect(item == nil)
    }
}
