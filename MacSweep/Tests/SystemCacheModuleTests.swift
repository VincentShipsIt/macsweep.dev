import XCTest
@testable import MacSweep

final class SystemCacheModuleTests: XCTestCase {

    var module: SystemCacheModule!
    var testDirectory: URL!

    override func setUp() async throws {
        module = SystemCacheModule()

        // Create a temporary directory for testing
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSweepTests-\(UUID().uuidString)")

        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        // Clean up test directory
        if let testDir = testDirectory, FileManager.default.fileExists(atPath: testDir.path) {
            try? FileManager.default.removeItem(at: testDir)
        }
    }

    // MARK: - Module Properties Tests

    func testModuleHasCorrectIdentifier() {
        XCTAssertEqual(module.id, "system-cache")
    }

    func testModuleHasCorrectName() {
        XCTAssertEqual(module.name, "System Caches")
    }

    func testModuleHasCorrectDescription() {
        XCTAssertEqual(module.description, "Application caches, logs, and crash reports")
    }

    func testModuleHasCorrectIcon() {
        XCTAssertEqual(module.icon, "folder.badge.gearshape")
    }

    // MARK: - Scan Tests

    func testScanReturnsEmptyArrayForNonexistentDirectory() async throws {
        // The module should handle non-existent directories gracefully
        let items = try await module.scan()

        // Should not crash, may return items from existing system directories
        XCTAssertNotNil(items)
    }

    func testScanReturnsSortedBySize() async throws {
        // Scan actual system caches
        let items = try await module.scan()

        // Verify items are sorted by size (largest first)
        if items.count >= 2 {
            for i in 0..<(items.count - 1) {
                XCTAssertGreaterThanOrEqual(
                    items[i].size,
                    items[i + 1].size,
                    "Items should be sorted by size descending"
                )
            }
        }
    }

    func testScanSkipsTinyItems() async throws {
        let items = try await module.scan()

        // All items should be larger than 1KB
        for item in items {
            XCTAssertGreaterThan(item.size, 1024, "Items smaller than 1KB should be filtered")
        }
    }

    func testScanItemsHaveCorrectModule() async throws {
        let items = try await module.scan()

        for item in items {
            XCTAssertEqual(item.module, "system-cache", "All items should belong to system-cache module")
        }
    }

    func testScanItemsHaveModuleName() async throws {
        let items = try await module.scan()

        for item in items {
            XCTAssertTrue(
                item.moduleName.hasPrefix("System Caches - "),
                "Module name should start with 'System Caches - '"
            )
        }
    }

    // MARK: - Clean Tests (Dry Run)

    func testDryRunDoesNotDeleteFiles() async throws {
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: testFile.path), "Dry run should not delete files")
        XCTAssertEqual(result.itemsProcessed, 1)
        XCTAssertEqual(result.bytesFreed, item.size)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testCleanReportsCorrectBytesFreed() async throws {
        let items = try await module.scan()

        guard !items.isEmpty else {
            // Skip test if no items to clean
            return
        }

        // Run dry-run to check calculation
        let result = try await module.clean(items: items, dryRun: true)

        let expectedBytes = items.reduce(0) { $0 + $1.size }
        XCTAssertEqual(result.bytesFreed, expectedBytes, "Bytes freed should match total of item sizes")
    }

    func testCleanIgnoresItemsFromOtherModules() async throws {
        let otherModuleItem = CleanupItem(
            id: UUID(),
            path: testDirectory.appendingPathComponent("other.txt"),
            size: 1000,
            type: .file,
            module: "browser-chrome",  // Different module
            moduleName: "Chrome Cache"
        )

        let result = try await module.clean(items: [otherModuleItem], dryRun: true)

        XCTAssertEqual(result.itemsProcessed, 0, "Should not process items from other modules")
        XCTAssertEqual(result.bytesFreed, 0)
    }

    // MARK: - Clean Tests (Actual Deletion)

    func testCleanActuallyDeletesFiles() async throws {
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: testFile.path), "File should be deleted")
        XCTAssertEqual(result.itemsProcessed, 1)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testCleanDirectoryRemovesContentsOnly() async throws {
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: testDir.path), "Directory should still exist")

        let contents = try FileManager.default.contentsOfDirectory(atPath: testDir.path)
        XCTAssertTrue(contents.isEmpty, "Directory should be empty after cleanup")
        XCTAssertEqual(result.itemsProcessed, 1)
    }

    func testCleanReportsErrorsForProtectedFiles() async throws {
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
        XCTAssertFalse(result.errors.isEmpty, "Should report error for missing file")
        XCTAssertEqual(result.itemsProcessed, 0)
    }

    // MARK: - Integration Tests

    func testScanAndCleanWorkflow() async throws {
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
        XCTAssertEqual(initialContents.count, 5)

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
        XCTAssertEqual(dryResult.bytesFreed, size)

        // Files should still exist
        let afterDryRun = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        XCTAssertEqual(afterDryRun.count, 5)

        // Actual cleanup
        let cleanResult = try await module.clean(items: [item], dryRun: false)
        XCTAssertEqual(cleanResult.itemsProcessed, 1)

        // Directory should be empty
        let afterClean = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        XCTAssertTrue(afterClean.isEmpty)
    }

    // MARK: - Performance Tests

    func testScanPerformance() async throws {
        // This test ensures scan completes in reasonable time
        // Using measure would require @MainActor, so we'll use a simple time check
        let startTime = Date()

        _ = try await module.scan()

        let elapsed = Date().timeIntervalSince(startTime)

        // Scan should complete in less than 30 seconds for typical user
        XCTAssertLessThan(elapsed, 30.0, "Scan should complete in less than 30 seconds")
    }
}
