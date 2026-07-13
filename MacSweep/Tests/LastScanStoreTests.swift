import Foundation
import Testing
@testable import MacSweepCore

final class LastScanStoreTests {
    private let currentSuiteName: String
    private let legacySuiteName: String
    private let currentDefaults: UserDefaults
    private let legacyDefaults: UserDefaults

    init() throws {
        currentSuiteName = "MacSweepLastScanTests-Current-\(UUID().uuidString)"
        legacySuiteName = "MacSweepLastScanTests-Legacy-\(UUID().uuidString)"
        currentDefaults = try #require(UserDefaults(suiteName: currentSuiteName))
        legacyDefaults = try #require(UserDefaults(suiteName: legacySuiteName))
    }

    deinit {
        currentDefaults.removePersistentDomain(forName: currentSuiteName)
        legacyDefaults.removePersistentDomain(forName: legacySuiteName)
    }

    @Test func migratesLegacySummaryDuringInitialization() throws {
        let summary = ScanSummary(
            date: Date(timeIntervalSince1970: 1_800_000_000),
            bytesFound: 4096,
            itemCount: 3
        )
        let data = try JSONEncoder().encode(summary)
        legacyDefaults.set(data, forKey: SchedulerConfig.lastScanKey)

        let store = LastScanStore(defaults: currentDefaults, legacyDefaults: legacyDefaults)
        let migrated = try #require(store.lastScan)

        #expect(migrated.date == summary.date)
        #expect(migrated.bytesFound == summary.bytesFound)
        #expect(migrated.itemCount == summary.itemCount)
        #expect(currentDefaults.data(forKey: SchedulerConfig.lastScanKey) == data)
        #expect(legacyDefaults.data(forKey: SchedulerConfig.lastScanKey) == nil)
    }

    @Test func readingDoesNotMigrateLegacyData() throws {
        let store = LastScanStore(defaults: currentDefaults, legacyDefaults: legacyDefaults)
        let data = try JSONEncoder().encode(
            ScanSummary(date: .now, bytesFound: 1024, itemCount: 1)
        )
        legacyDefaults.set(data, forKey: SchedulerConfig.lastScanKey)

        #expect(store.lastScan == nil)
        #expect(currentDefaults.data(forKey: SchedulerConfig.lastScanKey) == nil)
        #expect(legacyDefaults.data(forKey: SchedulerConfig.lastScanKey) == data)
    }
}
