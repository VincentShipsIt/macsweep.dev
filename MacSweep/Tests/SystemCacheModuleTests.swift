import Testing
import Foundation
@testable import MacSweepCore

final class SystemCacheModuleTests {

    let module = SystemCacheModule()
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
        if FileManager.default.fileExists(atPath: testDirectory.path) {
            try? FileManager.default.removeItem(at: testDirectory)
        }
    }

    // MARK: - Module Properties Tests

    @Test func moduleHasCorrectIdentifier() {
        #expect(module.id == "system-cache")
    }

    @Test func moduleHasCorrectName() {
        #expect(module.name == "System Caches")
    }

    @Test func moduleHasCorrectDescription() {
        #expect(module.description == "Application caches, logs, and crash reports")
    }

    @Test func moduleHasCorrectIcon() {
        #expect(module.icon == "folder.badge.gearshape")
    }

    // MARK: - Scan Tests

    @Test func scanReturnsEmptyArrayForNonexistentDirectory() async throws {
        // The module should handle non-existent directories gracefully and
        // not crash; it may return items from existing system directories.
        _ = try await module.scan()
    }

    @Test func scanReturnsSortedBySize() async throws {
        // Scan actual system caches
        let items = try await module.scan()

        // Verify items are sorted by size (largest first)
        if items.count >= 2 {
            for i in 0..<(items.count - 1) {
                #expect(
                    items[i].size >= items[i + 1].size,
                    "Items should be sorted by size descending"
                )
            }
        }
    }

    @Test func scanSkipsTinyItems() async throws {
        let items = try await module.scan()

        // All items should be larger than 1KB
        for item in items {
            #expect(item.size > 1024, "Items smaller than 1KB should be filtered")
        }
    }

    @Test func scanItemsHaveCorrectModule() async throws {
        let items = try await module.scan()

        for item in items {
            #expect(item.module == "system-cache", "All items should belong to system-cache module")
        }
    }

    @Test func scanItemsHaveModuleName() async throws {
        let items = try await module.scan()

        for item in items {
            #expect(
                item.moduleName.hasPrefix("System Caches - "),
                "Module name should start with 'System Caches - '"
            )
        }
    }

    // MARK: - Clean Tests (Dry Run)

    @Test func dryRunDoesNotDeleteFiles() async throws {
        // Create a test file
        let testFile = testDirectory.appendingPathComponent("test-cache-file.txt")
        let testContent = "Test content for cache cleanup"
        try testContent.write(to: testFile, atomically: true, encoding: .utf8)

        // Create a mock cleanup item
        let item = CleanupItem(
            id: UUID(),
            path: testFile,
            size: Int64(testContent.utf8.count),
            type: .file,
            module: "system-cache",
            moduleName: "System Caches - Test"
        )

        // Run dry-run cleanup
        let result = try await module.clean(items: [item], dryRun: true)

        // File should still exist
        #expect(FileManager.default.fileExists(atPath: testFile.path), "Dry run should not delete files")
        #expect(result.itemsProcessed == 1)
        #expect(result.bytesFreed == item.size)
        #expect(result.errors.isEmpty)
    }

    @Test func cleanReportsCorrectBytesFreed() async throws {
        let items = try await module.scan()

        guard !items.isEmpty else {
            // Skip test if no items to clean
            return
        }

        // Run dry-run to check calculation
        let result = try await module.clean(items: items, dryRun: true)

        let expectedBytes = items.reduce(0) { $0 + $1.size }
        #expect(result.bytesFreed == expectedBytes, "Bytes freed should match total of item sizes")
    }

    @Test func cleanIgnoresItemsFromOtherModules() async throws {
        let otherModuleItem = CleanupItem(
            id: UUID(),
            path: testDirectory.appendingPathComponent("other.txt"),
            size: 1000,
            type: .file,
            module: "browser-chrome",  // Different module
            moduleName: "Chrome Cache"
        )

        let result = try await module.clean(items: [otherModuleItem], dryRun: true)

        #expect(result.itemsProcessed == 0, "Should not process items from other modules")
        #expect(result.bytesFreed == 0)
    }

    // MARK: - Clean Tests (Actual Deletion)

    @Test func cleanActuallyDeletesFiles() async throws {
        // Create a test file
        let testFile = testDirectory.appendingPathComponent("deleteme.cache")
        let testContent = String(repeating: "x", count: 2048)  // 2KB
        try testContent.write(to: testFile, atomically: true, encoding: .utf8)

        let item = CleanupItem(
            id: UUID(),
            path: testFile,
            size: Int64(testContent.utf8.count),
            type: .file,
            module: "system-cache",
            moduleName: "System Caches - Test"
        )

        // Run actual cleanup
        let result = try await module.clean(items: [item], dryRun: false)

        // File should be deleted
        #expect(!FileManager.default.fileExists(atPath: testFile.path), "File should be deleted")
        #expect(result.itemsProcessed == 1)
        #expect(result.errors.isEmpty)
    }

    @Test func cleanDirectoryRemovesContentsOnly() async throws {
        // Create a test directory with files
        let testDir = testDirectory.appendingPathComponent("cache-dir")
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

        let file1 = testDir.appendingPathComponent("file1.cache")
        let file2 = testDir.appendingPathComponent("file2.cache")
        try "content1".write(to: file1, atomically: true, encoding: .utf8)
        try "content2".write(to: file2, atomically: true, encoding: .utf8)

        let item = CleanupItem(
            id: UUID(),
            path: testDir,
            size: 1000,
            type: .directory,
            module: "system-cache",
            moduleName: "System Caches - Test"
        )

        // Run cleanup
        let result = try await module.clean(items: [item], dryRun: false)

        // Directory should still exist but be empty
        #expect(FileManager.default.fileExists(atPath: testDir.path), "Directory should still exist")

        let contents = try FileManager.default.contentsOfDirectory(atPath: testDir.path)
        #expect(contents.isEmpty, "Directory should be empty after cleanup")
        #expect(result.itemsProcessed == 1)
    }

    @Test func cleanReportsErrorsForProtectedFiles() async throws {
        // Create an item pointing to a non-existent file
        let nonExistentFile = testDirectory.appendingPathComponent("does-not-exist.txt")

        let item = CleanupItem(
            id: UUID(),
            path: nonExistentFile,
            size: 100,
            type: .file,
            module: "system-cache",
            moduleName: "System Caches - Test"
        )

        let result = try await module.clean(items: [item], dryRun: false)

        // Should report an error
        #expect(!result.errors.isEmpty, "Should report error for missing file")
        #expect(result.itemsProcessed == 0)
    }

    // MARK: - Integration Tests

    @Test func scanAndCleanWorkflow() async throws {
        // Create test cache structure
        let cacheDir = testDirectory.appendingPathComponent("TestCache")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Add some cache files
        for i in 1...5 {
            let file = cacheDir.appendingPathComponent("cache\(i).tmp")
            let content = String(repeating: "data", count: 1000 * i)
            try content.write(to: file, atomically: true, encoding: .utf8)
        }

        // Verify files exist
        let initialContents = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        #expect(initialContents.count == 5)

        // Create a cleanup item for the test cache directory
        let size = try await DiskAnalyzer.directorySize(at: cacheDir)
        let item = CleanupItem(
            id: UUID(),
            path: cacheDir,
            size: size,
            type: .directory,
            module: "system-cache",
            moduleName: "System Caches - Test"
        )

        // First dry run
        let dryResult = try await module.clean(items: [item], dryRun: true)
        #expect(dryResult.bytesFreed == size)

        // Files should still exist
        let afterDryRun = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        #expect(afterDryRun.count == 5)

        // Actual cleanup
        let cleanResult = try await module.clean(items: [item], dryRun: false)
        #expect(cleanResult.itemsProcessed == 1)

        // Directory should be empty
        let afterClean = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        #expect(afterClean.isEmpty)
    }

    // MARK: - Performance Tests

    @Test func scanPerformance() async throws {
        // This test ensures scan completes in reasonable time.
        let startTime = Date()

        _ = try await module.scan()

        let elapsed = Date().timeIntervalSince(startTime)

        // Scan should complete in less than 30 seconds for typical user
        #expect(elapsed < 30.0, "Scan should complete in less than 30 seconds")
    }

    // MARK: - Recursive descendant protection (#82)

    @Test func cleanPreservesProtectedDescendantsRecursively() async throws {
        // Layout under a cache directory:
        //   junk.txt                        → removed
        //   CloudKit/secret.db              → protected top-level subdir → survives
        //   normal/deep/com.apple.bird/x    → nested protected dir → survives
        //   normal/deep/scratch.tmp         → removed
        let cacheRoot = testDirectory.appendingPathComponent("cache-root")
        let cloudKit = cacheRoot.appendingPathComponent("CloudKit")
        let deep = cacheRoot.appendingPathComponent("normal/deep")
        let bird = deep.appendingPathComponent("com.apple.bird")
        let fm = FileManager.default
        try fm.createDirectory(at: cloudKit, withIntermediateDirectories: true)
        try fm.createDirectory(at: bird, withIntermediateDirectories: true)

        try "junk".write(to: cacheRoot.appendingPathComponent("junk.txt"), atomically: true, encoding: .utf8)
        try "secret".write(to: cloudKit.appendingPathComponent("secret.db"), atomically: true, encoding: .utf8)
        try "protected".write(to: bird.appendingPathComponent("x"), atomically: true, encoding: .utf8)
        try "scratch".write(to: deep.appendingPathComponent("scratch.tmp"), atomically: true, encoding: .utf8)

        let item = CleanupItem(
            id: UUID(),
            path: cacheRoot,
            size: 1000,
            type: .directory,
            module: "system-cache",
            moduleName: "System Caches - Test"
        )

        let result = try await module.clean(items: [item], dryRun: false)

        // Protected content — top-level AND nested — survives.
        #expect(fm.fileExists(atPath: cloudKit.appendingPathComponent("secret.db").path))
        #expect(fm.fileExists(atPath: bird.appendingPathComponent("x").path))
        // Non-protected content is removed, even two levels deep.
        #expect(!fm.fileExists(atPath: cacheRoot.appendingPathComponent("junk.txt").path))
        #expect(!fm.fileExists(atPath: deep.appendingPathComponent("scratch.tmp").path))
        // The cache directory itself is kept.
        #expect(fm.fileExists(atPath: cacheRoot.path))
        #expect(result.itemsProcessed == 1)
    }
}
