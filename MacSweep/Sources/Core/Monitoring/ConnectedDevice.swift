import Foundation

// MARK: - Connected Device Model

/// A wireless peripheral (AirPods, Magic Keyboard/Mouse/Trackpad, game controller…)
/// currently paired and connected to this Mac, with whatever battery readings the
/// system exposes for it. Foundation-only so it can live in `MacSweepCore` and be
/// shared by the app UI, the CLI, and tests — the View layer maps it to colors/icons.
public struct ConnectedDevice: Identifiable, Equatable, Sendable {
    /// Stable identity = the normalized Bluetooth address (uppercase, colon-separated).
    public let id: String
    public let name: String
    public let kind: Kind

    /// Single-cell battery (keyboard, mouse, trackpad, headset, controller…).
    public let battery: Int?
    /// Per-bud / case readings for AirPods-style devices.
    public let batteryLeft: Int?
    public let batteryRight: Int?
    public let batteryCase: Int?

    public init(
        id: String,
        name: String,
        kind: Kind,
        battery: Int? = nil,
        batteryLeft: Int? = nil,
        batteryRight: Int? = nil,
        batteryCase: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.battery = battery
        self.batteryLeft = batteryLeft
        self.batteryRight = batteryRight
        self.batteryCase = batteryCase
    }

    public enum Kind: String, Sendable {
        case headphones, keyboard, mouse, trackpad, gamepad, speaker, other
    }

    /// True when at least one battery reading is available.
    public var hasBattery: Bool {
        battery != nil || batteryLeft != nil || batteryRight != nil || batteryCase != nil
    }

    /// The most-drained reading across all cells — drives the "low battery" warning.
    public var lowestBattery: Int? {
        [battery, batteryLeft, batteryRight, batteryCase].compactMap { $0 }.min()
    }

    /// Human label for the device category, e.g. "Keyboard".
    public var typeLabel: String {
        switch kind {
        case .headphones: return "Headphones"
        case .keyboard: return "Keyboard"
        case .mouse: return "Mouse"
        case .trackpad: return "Trackpad"
        case .gamepad: return "Game Controller"
        case .speaker: return "Speaker"
        case .other: return "Bluetooth Device"
        }
    }

    /// SF Symbol name for the device (strings only — no SwiftUI dependency in Core).
    public var iconName: String {
        switch kind {
        case .keyboard: return "keyboard"
        case .mouse: return "magicmouse"
        case .trackpad: return "trackpad"
        case .gamepad: return "gamecontroller"
        case .speaker: return "hifispeaker"
        case .headphones:
            let lower = name.lowercased()
            if lower.contains("airpods max") { return "airpods.max" }
            if lower.contains("airpods pro") { return "airpodspro" }
            if lower.contains("airpods") { return "airpods" }
            return "headphones"
        case .other:
            return "antenna.radiowaves.left.and.right"
        }
    }

