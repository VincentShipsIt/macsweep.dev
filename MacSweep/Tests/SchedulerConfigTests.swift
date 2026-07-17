import Testing
import Foundation
@testable import MacSweepCore

/// Coverage for `SchedulerConfig`, the shared interval/next-scan store that bridges
/// the GUI scheduler and the `macsweep schedule` CLI. Each test runs against an
/// isolated `UserDefaults` suite (unique name per test) so it never touches the real
/// `dev.macsweep` domain, and tears the suite down in `deinit`.
final class SchedulerConfigTests {
    private let suiteName: String
    private let defaults: UserDefaults

    init() throws {
        suiteName = "MacSweepSchedulerTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func config() -> SchedulerConfig { SchedulerConfig(defaults: defaults) }

    @Test func defaultsToSevenDaysWhenUnset() {
        #expect(config().intervalDays == SchedulerConfig.defaultIntervalDays)
        #expect(config().intervalDays == 7)
        #expect(config().intervalSeconds == 7 * 24 * 60 * 60)
    }

    @Test func roundTripsValidInterval() {
        let stored = config().setIntervalDays(14)
        #expect(stored == 14)
        #expect(config().intervalDays == 14)
        #expect(config().intervalSeconds == 14 * 24 * 60 * 60)
    }

    @Test func clampsBelowMinimumToOne() {
        #expect(config().setIntervalDays(0) == SchedulerConfig.minIntervalDays)
        #expect(config().intervalDays == 1)
        #expect(config().setIntervalDays(-5) == 1)
        #expect(config().intervalDays == 1)
    }

    @Test func clampsAboveMaximum() {
        #expect(config().setIntervalDays(999) == SchedulerConfig.maxIntervalDays)
        #expect(config().intervalDays == 365)
    }

    @Test func enabledIntervalUpdatePersistsAndReanchorsNextScan() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let nextScan = try #require(
            config().updateIntervalDays(14, scheduleEnabled: true, now: now)
        )

        #expect(config().intervalDays == 14)
        #expect(nextScan == now.addingTimeInterval(14 * 24 * 60 * 60))
        #expect(config().nextScheduledScan == nextScan)
    }

    @Test func disabledIntervalUpdatePersistsAndClearsNextScan() {
        config().setNextScheduledScan(Date(timeIntervalSince1970: 1_900_000_000))

        let nextScan = config().updateIntervalDays(30, scheduleEnabled: false)

        #expect(config().intervalDays == 30)
        #expect(nextScan == nil)
        #expect(config().nextScheduledScan == nil)
    }

    @Test func intervalUpdateAnchorsUsingClampedValue() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let nextScan = try #require(
            config().updateIntervalDays(999, scheduleEnabled: true, now: now)
        )

        #expect(config().intervalDays == SchedulerConfig.maxIntervalDays)
        #expect(
            nextScan
                == now.addingTimeInterval(
                    TimeInterval(SchedulerConfig.maxIntervalDays) * 24 * 60 * 60
                )
        )
    }

    @Test func persistsAndClearsNextScheduledScan() {
        #expect(config().nextScheduledScan == nil)

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        config().setNextScheduledScan(date)
        let stored = config().nextScheduledScan
        #expect(stored != nil)
        // UserDefaults stores Date at full precision; compare to the second to avoid
        // any serialization rounding surprises.
        #expect(abs((stored ?? .distantPast).timeIntervalSince(date)) < 1)

        config().setNextScheduledScan(nil)
        #expect(config().nextScheduledScan == nil)
    }
}
