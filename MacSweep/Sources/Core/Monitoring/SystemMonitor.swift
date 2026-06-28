import Foundation
import Combine
import IOKit.ps

/// Real-time system monitoring for CPU, RAM, Battery, and Network
@MainActor
final class SystemMonitor: ObservableObject {
    // MARK: - Published State
    @Published var cpuUsage: CPUUsage = .init()
    @Published var memoryUsage: MemoryUsage = .init()
    @Published var batteryInfo: BatteryInfo = .init()
    @Published var networkUsage: NetworkUsage = .init()
    @Published var diskUsage: DiskUsage?

    /// Connected Bluetooth peripherals (AirPods, Magic Keyboard/Mouse…) and their
    /// battery levels. Refreshed on a slower cadence than the core metrics because
    /// the underlying `system_profiler`/`ioreg` probes are comparatively expensive.
    @Published var connectedDevices: [ConnectedDevice] = []

    // MARK: - History for Graphs (2 minutes at 2s intervals)
    @Published var cpuHistory: [Double] = []
    @Published var memoryHistory: [Double] = []
    @Published var networkDownloadHistory: [UInt64] = []
    @Published var networkUploadHistory: [UInt64] = []
    private let maxHistorySize = 60

    // MARK: - Chip Info
    @Published var chipName: String = "Mac"

    // MARK: - Private
    private var timer: Timer?
    private var deviceTimer: Timer?
    private var previousNetworkStats: (rx: UInt64, tx: UInt64)?
    private var lastNetworkCheck: Date?
    /// Guards against overlapping device scans (the timer can fire again while a
    /// slow `system_profiler`/`ioreg` probe from the previous tick is still running).
    private var isRefreshingDevices = false

    /// How often connected-device battery is re-scanned. Much slower than the 2s
    /// core-metric tick so we don't spawn `system_profiler` every couple of seconds.
    private let deviceRefreshInterval: TimeInterval = 30

    // MARK: - Lifecycle

    init() {
        fetchChipName()
        startMonitoring()
    }

    private func fetchChipName() {
        var size: size_t = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let brandString = String(cString: brand)

        if !brandString.isEmpty {
            // Primary path. On Apple Silicon this is e.g. "Apple M3 Pro".
            chipName = brandString
        } else {
            // Fallback: hw.model (e.g. "Mac15,6"). The previous code read the
            // system_profiler *binary* off disk as a UTF-8 string and threw the
            // result away — a no-op that set chipName to modelString either way.
            // Spawning system_profiler here would block the init; the model
            // identifier is a fine, cheap fallback.
            var modelSize: size_t = 0
            sysctlbyname("hw.model", nil, &modelSize, nil, 0)
            var model = [CChar](repeating: 0, count: modelSize)
            sysctlbyname("hw.model", &model, &modelSize, nil, 0)
            let modelString = String(cString: model)
            if !modelString.isEmpty {
                chipName = modelString
            }
        }
    }

    deinit {
        timer?.invalidate()
        deviceTimer?.invalidate()
    }

    func startMonitoring() {
        // Initial fetch
        Task {
            await refresh()
            await refreshConnectedDevices()
        }

        // Periodic updates every 2 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }

        // Connected-device battery refreshes on its own slower cadence.
        deviceTimer = Timer.scheduledTimer(withTimeInterval: deviceRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshConnectedDevices()
            }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        deviceTimer?.invalidate()
        deviceTimer = nil
    }

    /// Re-scan connected Bluetooth peripherals and their battery levels.
    /// Safe to call manually (e.g. from a Refresh button) in addition to the timer.
    func refreshConnectedDevices() async {
        guard !isRefreshingDevices else { return }
        isRefreshingDevices = true
        defer { isRefreshingDevices = false }
        connectedDevices = await ConnectedDeviceScanner.scan()
    }

