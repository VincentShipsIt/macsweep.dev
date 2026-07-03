import Foundation
import AppKit

/// Process information for display in lists
struct RunningProcess: Identifiable {
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
    @Published var processes: [RunningProcess] = []
    @Published var isLoading = false

    private var timer: Timer?

    func startMonitoring() async {
        // Don't schedule a second timer if one is already running (e.g. `.task`
        // re-fires). The leaked-timer case is handled by the views calling
        // stopMonitoring() in .onDisappear.
        guard timer == nil else { return }
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

        // One `ps` invocation for every process, instead of two spawns per app.
        // The previous code ran `ps` 2× per running app on a 5s timer — dozens of
        // process spawns each tick. Sample once and look pids up in the table.
        let stats = await Self.sampleProcessStats()

        let runningApps = NSWorkspace.shared.runningApplications

        var newProcesses: [RunningProcess] = []

        for app in runningApps {
            guard let name = app.localizedName ?? app.bundleIdentifier else { continue }

            let sample = stats[app.processIdentifier]

            newProcesses.append(RunningProcess(
                pid: app.processIdentifier,
                name: name,
                bundleID: app.bundleIdentifier,
                icon: app.icon,
                memoryMB: sample?.memoryMB ?? 0,
                cpuPercent: sample?.cpuPercent ?? 0,
                isActive: app.isActive
            ))
        }

        processes = newProcesses
    }

    /// Get top processes sorted by CPU usage
    func topByCPU(limit: Int = 5) -> [RunningProcess] {
        Array(processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit))
    }

    /// Get top processes sorted by memory usage
    func topByMemory(limit: Int = 5) -> [RunningProcess] {
        Array(processes.sorted { $0.memoryMB > $1.memoryMB }.prefix(limit))
    }

    /// Sample memory + CPU for every process in one `ps` invocation.
    ///
    /// Runs through the shared `ProcessRunner`, which drains stdout concurrently
    /// and enforces a watchdog timeout — `ps -axo` for hundreds of processes
    /// overflows the 64KB pipe buffer, so a naive drain-after-wait would deadlock.
    /// A failure or timeout yields an empty table (0/0 for every app).
    private static func sampleProcessStats() async -> [pid_t: (memoryMB: Double, cpuPercent: Double)] {
        guard let output = try? await ProcessRunner.run(
            executable: "/bin/ps", arguments: ["-axo", "pid=,rss=,%cpu="]).output
        else { return [:] }

        var result: [pid_t: (memoryMB: Double, cpuPercent: Double)] = [:]
        for line in output.split(separator: "\n") {
            let cols = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .filter { !$0.isEmpty }
            guard cols.count >= 3,
                  let pid = pid_t(cols[0]),
                  let rssKB = Double(cols[1]),
                  let cpu = Double(cols[2]) else { continue }
            result[pid] = (memoryMB: rssKB / 1024, cpuPercent: cpu)
        }
        return result
    }
}
