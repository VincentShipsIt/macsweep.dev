import Foundation
import Testing

@testable import MacSweepCore

@MainActor
struct ScanSchedulerTests {
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)
    private func config() -> SchedulerConfig {
        SchedulerConfig(defaults: UserDefaults(suiteName: "ScanSchedulerTests.\(UUID())")!)
    }
    private func result(partial: Bool = false, size: Int64 = 200_000_000) -> PartialScanResult {
        PartialScanResult(
            items: [
                CleanupItem(
                    id: UUID(), path: URL(fileURLWithPath: "/tmp/fixture"),
                    size: size, type: .file, module: "fixture", moduleName: "Fixture")
            ],
            failures: partial ? [ModuleScanFailure(moduleID: "broken", moduleName: "Broken", message: "Denied")] : [])
    }

    @Test func disabledRegistrationClearsStaleScheduleWithoutScanning() {
        let config = config()
        config.setNextScheduledScan(anchor.addingTimeInterval(-1))
        var scans = 0
        let scheduler = ScanScheduler(
            config: config, isEnabled: { false },
            scan: {
                scans += 1
                return result()
            }, notify: { _ in Issue.record("Disabled notification") }, now: { anchor })
        scheduler.register()
        #expect(config.nextScheduledScan == nil)
        #expect(scans == 0)
    }

    @Test func registrationAndIntervalChangesPersistOneFutureAnchor() {
        let config = config()
        let scheduler = ScanScheduler(config: config, isEnabled: { true }, notify: { _ in }, now: { anchor })
        scheduler.register()
        #expect(config.nextScheduledScan == anchor.addingTimeInterval(7 * 86_400))
        scheduler.register()
        #expect(config.nextScheduledScan == anchor.addingTimeInterval(7 * 86_400))
        scheduler.updateIntervalDays(2)
        #expect(config.nextScheduledScan == anchor.addingTimeInterval(2 * 86_400))
        scheduler.cancelScheduledScan()
        #expect(config.nextScheduledScan == nil)
    }

    @Test func overdueCompleteScanPersistsAndNotifiesOnceThenSchedulesNext() async {
        let config = config()
        config.setNextScheduledScan(anchor.addingTimeInterval(-1))
        var scans = 0
        var summaries: [ScanSummary] = []
        var notifications: [Int64] = []
        let scheduler = ScanScheduler(
            config: config, isEnabled: { true },
            scan: {
                scans += 1
                return result()
            }, saveSummary: { summaries.append($0) }, notify: { notifications.append($0) }, now: { anchor })
        scheduler.register()
        scheduler.register()
        for _ in 0..<1_000 where summaries.isEmpty { await Task.yield() }
        #expect(scans == 1)
        #expect(summaries.count == 1)
        #expect(summaries.first?.bytesFound == 200_000_000)
        #expect(notifications == [200_000_000])
        #expect(config.nextScheduledScan == anchor.addingTimeInterval(7 * 86_400))
        scheduler.cancelScheduledScan()
    }

    @Test func partialResultCannotOverwriteCompleteSummaryOrNotify() async {
        let config = config()
        config.setNextScheduledScan(anchor.addingTimeInterval(-1))
        var scans = 0
        let scheduler = ScanScheduler(
            config: config, isEnabled: { true },
            scan: {
                scans += 1
                return result(partial: true)
            }, saveSummary: { _ in Issue.record("Partial summary persisted") },
            notify: { _ in Issue.record("Partial notification") }, now: { anchor })
        scheduler.register()
        for _ in 0..<1_000 where config.nextScheduledScan != anchor.addingTimeInterval(7 * 86_400) {
            await Task.yield()
        }
        #expect(scans == 1)
        #expect(config.nextScheduledScan == anchor.addingTimeInterval(7 * 86_400))
        scheduler.cancelScheduledScan()
    }

    @Test func cancellationDuringScanCannotPersistNotifyOrReschedule() async {
        let config = config()
        config.setNextScheduledScan(anchor.addingTimeInterval(-1))
        var enabled = true
        var started = false
        var finish: CheckedContinuation<PartialScanResult, Never>?
        var completed = false
        let scheduler = ScanScheduler(
            config: config, isEnabled: { enabled },
            scan: {
                started = true
                let value = await withCheckedContinuation { finish = $0 }
                completed = true
                return value
            }, saveSummary: { _ in Issue.record("Cancelled summary") },
            notify: { _ in Issue.record("Cancelled notification") }, now: { anchor })
        scheduler.register()
        for _ in 0..<1_000 where !started { await Task.yield() }
        #expect(started)
        enabled = false
        scheduler.cancelScheduledScan()
        finish?.resume(returning: result())
        for _ in 0..<1_000 where !completed { await Task.yield() }
        #expect(completed)
        #expect(config.nextScheduledScan == nil)
    }
}
