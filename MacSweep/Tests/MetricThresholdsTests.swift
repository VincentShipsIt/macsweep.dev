import Testing
import Foundation
@testable import MacSweepCore

// Boundary coverage for the unified metric-alert thresholds. These numbers are
// user-visible (they decide when a metric turns orange/red across the menu bar,
// dashboard, and detail popovers), so each boundary is pinned explicitly.

struct MetricThresholdsTests {

    // MARK: - CPU (usage + temperature, whichever is worse)

    @Test func cpuNormalBelowAllBoundaries() {
        #expect(MetricThresholds.cpu(usage: 50, temperature: 40) == .normal)
    }

    @Test func cpuWarningAtUsageBoundary() {
        #expect(MetricThresholds.cpu(usage: 70, temperature: nil) == .warning)
        #expect(MetricThresholds.cpu(usage: 69.9, temperature: nil) == .normal)
    }

    @Test func cpuCriticalAtUsageBoundary() {
        #expect(MetricThresholds.cpu(usage: 90, temperature: nil) == .critical)
        #expect(MetricThresholds.cpu(usage: 89.9, temperature: nil) == .warning)
    }

    @Test func cpuTemperatureCanDriveTheLevelAboveLowUsage() {
        #expect(MetricThresholds.cpu(usage: 5, temperature: 61) == .warning)
        #expect(MetricThresholds.cpu(usage: 5, temperature: 81) == .critical)
    }

    @Test func cpuNilTemperatureIsTreatedAsCool() {
        #expect(MetricThresholds.cpu(usage: 10, temperature: nil) == .normal)
    }

    // MARK: - CPU temperature (alone)

    @Test func cpuTemperatureBoundaries() {
        #expect(MetricThresholds.cpuTemperature(nil) == .normal)
        #expect(MetricThresholds.cpuTemperature(60) == .normal)   // strictly greater-than
        #expect(MetricThresholds.cpuTemperature(61) == .warning)
        #expect(MetricThresholds.cpuTemperature(80) == .warning)
        #expect(MetricThresholds.cpuTemperature(81) == .critical)
    }

    // MARK: - Memory (used fraction; menu bar + dashboard now share this)

    @Test func memoryBoundaries() {
        #expect(MetricThresholds.memory(usagePercent: 0.74) == .normal)
        #expect(MetricThresholds.memory(usagePercent: 0.75) == .warning)
        #expect(MetricThresholds.memory(usagePercent: 0.89) == .warning)
        #expect(MetricThresholds.memory(usagePercent: 0.90) == .critical)
    }

    // MARK: - Storage (free fraction)

    @Test func storageBoundaries() {
        #expect(MetricThresholds.storage(freePercent: 0.25) == .normal)
        #expect(MetricThresholds.storage(freePercent: 0.20) == .normal)   // strictly less-than
        #expect(MetricThresholds.storage(freePercent: 0.19) == .warning)
        #expect(MetricThresholds.storage(freePercent: 0.10) == .warning)
        #expect(MetricThresholds.storage(freePercent: 0.09) == .critical)
    }

    // MARK: - Battery (discharge only)

    @Test func batteryChargingIsAlwaysNormal() {
        #expect(MetricThresholds.battery(percent: 5, isCharging: true) == .normal)
    }

    @Test func batteryWithoutABatteryIsNormal() {
        #expect(MetricThresholds.battery(percent: 5, isCharging: false, hasBattery: false) == .normal)
    }

    @Test func batteryDischargeBoundaries() {
        #expect(MetricThresholds.battery(percent: 50, isCharging: false) == .normal)
        #expect(MetricThresholds.battery(percent: 49, isCharging: false) == .warning)
        #expect(MetricThresholds.battery(percent: 20, isCharging: false) == .warning)
        #expect(MetricThresholds.battery(percent: 19, isCharging: false) == .critical)
    }

    // MARK: - Battery health band

    @Test func batteryHealthBandBoundaries() {
        #expect(BatteryHealthBand(health: 100) == .good)
        #expect(BatteryHealthBand(health: 80) == .good)
        #expect(BatteryHealthBand(health: 79) == .fair)
        #expect(BatteryHealthBand(health: 50) == .fair)
        #expect(BatteryHealthBand(health: 49) == .poor)
        #expect(BatteryHealthBand(health: 0) == .poor)
    }

    @Test func batteryHealthBandCarriesIconAndText() {
        #expect(BatteryHealthBand(health: 90).iconName == "checkmark.circle.fill")
        #expect(BatteryHealthBand(health: 60).conditionText == "Battery may need service soon")
        #expect(BatteryHealthBand(health: 10).iconName == "xmark.circle.fill")
    }

    // MARK: - Connected devices subtitle (menu bar + dashboard share this)

    private func device(_ name: String) -> ConnectedDevice {
        ConnectedDevice(id: name, name: name, kind: .other, battery: 50)
    }

    @Test func connectedDevicesSubtitleWording() {
        #expect(ConnectedDevicesSummary.subtitle(for: []) == "None connected")
        #expect(ConnectedDevicesSummary.subtitle(for: [device("Magic Keyboard")]) == "Magic Keyboard")
        #expect(ConnectedDevicesSummary.subtitle(for: [device("A"), device("B")]) == "2 connected")
        #expect(ConnectedDevicesSummary.subtitle(for: [device("A"), device("B"), device("C")]) == "3 connected")
    }
}
