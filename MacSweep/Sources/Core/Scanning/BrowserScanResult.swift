import Foundation

/// UI-independent result data for one installed browser scan.
///
/// Keeping the result in Core makes its metadata and size derivations reachable
/// from SwiftPM tests while Browser Cleanup remains responsible for scan,
/// selection, cleanup, and presentation state.
struct BrowserScanResult: Identifiable {
    let id: UUID
    let browserName: String
    let browserIcon: String
    let isRunning: Bool
    let items: [CleanupItem]

    var totalSize: Int64 {
        items.totalSize()
    }

    var formattedSize: String {
        items.formattedTotalSize()
    }
}
