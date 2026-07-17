import Foundation
import Testing
@testable import MacSweepCore

@Suite("Trash bins")
struct TrashBinsModuleTests {
    @Test func emptyAllResultCountsOnlyPreviewItemsConfirmedGone() {
        let removed = item(path: "/trash/removed", size: 120)
        let retained = item(path: "/trash/retained", size: 80)
        let addedAfterPreview = item(path: "/trash/new", size: 500)

        let result = TrashBinsModule.verifiedEmptyAllResult(
            previewItems: [removed, retained],
            remainingItems: [retained, addedAfterPreview]
        )

        #expect(result.itemsProcessed == 1)
        #expect(result.bytesFreed == 120)
        #expect(result.errors.map(\.path) == [retained.path])
        #expect(result.historyActions == [removed.id: .deletePermanently])
    }

    @Test func emptyAllResultReportsCompletePreviewRemoval() {
        let first = item(path: "/trash/first", size: 120)
        let second = item(path: "/trash/second", size: 80)

        let result = TrashBinsModule.verifiedEmptyAllResult(
            previewItems: [first, second],
            remainingItems: []
        )

        #expect(result.itemsProcessed == 2)
        #expect(result.bytesFreed == 200)
        #expect(result.errors.isEmpty)
    }

    private func item(path: String, size: Int64) -> CleanupItem {
        CleanupItem(
            id: UUID(),
            path: URL(fileURLWithPath: path),
            size: size,
            type: .file,
            module: "trash-bins",
            moduleName: "User Trash"
        )
    }
}