    func refresh() async {
        cpuUsage = await fetchCPUUsage()
        memoryUsage = await fetchMemoryUsage()
        batteryInfo = await fetchBatteryInfo()
        networkUsage = await fetchNetworkUsage()
        diskUsage = await DiskUsage.current()

        // Update history arrays
        cpuHistory.append(cpuUsage.total)
        if cpuHistory.count > maxHistorySize {
            cpuHistory.removeFirst()
        }

        memoryHistory.append(memoryUsage.usedPercentage * 100)
        if memoryHistory.count > maxHistorySize {
            memoryHistory.removeFirst()
        }

        networkDownloadHistory.append(networkUsage.downloadSpeed)
        if networkDownloadHistory.count > maxHistorySize {
            networkDownloadHistory.removeFirst()
        }

        networkUploadHistory.append(networkUsage.uploadSpeed)
        if networkUploadHistory.count > maxHistorySize {
            networkUploadHistory.removeFirst()
        }
    }

    // MARK: - Memory Management

    /// Free up memory by purging inactive memory
    func freeUpMemory() async throws {
        let purgePath = "/usr/sbin/purge"
        guard FileManager.default.fileExists(atPath: purgePath) else {
            // purge not available - refresh anyway
            memoryUsage = await fetchMemoryUsage()
            return
        }

        // runCommand hops to a background queue and waits there, so purge (which
        // can take several seconds walking inactive pages) does not block the
        // MainActor and freeze the UI / progress spinner.
        _ = await runCommand(purgePath, arguments: [])

        // Refresh after purge
        memoryUsage = await fetchMemoryUsage()
    }
}

// MARK: - CPU Usage

struct CPUUsage: Sendable {
    var user: Double = 0
    var system: Double = 0
    var idle: Double = 0
    var temperature: Double? = nil

    var total: Double {
        user + system
    }

    var totalPercentage: Int {
        Int(total.rounded())
    }

    var formattedLoad: String {
        "Load: \(totalPercentage)%"
    }

    var formattedTemperature: String? {
        guard let temp = temperature else { return nil }
        return String(format: "%.0f°C", temp)
    }

    var temperatureColor: String {
        guard let temp = temperature else { return "primary" }
        if temp > 80 { return "red" }
        if temp > 60 { return "orange" }
        return "green"
    }
}

extension SystemMonitor {
    func fetchCPUUsage() async -> CPUUsage {
        // Use top command to get CPU usage
        let output = await runCommand("/usr/bin/top", arguments: ["-l", "1", "-n", "0", "-stats", "cpu"])

        var usage = CPUUsage()

        // Parse: CPU usage: X% user, Y% sys, Z% idle
        if let match = output.firstMatch(of: #/CPU usage: ([0-9.]+)% user, ([0-9.]+)% sys, ([0-9.]+)% idle/#) {
            usage.user = Double(match.1) ?? 0
            usage.system = Double(match.2) ?? 0
            usage.idle = Double(match.3) ?? 0
        }

        // Try to get temperature (requires external tool like osx-cpu-temp or SMC access)
        usage.temperature = await fetchCPUTemperature()

        return usage
    }

    private func fetchCPUTemperature() async -> Double? {
        // Try using powermetrics (requires sudo) or third-party tool
        // For now, return nil - temperature requires SMC access
        // Users can install osx-cpu-temp via Homebrew

        // Check if osx-cpu-temp is available
        let tempOutput = await runCommand("/usr/local/bin/osx-cpu-temp", arguments: [])
        if let match = tempOutput.firstMatch(of: #/([0-9.]+)°C/#) {
            return Double(match.1)
        }

        // Try Homebrew ARM path
        let tempOutputARM = await runCommand("/opt/homebrew/bin/osx-cpu-temp", arguments: [])
        if let match = tempOutputARM.firstMatch(of: #/([0-9.]+)°C/#) {
            return Double(match.1)
        }

        return nil
    }
}

// MARK: - Memory Usage

struct MemoryUsage: Sendable {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var free: UInt64 = 0
    var wired: UInt64 = 0
    var active: UInt64 = 0
    var inactive: UInt64 = 0
    var compressed: UInt64 = 0

    var available: UInt64 {
        free + inactive
    }

    var usedPercentage: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total)
    }

    var formattedAvailable: String {
        ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .memory)
    }

    var formattedUsed: String {
        ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .memory)
    }

    var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .memory)
    }

    var formattedWired: String {
        ByteCountFormatter.string(fromByteCount: Int64(wired), countStyle: .memory)
    }

    var formattedCompressed: String {
        ByteCountFormatter.string(fromByteCount: Int64(compressed), countStyle: .memory)
    }

    var formattedFree: String {
        ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .memory)
    }

    var pressureLevel: MemoryPressure {
        let usedPercent = usedPercentage
        if usedPercent > 0.9 { return .critical }
        if usedPercent > 0.75 { return .warning }
        return .normal
    }

    enum MemoryPressure: String {
        case normal, warning, critical

        var color: String {
            switch self {
            case .normal: return "green"
            case .warning: return "orange"
            case .critical: return "red"
            }
        }
    }
}

