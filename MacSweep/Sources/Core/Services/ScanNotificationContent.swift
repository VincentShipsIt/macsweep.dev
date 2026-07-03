import Foundation

/// Builds the user-facing copy for scan-complete notifications.
///
/// Lives in the package (not `Background/`) so it is reachable by `swift test`,
/// and routes the size through `ByteCountFormatter` with the app-wide `.file`
/// style — the hand-rolled GB/MB division it replaces could disagree with every
/// in-app display of the same number.
enum ScanNotificationContent {
    static let title = "MacSweep Weekly Scan"
    static let categoryIdentifier = "SCAN_COMPLETE"

    static func formattedBody(for bytesFound: Int64) -> String {
        let size = ByteCountFormatter.string(fromByteCount: bytesFound, countStyle: .file)
        return "Found \(size) of dev junk ready to clean. Tap to review."
    }
}
