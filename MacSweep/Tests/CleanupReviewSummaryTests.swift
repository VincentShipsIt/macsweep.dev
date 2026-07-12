import Foundation
import Testing
@testable import MacSweepCore

@Suite("Cleanup review summary")
struct CleanupReviewSummaryTests {
    @Test func aggregatesExactSelectionByModuleAndPath() {
        let first = item(path: "/tmp/cache-a", size: 800, module: "System Junk")
        let second = item(path: "/tmp/cache-b", size: 200, module: "System Junk")
        let third = item(path: "/tmp/mail", size: 500, module: "Mail")

        let summary = CleanupReviewSummary(
            items: [first, second, third],
            confirmationThreshold: 2_000
        )

        #expect(summary.itemCount == 3)
        #expect(summary.totalBytes == 1_500)
        #expect(summary.moduleCounts.map(\.name) == ["System Junk", "Mail"])
        #expect(summary.moduleCounts.map(\.count) == [2, 1])
        #expect(summary.paths == [first.path, second.path, third.path])
        #expect(!summary.exceedsConfirmationThreshold)
    }

    @Test func includesNonFilesystemWorkAndSurfacesLargeSelection() {
        let file = item(path: "/tmp/build", size: 700, module: "Developer Tools")

        let summary = CleanupReviewSummary(
            items: [file],
            additionalCount: 2,
            additionalBytes: 400,
            additionalModules: ["Git", "Git"],
            additionalPaths: [
                URL(fileURLWithPath: "/tmp/worktree"),
                URL(fileURLWithPath: "/tmp/repository")
            ],
            confirmationThreshold: 1_000
        )

        #expect(summary.itemCount == 3)
        #expect(summary.totalBytes == 1_100)
        #expect(summary.moduleCounts.map(\.name) == ["Git", "Developer Tools"])
        #expect(summary.paths.count == 3)
        #expect(summary.exceedsConfirmationThreshold)
    }

    @Test func deduplicatesPathsAndSaturatesOverflowingSizes() {
        let sharedPath = "/tmp/shared"
        let first = item(path: sharedPath, size: Int64.max, module: "System Junk")
        let second = item(path: sharedPath, size: 1, module: "Developer Tools")

        let summary = CleanupReviewSummary(
            items: [first, second],
            additionalBytes: Int64.max
        )

        #expect(summary.totalBytes == Int64.max)
        #expect(summary.paths == [first.path])
        #expect(summary.exceedsConfirmationThreshold)
    }

    private func item(path: String, size: Int64, module: String) -> CleanupItem {
        CleanupItem(
            id: UUID(),
            path: URL(fileURLWithPath: path),
            size: size,
            type: .directory,
            module: module.lowercased(),
            moduleName: module
        )
    }
}