extension SystemMonitor {
    func fetchMemoryUsage() async -> MemoryUsage {
        var usage = MemoryUsage()

        // Get total physical memory
        var size = MemoryLayout<UInt64>.size
        var physicalMemory: UInt64 = 0
        sysctlbyname("hw.memsize", &physicalMemory, &size, nil, 0)
        usage.total = physicalMemory

        // Parse vm_stat for detailed breakdown
        let vmStatOutput = await runCommand("/usr/bin/vm_stat", arguments: [])

        // Get page size
        let pageSize: UInt64
        let pageSizeOutput = await runCommand("/usr/bin/pagesize", arguments: [])
        pageSize = UInt64(pageSizeOutput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 16384

        // Parse vm_stat output
        let lines = vmStatOutput.components(separatedBy: "\n")
        var stats: [String: UInt64] = [:]

        for line in lines {
            let parts = line.components(separatedBy: ":")
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let valueStr = parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")
                if let value = UInt64(valueStr) {
                    stats[key] = value * pageSize
                }
            }
        }

        usage.free = stats["Pages free"] ?? 0
        usage.active = stats["Pages active"] ?? 0
        usage.inactive = stats["Pages inactive"] ?? 0
        usage.wired = stats["Pages wired down"] ?? 0
        usage.compressed = stats["Pages occupied by compressor"] ?? 0

        usage.used = usage.active + usage.wired + usage.compressed

        return usage
    }
}

// MARK: - Battery Info

struct BatteryInfo: Sendable {
    var hasBattery: Bool = false
    var percentage: Int = 0
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var timeRemaining: Int? = nil  // minutes
    var cycleCount: Int? = nil
    var health: Int? = nil  // percentage
    var temperature: Double? = nil

    var statusText: String {
        if !hasBattery {
            return "No Battery"
        } else if isCharging {
            return "Charging"
        } else if isPluggedIn {
            return "Fully charged"
        } else if let time = timeRemaining {
            let hours = time / 60
            let mins = time % 60
            return "\(hours):\(String(format: "%02d", mins)) remaining"
        } else {
            return "On Battery"
        }
    }

    var icon: String {
        if !hasBattery {
            return "powerplug.fill"
        }
        if isCharging || isPluggedIn {
            return "battery.100.bolt"
        }
        switch percentage {
        case 0..<25: return "battery.25"
        case 25..<50: return "battery.50"
        case 50..<75: return "battery.75"
        default: return "battery.100"
        }
    }
}

extension SystemMonitor {
    func fetchBatteryInfo() async -> BatteryInfo {
        var info = BatteryInfo()

        // Use IOKit for battery info
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array

        for source in sources {
            if let description = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] {
                let sourceType = description[kIOPSTypeKey] as? String
                if let sourceType, sourceType != kIOPSInternalBatteryType {
                    continue
                }

                info.hasBattery = true

                if let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                   let maxCapacity = description[kIOPSMaxCapacityKey] as? Int,
                   maxCapacity > 0 {
                    info.percentage = (capacity * 100) / maxCapacity
                }

                if let isCharging = description[kIOPSIsChargingKey] as? Bool {
                    info.isCharging = isCharging
                }

                if let powerSource = description[kIOPSPowerSourceStateKey] as? String {
                    info.isPluggedIn = (powerSource == kIOPSACPowerValue)
                }

                if let timeToEmpty = description[kIOPSTimeToEmptyKey] as? Int, timeToEmpty > 0 {
                    info.timeRemaining = timeToEmpty
                }
            }
        }

        guard info.hasBattery else {
            info.isPluggedIn = true
            return info
        }

        // Get cycle count from system_profiler
        let profilerOutput = await runCommand("/usr/sbin/system_profiler", arguments: ["SPPowerDataType"])
        if let match = profilerOutput.firstMatch(of: #/Cycle Count: ([0-9]+)/#) {
            info.cycleCount = Int(match.1)
        }
        if let match = profilerOutput.firstMatch(of: #/Condition: ([A-Za-z ]+)/#) {
            let condition = String(match.1)
            info.health = condition == "Normal" ? 100 : (condition == "Replace Soon" ? 50 : 25)
        }

