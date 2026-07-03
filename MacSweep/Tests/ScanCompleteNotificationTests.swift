import Testing
import Foundation
@testable import MacSweepCore

/// Coverage for the scheduled-scan notification content extracted from
/// Background/NotificationManager into the package (#120).
struct ScanCompleteNotificationTests {

    @Test func usesGigabytesAtOrAboveOneGB() {
        #expect(ScanCompleteNotification.body(bytesFound: 1_000_000_000)
            == "Found 1.0 GB of dev junk ready to clean. Tap to review.")
        #expect(ScanCompleteNotification.body(bytesFound: 2_500_000_000)
            == "Found 2.5 GB of dev junk ready to clean. Tap to review.")
    }

    @Test func usesMegabytesBelowOneGB() {
        #expect(ScanCompleteNotification.body(bytesFound: 999_999_999)
            == "Found 1000 MB of dev junk ready to clean. Tap to review.")
        #expect(ScanCompleteNotification.body(bytesFound: 500_000_000)
            == "Found 500 MB of dev junk ready to clean. Tap to review.")
        #expect(ScanCompleteNotification.body(bytesFound: 0)
            == "Found 0 MB of dev junk ready to clean. Tap to review.")
    }

    @Test func titleAndCategoryAreStable() {
        // The category id is registered with UNUserNotificationCenter; changing
        // it silently orphans the tap-handling registration.
        #expect(ScanCompleteNotification.title == "MacSweep Weekly Scan")
        #expect(ScanCompleteNotification.categoryIdentifier == "SCAN_COMPLETE")
    }
}