    /// One-line battery readout, e.g. "L 98% · R 98% · Case 100%" or "84%".
    public var batterySummary: String {
        var parts: [String] = []
        if let left = batteryLeft { parts.append("L \(left)%") }
        if let right = batteryRight { parts.append("R \(right)%") }
        if let caseLevel = batteryCase { parts.append("Case \(caseLevel)%") }
        if parts.isEmpty, let single = battery { parts.append("\(single)%") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

// MARK: - Scanner

/// Discovers connected Bluetooth peripherals and their battery levels.
///
/// macOS exposes peripheral battery through two complementary sources, and neither
/// alone is complete:
///   * `system_profiler SPBluetoothDataType -json` reports the connected device
///     list plus AirPods-style left/right/case levels — but omits battery for many
///     HID peripherals (e.g. Magic Keyboard reports no `device_batteryLevel*`).
///   * `ioreg -r -l -k BatteryPercent` exposes a single `BatteryPercent` for those
///     HID devices, keyed by Bluetooth address.
///
/// We merge both, keyed by normalized address, so a keyboard's 84% (ioreg) and a
/// pair of AirPods' L/R (system_profiler) both surface. The app is not sandboxed,
/// so neither command needs a Bluetooth entitlement or triggers a TCC prompt.
public enum ConnectedDeviceScanner {
    private static let systemProfilerPath = "/usr/sbin/system_profiler"
    private static let ioregPath = "/usr/sbin/ioreg"

    /// Run both probes and return connected devices that report a battery level.
    public static func scan() async -> [ConnectedDevice] {
        async let profilerOut = runProcess(systemProfilerPath, ["SPBluetoothDataType", "-json"])
        async let ioregOut = runProcess(ioregPath, ["-r", "-l", "-k", "BatteryPercent"])
        let (profiler, ioreg) = await (profilerOut, ioregOut)
        return parse(systemProfilerJSON: Data(profiler.utf8), ioreg: ioreg)
    }

    /// Pure merge of the two probe outputs — no I/O, so it is unit-testable against
    /// captured fixtures.
    public static func parse(systemProfilerJSON: Data, ioreg: String) -> [ConnectedDevice] {
        var devices = parseSystemProfiler(systemProfilerJSON)
        let ioregBattery = parseIORegBattery(ioreg)

        // Index of devices we already have, by normalized address.
        var byAddress: [String: Int] = [:]  // address -> index in `devices`
        for (index, device) in devices.enumerated() {
            byAddress[device.id] = index
        }

        // 1) Fill in single-cell battery for known devices that lacked any reading.
        for (index, device) in devices.enumerated() where !device.hasBattery {
            if let percent = ioregBattery[device.id]?.percent {
                devices[index] = ConnectedDevice(
                    id: device.id,
                    name: device.name,
                    kind: device.kind,
                    battery: percent
                )
            }
        }

        // 2) Add ioreg-only devices (connected HID peripheral not in the profiler
        //    connected list) so nothing with a battery is dropped.
        for (address, entry) in ioregBattery where byAddress[address] == nil {
            devices.append(ConnectedDevice(
                id: address,
                name: entry.product ?? "Bluetooth Device",
                kind: kind(forProductName: entry.product ?? ""),
                battery: entry.percent
            ))
        }

        // Battery is the whole point of this feature: only surface devices that have one.
        return devices
            .filter(\.hasBattery)
            .sorted { lhs, rhs in
                // Most-drained first, then alphabetical for a stable order.
                let l = lhs.lowestBattery ?? Int.max
                let r = rhs.lowestBattery ?? Int.max
                if l != r { return l < r }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    // MARK: - system_profiler

    private static func parseSystemProfiler(_ data: Data) -> [ConnectedDevice] {
        guard
            !data.isEmpty,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let controllers = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }

        var result: [ConnectedDevice] = []
        for controller in controllers {
            guard let connected = controller["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                // Each entry is a single-key dict: { "<device name>": { ...info } }.
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    guard let rawAddress = info["device_address"] as? String else { continue }
                    let address = normalize(address: rawAddress)
                    let minor = info["device_minorType"] as? String
                    result.append(ConnectedDevice(
                        id: address,
                        name: name,
                        kind: kind(forMinorType: minor),
                        battery: percent(from: info["device_batteryLevelMain"]),
                        batteryLeft: percent(from: info["device_batteryLevelLeft"]),
                        batteryRight: percent(from: info["device_batteryLevelRight"]),
                        batteryCase: percent(from: info["device_batteryLevelCase"])
                    ))
                }
            }
        }
        return result
    }

    // MARK: - ioreg

    struct IORegBatteryEntry {
        let percent: Int
        let product: String?
    }

    /// Map of normalized address -> battery entry, parsed from `ioreg -r -l -k BatteryPercent`.
    static func parseIORegBattery(_ text: String) -> [String: IORegBatteryEntry] {
        guard !text.isEmpty else { return [:] }
        var map: [String: IORegBatteryEntry] = [:]

        // `ioreg -r` prints one subtree node per match; nodes begin with "+-o".
        let nodes = text.components(separatedBy: "+-o").dropFirst()
        for node in nodes {
            guard
                let percent = intValue(forKey: "BatteryPercent", in: node),
                percent > 0,
                let rawAddress = stringValue(forKey: "DeviceAddress", in: node)
            else { continue }
            let address = normalize(address: rawAddress)
            let product = stringValue(forKey: "Product", in: node)
            // First reading for an address wins; ioreg can list the same device twice.
            if map[address] == nil {
                map[address] = IORegBatteryEntry(percent: percent, product: product)
            }
        }
        return map
    }

    private static func stringValue(forKey key: String, in node: String) -> String? {
        // Matches:  "Key" = "value"
        guard let range = node.range(of: "\"\(key)\" = \"") else { return nil }
        let rest = node[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func intValue(forKey key: String, in node: String) -> Int? {
        // Matches:  "Key" = 84
        guard let range = node.range(of: "\"\(key)\" = ") else { return nil }
        let rest = node[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        return Int(digits)
    }

    // MARK: - Helpers

    /// Both probes report addresses, but with different casing/separators
    /// ("C4:35:D9:…" vs "10-94-bb-b9-…"). Normalize so the merge join works.
    static func normalize(address: String) -> String {
        address
            .uppercased()
            .replacingOccurrences(of: "-", with: ":")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Parse a battery value that may arrive as a String ("98%") or a number.
    private static func percent(from value: Any?) -> Int? {
        if let number = value as? Int { return clampPercent(number) }
        if let number = value as? Double { return clampPercent(Int(number)) }
        if let string = value as? String {
            let digits = string.prefix { $0.isNumber }
            if let parsed = Int(digits) { return clampPercent(parsed) }
        }
        return nil
    }

    private static func clampPercent(_ value: Int) -> Int? {
        // Intentionally treat 0 as "no reading": BT peripherals (and ioreg) commonly
        // report 0% when the level is simply unavailable, so excluding it avoids
        // false "0% / dead" entries. Verified by ConnectedDeviceScannerTests.
        guard value > 0 else { return nil }
        return min(value, 100)
    }

    private static func kind(forMinorType minor: String?) -> ConnectedDevice.Kind {
        switch minor?.lowercased() {
        case "headphones", "headset": return .headphones
        case "keyboard": return .keyboard
        case "mouse": return .mouse
        case "trackpad": return .trackpad
        case "gamepad": return .gamepad
        case "speaker": return .speaker
        default: return .other
        }
    }

    private static func kind(forProductName product: String) -> ConnectedDevice.Kind {
        let lower = product.lowercased()
        if lower.contains("keyboard") { return .keyboard }
        if lower.contains("trackpad") { return .trackpad }
        if lower.contains("mouse") { return .mouse }
        if lower.contains("airpods") || lower.contains("headphone") { return .headphones }
        return .other
    }

    private static func runProcess(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                // Watchdog: terminate a stuck system_profiler/ioreg so a hung probe
                // can't block readDataToEndOfFile()/waitUntilExit() indefinitely and
                // pile up tasks. Termination closes the pipe, unblocking the read.
                let watchdog = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    watchdog.cancel()
                    continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch {
                    watchdog.cancel()
                    continuation.resume(returning: "")
                }
            }
        }
    }
}