        return info
    }
}

// MARK: - Network Usage

struct NetworkUsage: Sendable {
    var downloadSpeed: UInt64 = 0  // bytes per second
    var uploadSpeed: UInt64 = 0    // bytes per second
    var totalDownloaded: UInt64 = 0
    var totalUploaded: UInt64 = 0
    var isConnected: Bool = false
    var interfaceName: String? = nil
    var ssid: String? = nil

    var formattedDownload: String {
        Self.formatSpeed(downloadSpeed)
    }

    var formattedUpload: String {
        Self.formatSpeed(uploadSpeed)
    }

    /// Canonical bytes/sec → human string. Shared by the dashboard's SpeedMeter so
    /// the model and the view never drift. Sub-1 kbps reads as a flat "0 KB/s"
    /// rather than a jittery "0.x KB/s".
    static func formatSpeed(_ bytesPerSecond: UInt64) -> String {
        let kbps = Double(bytesPerSecond) / 1024
        if kbps < 1 {
            return "0 KB/s"
        } else if kbps < 1024 {
            return String(format: "%.1f KB/s", kbps)
        } else {
            return String(format: "%.1f MB/s", kbps / 1024)
        }
    }
}

extension SystemMonitor {
    func fetchNetworkUsage() async -> NetworkUsage {
        var usage = NetworkUsage()

        // Get network interface stats using netstat
        let netstatOutput = await runCommand("/usr/sbin/netstat", arguments: ["-ib"])

        var totalRx: UInt64 = 0
        var totalTx: UInt64 = 0

        let lines = netstatOutput.components(separatedBy: "\n")
        for line in lines {
            // Look for en0 (Wi-Fi) or en1 (Ethernet)
            if line.hasPrefix("en0") || line.hasPrefix("en1") {
                let columns = line.split(separator: " ").map(String.init)
                // netstat -ib prints one row per (interface, protocol-family):
                // a <Link#N> row with the real hardware counters plus IPv4/IPv6
                // rows that duplicate those same counts. Summing them all would
                // inflate totals 2-3x, so only count the Link-layer row.
                guard columns.count >= 10, columns[2].hasPrefix("<Link#") else { continue }
                // Column 6 is Ibytes (received), Column 9 is Obytes (sent)
                if let rx = UInt64(columns[6]), let tx = UInt64(columns[9]) {
                    totalRx += rx
                    totalTx += tx
                    usage.isConnected = true
                    usage.interfaceName = columns[0]
                }
            }
        }

        usage.totalDownloaded = totalRx
        usage.totalUploaded = totalTx

        // Calculate speed (delta since last check)
        let now = Date()
        if let previous = previousNetworkStats, let lastCheck = lastNetworkCheck {
            let timeDelta = now.timeIntervalSince(lastCheck)
            if timeDelta > 0 {
                // Guard UInt64 subtraction: interface counters reset on link
                // change / sleep and the set of interfaces summed can shrink, so
                // totalRx < previous.rx is possible and would trap. Treat a
                // backwards delta as zero for that tick.
                let rxDelta = totalRx >= previous.rx ? totalRx - previous.rx : 0
                let txDelta = totalTx >= previous.tx ? totalTx - previous.tx : 0
                usage.downloadSpeed = UInt64(Double(rxDelta) / timeDelta)
                usage.uploadSpeed = UInt64(Double(txDelta) / timeDelta)
            }
        }

        previousNetworkStats = (totalRx, totalTx)
        lastNetworkCheck = now

        // Get Wi-Fi SSID
        let airportOutput = await runCommand("/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport", arguments: ["-I"])
        if let match = airportOutput.firstMatch(of: #/\s+SSID: (.+)/#) {
            usage.ssid = String(match.1).trimmingCharacters(in: .whitespaces)
        }

        return usage
    }
}

// MARK: - Command Runner

extension SystemMonitor {
    private func runCommand(_ path: String, arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    // Drain before reaping so verbose commands (e.g.
                    // system_profiler) can't fill the 64 KB pipe buffer and
                    // deadlock against waitUntilExit.
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}
