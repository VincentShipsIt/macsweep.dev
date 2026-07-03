import Foundation

/// Content for the scheduled-scan completion notification.
///
/// Lives in the package (not `Background/`, which sits outside the SwiftPM
/// graph) so the wording and the GB/MB threshold are reachable by `swift test`;
/// `NotificationManager` is reduced to UNUserNotificationCenter plumbing.
enum ScanCompleteNotification {
    static let title = "MacSweep Weekly Scan"
    static let categoryIdentifier = "SCAN_COMPLETE"

    static func body(bytesFound: Int64) -> String {
        let gb = Double(bytesFound) / 1_000_000_000
        let mb = Double(bytesFound) / 1_000_000

        if gb >= 1 {
            return String(format: "Found %.1f GB of dev junk ready to clean. Tap to review.", gb)
        }
        return String(format: "Found %.0f MB of dev junk ready to clean. Tap to review.", mb)
    }
}
