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
}
