import Testing
@testable import MacSweepCore

struct WidgetTypeTests {
    @Test func casesPreserveCrossSurfaceOrder() {
        #expect(WidgetType.allCases == [
            .storage,
            .memory,
            .battery,
            .cpu,
            .network,
            .devices,
            .system
        ])
    }

    @Test func rawValuesRemainStable() {
        #expect(WidgetType.allCases.map(\.rawValue) == [
            "storage",
            "memory",
            "battery",
            "cpu",
            "network",
            "devices",
            "system"
        ])
    }
}
