import Foundation
import Testing
@testable import MacSweepCore

final class CleanupPerformanceStoreTests {
    private let suiteName: String
    private let defaults: UserDefaults

    init() throws {
        suiteName = "MacSweepCleanupPerformanceTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func store() -> CleanupPerformanceStore {
        CleanupPerformanceStore(defaults: defaults)
    }

    @Test func recordsUsefulCleanupResults() throws {
        let store = store()
        let result = CleanupResult(
            itemsProcessed: 3,
            bytesFreed: 4096,
            errors: [CleanupError(path: URL(fileURLWithPath: "/tmp/a"), message: "File is in use")]
        )

        let entry = try #require(store.record(result))

        #expect(entry.bytesFreed == 4096)
        #expect(entry.itemsProcessed == 3)
        #expect(entry.errorCount == 1)
        #expect(store.history == [entry])
    }

    @Test func ignoresNoOpCleanupResults() {
        let store = store()
        let result = CleanupResult(itemsProcessed: 0, bytesFreed: 0)

        #expect(store.record(result) == nil)
        #expect(store.history.isEmpty)
    }

    @Test func recordsFullyFailedCleanupResults() throws {
        let store = store()
        let result = CleanupResult(
            itemsProcessed: 0,
            bytesFreed: 0,
            errors: [CleanupError(path: URL(fileURLWithPath: "/tmp/a"), message: "Permission denied")]
        )

        let entry = try #require(store.record(result))

        #expect(entry.bytesFreed == 0)
        #expect(entry.itemsProcessed == 0)
        #expect(entry.errorCount == 1)
        #expect(store.history == [entry])
        #expect(store.summary().successRate == 0)
    }

    @Test func summaryUsesRequestedWindowAndSuccessRate() {
        let store = store()
        let now = Date()
        store.history = [
            CleanupPerformanceEntry(
                timestamp: now.addingTimeInterval(-40 * 24 * 60 * 60),
                bytesFreed: 9_000,
                itemsProcessed: 9,
                errorCount: 0
            ),
            CleanupPerformanceEntry(
                timestamp: now.addingTimeInterval(-2 * 24 * 60 * 60),
                bytesFreed: 4_000,
                itemsProcessed: 3,
                errorCount: 1
            ),
            CleanupPerformanceEntry(
                timestamp: now.addingTimeInterval(-1 * 24 * 60 * 60),
                bytesFreed: 6_000,
                itemsProcessed: 5,
                errorCount: 0
            ),
        ]

        let summary = store.summary(generatedAt: now, windowDays: 30)

        #expect(summary.cleanupCount == 2)
        #expect(summary.totalBytesFreed == 10_000)
        #expect(summary.totalItemsProcessed == 8)
        #expect(summary.totalErrors == 1)
        #expect(summary.successRate == 8.0 / 9.0)
        #expect(summary.bestCleanup?.bytesFreed == 6_000)
    }
}
