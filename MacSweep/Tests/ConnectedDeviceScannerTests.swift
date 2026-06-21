import Testing
import Foundation
@testable import MacSweepCore

struct ConnectedDeviceScannerTests {
    // system_profiler reports AirPods L/R, a keyboard with NO battery keys, and a
    // beacon with no battery at all. Addresses use uppercase colon form.
    private let systemProfilerJSON = """
    {
      "SPBluetoothDataType": [
        {
          "controller_properties": { "controller_address": "9C:76:0E:4C:68:9E" },
          "device_connected": [
            {
              "Vincent\\u2019s AirPods Pro": {
                "device_address": "C4:35:D9:18:54:D1",
                "device_minorType": "Headphones",
                "device_batteryLevelLeft": "98%",
                "device_batteryLevelRight": "97%",
                "device_batteryLevelCase": "100%"
              }
            },
            {
              "Magic Keyboard": {
                "device_address": "10:94:BB:B9:50:6A",
                "device_minorType": "Keyboard"
              }
            },
            {
              "Spare Beacon": {
                "device_address": "AA:BB:CC:DD:EE:FF",
                "device_minorType": "Other"
              }
            }
          ],
          "device_not_connected": [
            { "Apple TV": { "device_address": "90:DD:5D:CE:93:14" } }
          ]
        }
      ]
    }
    """

    // ioreg exposes the keyboard's battery (lowercase, hyphen-separated address — must
    // still join to the profiler entry), an ioreg-only mouse, and a 0% node to ignore.
    private let ioreg = """
    +-o AppleDeviceManagementHIDEventService  <class ...>
        {
          "DeviceAddress" = "10-94-bb-b9-50-6a"
          "Product" = "Magic Keyboard"
          "BatteryPercent" = 84
        }
    +-o AppleDeviceManagementHIDEventService  <class ...>
        {
          "DeviceAddress" = "20-30-40-50-60-70"
          "Product" = "Magic Mouse"
          "BatteryPercent" = 60
        }
    +-o SomethingDrained  <class ...>
        {
          "DeviceAddress" = "DE-AD-BE-EF-00-00"
          "Product" = "Dead Thing"
          "BatteryPercent" = 0
        }
    """

    @Test func mergesBothSourcesByAddress() {
        let devices = ConnectedDeviceScanner.parse(
            systemProfilerJSON: Data(systemProfilerJSON.utf8),
            ioreg: ioreg
        )

        // AirPods + keyboard (merged) + ioreg-only mouse. Beacon (no battery) and the
        // 0% node are excluded.
        #expect(devices.count == 3)
        #expect(!devices.contains { $0.name == "Spare Beacon" })
        #expect(!devices.contains { $0.name == "Dead Thing" })
    }

    @Test func airPodsKeepPerCellLevels() throws {
        let devices = ConnectedDeviceScanner.parse(
            systemProfilerJSON: Data(systemProfilerJSON.utf8),
            ioreg: ioreg
        )
        let airpods = try #require(devices.first { $0.kind == .headphones })
        #expect(airpods.batteryLeft == 98)
        #expect(airpods.batteryRight == 97)
        #expect(airpods.batteryCase == 100)
        #expect(airpods.battery == nil)
        #expect(airpods.lowestBattery == 97)
        #expect(airpods.iconName == "airpodspro")
        #expect(airpods.batterySummary == "L 98% · R 97% · Case 100%")
    }

    @Test func keyboardBatteryFilledFromIORegAcrossAddressFormats() throws {
        let devices = ConnectedDeviceScanner.parse(
            systemProfilerJSON: Data(systemProfilerJSON.utf8),
            ioreg: ioreg
        )
        // Keyboard had no battery in system_profiler; ioreg's "10-94-bb-…" must
        // normalize to "10:94:BB:…" and merge.
        let keyboard = try #require(devices.first { $0.kind == .keyboard })
        #expect(keyboard.name == "Magic Keyboard")
        #expect(keyboard.battery == 84)
    }

    @Test func ioregOnlyDeviceIsAdded() throws {
        let devices = ConnectedDeviceScanner.parse(
            systemProfilerJSON: Data(systemProfilerJSON.utf8),
            ioreg: ioreg
        )
        let mouse = try #require(devices.first { $0.name == "Magic Mouse" })
        #expect(mouse.kind == .mouse)
        #expect(mouse.battery == 60)
    }

    @Test func sortedByMostDrainedFirst() {
        let devices = ConnectedDeviceScanner.parse(
            systemProfilerJSON: Data(systemProfilerJSON.utf8),
            ioreg: ioreg
        )
        // Mouse (60) < Keyboard (84) < AirPods (97).
        #expect(devices.map(\.lowestBattery) == [60, 84, 97])
    }

    @Test func addressNormalizationIsCaseAndSeparatorInsensitive() {
        #expect(
            ConnectedDeviceScanner.normalize(address: "10-94-bb-b9-50-6a")
                == ConnectedDeviceScanner.normalize(address: "10:94:BB:B9:50:6A")
        )
    }

    @Test func emptyInputsReturnNoDevices() {
        #expect(ConnectedDeviceScanner.parse(systemProfilerJSON: Data(), ioreg: "").isEmpty)
        #expect(ConnectedDeviceScanner.parse(systemProfilerJSON: Data("not json".utf8), ioreg: "").isEmpty)
    }

    @Test func ioregParserExtractsBatteryByAddress() {
        let map = ConnectedDeviceScanner.parseIORegBattery(ioreg)
        #expect(map["10:94:BB:B9:50:6A"]?.percent == 84)
        #expect(map["20:30:40:50:60:70"]?.percent == 60)
        #expect(map["DE:AD:BE:EF:00:00"] == nil)  // 0% is dropped
    }
}
