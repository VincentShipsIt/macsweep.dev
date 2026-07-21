import Foundation
import Testing
@testable import MacSweepCore

@Suite("Browser scan result")
struct BrowserScanResultTests {
    @Test func preservesBrowserMetadataAndAggregatesItemSizes() {
        let id = UUID()
        let result = BrowserScanResult(
            id: id,
            browserName: "Safari",
            browserIcon: "safari",
            isRunning: true,
            items: [item(size: 1_000), item(size: 2_000)]
        )

        #expect(result.id == id)
        #expect(result.browserName == "Safari")
        #expect(result.browserIcon == "safari")
        #expect(result.isRunning)
        #expect(result.totalSize == 3_000)
        #expect(result.formattedSize == fileStyle(3_000))
    }

    @Test func emptyResultUsesCanonicalZeroSizeFormatting() {
        let result = BrowserScanResult(
            id: UUID(),
            browserName: "Firefox",
            browserIcon: "globe",
            isRunning: false,
            items: []
        )

        #expect(result.totalSize == 0)
        #expect(result.formattedSize == fileStyle(0))
    }

    private func item(size: Int64) -> CleanupItem {
        let id = UUID()
        return CleanupItem(
            id: id,
            path: URL(fileURLWithPath: "/tmp/\(id.uuidString)"),
            size: size,
            type: .directory,
            module: "browser-cache",
            moduleName: "Browser Cache"
        )
    }

    private func fileStyle(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
