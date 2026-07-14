import Testing
import Foundation
@testable import MacSweepCore

// Coverage for the shared size-summary helpers: the Sequence<CleanupItem>
// total-size extension that replaced the per-view filter+reduce+formatter
// boilerplate, and the scan-notification body builder.

struct SizeFormattingTests {

    private func item(size: Int64, id: UUID = UUID()) -> CleanupItem {
        CleanupItem(
            id: id,
            path: URL(fileURLWithPath: "/tmp/\(id.uuidString)"),
            size: size,
            type: .file,
            module: "test",
            moduleName: "Test"
        )
    }

    private func fileStyle(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - totalSize / formattedTotalSize

    @Test func emptySequenceFormatsAsZero() {
        let items: [CleanupItem] = []

        #expect(items.totalSize() == 0)
        #expect(items.formattedTotalSize() == fileStyle(0))
    }

    @Test func singleItemUsesItsOwnSize() {
        let items = [item(size: 1_500_000)]

        #expect(items.totalSize() == 1_500_000)
        #expect(items.formattedTotalSize() == fileStyle(1_500_000))
    }

    @Test func sizesAreSummedAcrossItems() {
        let items = [item(size: 1_000), item(size: 2_000), item(size: 3_000)]

        #expect(items.totalSize() == 6_000)
        #expect(items.formattedTotalSize() == fileStyle(6_000))
    }

    @Test func selectedFilterCountsOnlySelectedIDs() {
        let a = UUID()
        let b = UUID()
        let items = [item(size: 1_000, id: a), item(size: 2_000, id: b), item(size: 4_000)]

        #expect(items.totalSize(selected: [a, b]) == 3_000)
        #expect(items.formattedTotalSize(selected: [a, b]) == fileStyle(3_000))
    }

    @Test func emptySelectionFormatsAsZero() {
        let items = [item(size: 1_000), item(size: 2_000)]

        #expect(items.totalSize(selected: []) == 0)
        #expect(items.formattedTotalSize(selected: []) == fileStyle(0))
    }

    @Test func zeroByteItemsContributeNothing() {
        let items = [item(size: 0), item(size: 0)]

        #expect(items.totalSize() == 0)
        #expect(items.formattedTotalSize() == fileStyle(0))
    }

    @Test func nilSelectionMeansEverything() {
        let items = [item(size: 1_000), item(size: 2_000)]

        #expect(items.totalSize(selected: nil) == items.totalSize())
    }

    // MARK: - ScanNotificationContent.formattedBody(for:)

    @Test(arguments: [
        Int64(0),                 // nothing found
        Int64(500_000),           // < 1 MB
        Int64(999_999_999),       // just under 1 GB
        Int64(1_000_000_000),     // exactly 1 GB
        Int64(42_500_000_000),    // large
    ])
    func notificationBodyMatchesInAppFileStyleFormatting(bytes: Int64) {
        let body = ScanNotificationContent.formattedBody(for: bytes)

        // The notification must show the exact same size text as every in-app
        // surface (all use ByteCountFormatter with .file), wrapped in the copy.
        #expect(body == "Found \(fileStyle(bytes)) of dev junk ready to clean. Tap to review.")
    }

    @Test func notificationBodyNoLongerHandRollsUnits() {
        // 1_500_000_000 bytes: the old String(format:) path printed "1.5 GB";
        // ByteCountFormatter agrees here, but the value must come from the
        // formatter (locale-aware), not manual division.
        let body = ScanNotificationContent.formattedBody(for: 1_500_000_000)

        #expect(body.contains(fileStyle(1_500_000_000)))
    }

    @Test func notificationTitleAndCategoryAreStable() {
        // The category id is registered with UNUserNotificationCenter; changing
        // it silently orphans the tap-handling registration.
        #expect(ScanNotificationContent.title == "MacSweep Weekly Scan")
        #expect(ScanNotificationContent.categoryIdentifier == "SCAN_COMPLETE")
    }

    // MARK: - Int64.formattedFileSize

    // The migration replaced ~29 inline `ByteCountFormatter.string(fromByteCount:
    // countStyle: .file)` call sites with this single extension. It is now the
    // one source of truth every model property and view label routes through, so
    // pin its output to the `.file` count style across the byte-magnitude range.
    @Test(arguments: [
        Int64(0),                 // zero
        Int64(1),                 // 1 byte
        Int64(999),               // < 1 KB
        Int64(1_024),             // KB boundary
        Int64(500_000),           // < 1 MB
        Int64(1_500_000),         // MB
        Int64(999_999_999),       // just under 1 GB
        Int64(1_000_000_000),     // exactly 1 GB
        Int64(42_500_000_000),    // large GB
        Int64.max,                // overflow-guard ceiling
    ])
    func formattedFileSizeMatchesFileCountStyle(bytes: Int64) {
        #expect(bytes.formattedFileSize == fileStyle(bytes))
    }

    // MARK: - Model properties route through the extension

    // Representative migrated sites (models highlighted in the migration scope):
    // each formatted property must produce the exact `.file` text the extension
    // does, proving the swap preserved output.

    @Test func cleanupResultFormatsBytesFreedAsFileStyle() {
        let result = CleanupResult(itemsProcessed: 3, bytesFreed: 1_500_000)

        #expect(result.formattedBytesFreed == fileStyle(1_500_000))
    }

    @Test func diskUsageFormatsEachComponentAsFileStyle() {
        let usage = DiskUsage(total: 500_000_000_000, used: 300_000_000_000, free: 200_000_000_000)

        #expect(usage.formattedTotal == fileStyle(500_000_000_000))
        #expect(usage.formattedUsed == fileStyle(300_000_000_000))
        #expect(usage.formattedFree == fileStyle(200_000_000_000))
    }

    @Test func networkCleanupSummaryFormatsCacheSizeAsFileStyle() {
        var summary = NetworkCleanupSummary()
        summary.cacheSize = 12_345_678

        #expect(summary.formattedCacheSize == fileStyle(12_345_678))
    }
}
