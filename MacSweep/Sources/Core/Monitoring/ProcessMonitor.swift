import Foundation
import AppKit

/// Process information for display in lists
struct ProcessInfo: Identifiable {
    var id: pid_t { pid }
    let pid: pid_t
    let name: String
    let bundleID: String?
    let icon: NSImage?
    let memoryMB: Double
    let cpuPercent: Double
    let isActive: Bool

    var formattedMemory: String {
        if memoryMB >= 1024 {
            return String(format: "%.1f GB", memoryMB / 1024)
        }
        return String(format: "%.0f MB", memoryMB)
    }

    var formattedCPU: String {
        String(format: "%.1f%%", cpuPercent)
    }
}

/// Monitors running processes for CPU and memory usage
@MainActor
final class ProcessMonitor: ObservableObject {
    @Published var processes: [ProcessInfo] = []
    @Published var isLoading = false

    private var timer: Timer?

    func startMonitoring() async {
        await refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let runningApps = NSWorkspace.shared.runningApplications

        var newProcesses: [ProcessInfo] = []

        for app in runningApps {
            guard let name = app.localizedName ?? app.bundleIdentifier else { continue }

            let memory = getMemoryUsage(pid: app.processIdentifier)
            let cpu = getCPUUsage(pid: app.processIdentifier)

            newProcesses.append(ProcessInfo(
                pid: app.processIdentifier,
                name: name,
                bundleID: app.bundleIdentifier,
                icon: app.icon,
                memoryMB: memory,
                cpuPercent: cpu,
                isActive: app.isActive
            ))
        }

        processes = newProcesses
    }

    /// Get top processes sorted by CPU usage
    func topByCPU(limit: Int = 5) -> [ProcessInfo] {
        Array(processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit))
    }

    /// Get top processes sorted by memory usage
    func topByMemory(limit: Int = 5) -> [ProcessInfo] {
        Array(processes.sorted { $0.memoryMB > $1.memoryMB }.prefix(limit))
    }

    private func getMemoryUsage(pid: pid_t) -> Double {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "rss="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let kb = Double(output) {
                return kb / 1024
            }
        } catch {
            // Ignore errors
        }

        return 0
    }

    private func getCPUUsage(pid: pid_t) -> Double {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "%cpu="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let cpu = Double(output) {
                return cpu
            }
        } catch {
            // Ignore errors
        }

        return 0
    }
}
