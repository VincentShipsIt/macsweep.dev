import Testing
import Foundation
@testable import MacSweepCore

struct SmartCareAnalyzerTests {
    @Test func summarizeGroupsByModuleAndPreselectsRecommendedItems() {
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

        #expect(summary.findings.count == 3)
        #expect(summary.findings.first?.moduleID == "similar-photos")
        #expect(summary.recommendedFindings.map(\.moduleID) == ["system-cache"])
        #expect(Set(summary.reviewRequiredFindings.map(\.moduleID)) == ["duplicates", "similar-photos"])
        #expect(summary.recommendedCleanupItemIDs.contains(cacheItem.id))
        #expect(!summary.recommendedCleanupItemIDs.contains(duplicateItem.id))
        #expect(!summary.recommendedCleanupItemIDs.contains(similarPhoto.id))
        #expect(summary.score < 100)
    }

    @Test func personalFileModulesAlwaysRequireReview() {
        let tmp = FileManager.default.temporaryDirectory
        let modules = ["large-files", "duplicates", "similar-photos"]
        let items = modules.enumerated().map { index, module in
            CleanupItem(
                id: UUID(),
                path: tmp.appendingPathComponent("review-\(index)"),
                size: Int64(index + 1) * 1_024,
                type: .file,
                module: module,
                moduleName: module
            )
        }

        let summary = SmartCareAnalyzer().summarize(items: items, diskUsage: nil)

        #expect(summary.recommendedFindings.isEmpty)
        #expect(Set(summary.reviewRequiredFindings.map(\.moduleID)) == Set(modules))
        #expect(summary.recommendedCleanupItemIDs.isEmpty)
    }
}
