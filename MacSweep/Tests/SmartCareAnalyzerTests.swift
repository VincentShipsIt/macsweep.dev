import XCTest
@testable import MacSweepCore

final class SmartCareAnalyzerTests: XCTestCase {
    func testSummarizeGroupsByModuleAndPreselectsRecommendedItems() {
        let tmp = FileManager.default.temporaryDirectory
        let cacheItem = CleanupItem(
            id: UUID(),
            path: tmp.appendingPathComponent("cache.dat"),
            size: 1_024,
            type: .file,
            module: "system-cache",
            moduleName: "System Cache"
        )
        let duplicateItem = CleanupItem(
            id: UUID(),
            path: tmp.appendingPathComponent("duplicate.jpg"),
            size: 4_096,
            type: .file,
            module: "duplicates",
            moduleName: "Duplicate"
        )
        let similarPhoto = CleanupItem(
            id: UUID(),
            path: tmp.appendingPathComponent("similar.jpg"),
            size: 8_192,
            type: .file,
            module: "similar-photos",
            moduleName: "Similar"
        )

        let summary = SmartCareAnalyzer().summarize(
            items: [cacheItem, duplicateItem, similarPhoto],
            diskUsage: DiskUsage(total: 100, used: 92, free: 8)
        )

        XCTAssertEqual(summary.findings.count, 3)
        XCTAssertEqual(summary.findings.first?.moduleID, "similar-photos")
        XCTAssertTrue(summary.recommendedCleanupItemIDs.contains(cacheItem.id))
        XCTAssertFalse(summary.recommendedCleanupItemIDs.contains(duplicateItem.id))
        XCTAssertFalse(summary.recommendedCleanupItemIDs.contains(similarPhoto.id))
        XCTAssertLessThan(summary.score, 100)
    }
}
