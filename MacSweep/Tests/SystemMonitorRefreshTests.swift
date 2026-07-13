import Testing
@testable import MacSweepCore

struct SystemMonitorRefreshTests {
    @Test func forcedRefreshRunsSlowMetricsBetweenScheduledIntervals() {
        #expect(SystemMonitor.shouldRefreshSlowMetrics(force: true, tickCount: 1, interval: 15))
        #expect(!SystemMonitor.shouldRefreshSlowMetrics(force: false, tickCount: 1, interval: 15))
        #expect(SystemMonitor.shouldRefreshSlowMetrics(force: false, tickCount: 15, interval: 15))
    }
}
