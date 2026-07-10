import Testing
import Foundation
@testable import MacSweepCore

final class BrowserModuleTests {

    let testDirectory: URL
    let valuableDirectory: URL

    // swift-testing creates a fresh instance per @Test: init() is the per-test
    // setUp, deinit is the per-test tearDown. Each instance gets a UUID-scoped
    // temp dir so parallel test execution can't collide.
    init() throws {
        // Cleanup validation intentionally permits symlinks whose targets stay
        // under the user's home directory. Keep these fixtures there so the
        // adversarial tests exercise BrowserModule's deletion code instead of
        // being short-circuited by SafetyChecker's outside-home guard.
        testDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/MacSweepBrowserModuleTests-\(UUID().uuidString)")
        valuableDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".MacSweepBrowserValuableTests-\(UUID().uuidString)")

        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: valuableDirectory,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: testDirectory)
        try? FileManager.default.removeItem(at: valuableDirectory)
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

    // MARK: - Symlink-safe cleanup

    @Test func cleanRejectsCacheRootSymlinkWithoutTouchingTargetOrClaimingBytes() async throws {
        let fm = FileManager.default
        let valuable = valuableDirectory.appendingPathComponent("root-target")
        let nested = valuable.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let document = valuable.appendingPathComponent("document.txt")
        let photo = nested.appendingPathComponent("photo.jpg")
        try Data("valuable document".utf8).write(to: document)
        try Data("valuable photo".utf8).write(to: photo)

        let cacheLink = testDirectory.appendingPathComponent("Cache")
        try fm.createSymbolicLink(at: cacheLink, withDestinationURL: valuable)

        let module = BrowserCleanupTestModule(basePath: testDirectory)
        let result = try await module.clean(
            items: [cleanupItem(at: cacheLink, moduleID: module.id)],
            dryRun: false
        )

        #expect(result.itemsProcessed == 0)
        #expect(result.bytesFreed == 0,
                "A replacement symlink must not receive the stale scanned cache byte credit")
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.message.contains("symbolic link") == true)
        #expect((try? fm.destinationOfSymbolicLink(atPath: cacheLink.path)) != nil,
                "The explicit root policy is to reject and preserve the symlink node")
        #expect(fm.fileExists(atPath: valuable.path), "The target directory must survive")
        #expect(fm.fileExists(atPath: document.path), "Every target child must survive")
        #expect(fm.fileExists(atPath: photo.path), "Nested target children must survive")
    }

    @Test func cleanRejectsSymlinkInCacheRootAncestor() async throws {
        let fm = FileManager.default
        let valuableParent = valuableDirectory.appendingPathComponent("parent-target")
        let realCache = valuableParent.appendingPathComponent("Cache")
        try fm.createDirectory(at: realCache, withIntermediateDirectories: true)
        let document = realCache.appendingPathComponent("document.txt")
        try Data("valuable document".utf8).write(to: document)

        let linkedParent = testDirectory.appendingPathComponent("linked-parent")
        try fm.createSymbolicLink(at: linkedParent, withDestinationURL: valuableParent)
        let cacheThroughLink = linkedParent.appendingPathComponent("Cache")

        let module = BrowserCleanupTestModule(basePath: testDirectory)
        let result = try await module.clean(
            items: [cleanupItem(at: cacheThroughLink, moduleID: module.id)],
            dryRun: false
        )

        #expect(result.itemsProcessed == 0)
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.message.contains("symbolic-link component") == true,
                "The local no-follow walk should reject the symlinked ancestor")
        #expect(fm.fileExists(atPath: document.path),
                "A symlinked ancestor must not redirect cleanup into its target")
        #expect((try? fm.destinationOfSymbolicLink(atPath: linkedParent.path)) != nil,
                "An ancestor outside the cleanup root must be left untouched")
    }

    @Test func cleanUnlinksNestedSymlinkWithoutTouchingTarget() async throws {
        let fm = FileManager.default
        let cache = testDirectory.appendingPathComponent("ordinary/Cache")
        let nestedDirectory = cache.appendingPathComponent("level-one/level-two")
        let valuable = valuableDirectory.appendingPathComponent("nested-target")
        try fm.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: valuable, withIntermediateDirectories: true)
        let document = valuable.appendingPathComponent("document.txt")
        try Data("valuable document".utf8).write(to: document)

        let nestedLink = nestedDirectory.appendingPathComponent("linked-data")
        try fm.createSymbolicLink(at: nestedLink, withDestinationURL: valuable)
        let cacheFile = cache.appendingPathComponent("cached.bin")
        try Data(repeating: 0, count: 4096).write(to: cacheFile)

        let module = BrowserCleanupTestModule(basePath: testDirectory)
        let result = try await module.clean(
            items: [cleanupItem(at: cache, moduleID: module.id)],
            dryRun: false
        )

        #expect(result.itemsProcessed == 1)
        #expect(result.errors.isEmpty)
        #expect(fm.fileExists(atPath: cache.path), "The real cache root should be kept")
        #expect((try? fm.destinationOfSymbolicLink(atPath: nestedLink.path)) == nil,
                "Nested symlink nodes should be unlinked")
        #expect(!fm.fileExists(atPath: cacheFile.path), "Ordinary cache files should be removed")
        #expect(fm.fileExists(atPath: valuable.path), "The nested symlink target must survive")
        #expect(fm.fileExists(atPath: document.path), "The target's children must survive")
    }

    @Test func cleanRecursivelyEmptiesOrdinaryCacheDirectory() async throws {
        let fm = FileManager.default
        let cache = testDirectory.appendingPathComponent("recursive/Cache")
        let nested = cache.appendingPathComponent("a/b")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2048).write(to: cache.appendingPathComponent("top.bin"))
        try Data(repeating: 2, count: 2048).write(to: nested.appendingPathComponent("nested.bin"))

        let module = BrowserCleanupTestModule(basePath: testDirectory)
        let result = try await module.clean(
            items: [cleanupItem(at: cache, moduleID: module.id)],
            dryRun: false
        )

        #expect(result.itemsProcessed == 1)
        #expect(result.errors.isEmpty)
        #expect(fm.fileExists(atPath: cache.path), "Cleanup should keep an ordinary cache root")
        #expect(try fm.contentsOfDirectory(atPath: cache.path).isEmpty,
                "Cleanup should recursively remove ordinary cache contents")
    }

    private func cleanupItem(at path: URL, moduleID: String) -> CleanupItem {
        CleanupItem(
            id: UUID(),
            path: path,
            size: 4096,
            type: .directory,
            module: moduleID,
            moduleName: "Test Browser Cache"
        )
    }
}

private struct BrowserCleanupTestModule: BrowserModule {
    let id = "browser-test"
    let name = "Test Browser"
    let description = "Browser cleanup regression-test module"
    let icon = "globe"
    let browserName = "Test Browser"
    let bundleID = "invalid.macsweep.browser-test"
    let basePath: URL

    let cachePaths: [URL] = []
    let serviceWorkerPaths: [URL] = []
    let localStoragePaths: [URL] = []
    var isRunning: Bool { false }

    func scan() async throws -> [CleanupItem] { [] }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        try await cleanBrowserItems(items, dryRun: dryRun)
    }
}
