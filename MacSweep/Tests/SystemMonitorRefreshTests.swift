import Testing
@testable import MacSweepCore

struct SystemMonitorRefreshTests {
    @Test func forcedRefreshRunsSlowMetricsBetweenScheduledIntervals() {
        #expect(SystemMonitor.shouldRefreshSlowMetrics(force: true, tickCount: 1, interval: 15))
        #expect(!SystemMonitor.shouldRefreshSlowMetrics(force: false, tickCount: 1, interval: 15))
        #expect(SystemMonitor.shouldRefreshSlowMetrics(force: false, tickCount: 15, interval: 15))
    }

    @Test func desktopMacUsesExplicitNoBatteryState() {
        let info = BatteryInfo()

        #expect(info.hasBattery == false)
        #expect(info.statusText == "No Battery")
        #expect(info.icon == "powerplug.fill")
    }

    @Test func optimizationNeverOffersUnsafeTerminationTargets() {
        #expect(!ProcessMonitor.isSafeTerminationTarget(0, currentPID: 42))
        #expect(!ProcessMonitor.isSafeTerminationTarget(1, currentPID: 42))
        #expect(!ProcessMonitor.isSafeTerminationTarget(42, currentPID: 42))
        #expect(ProcessMonitor.isSafeTerminationTarget(43, currentPID: 42))
    }
}
