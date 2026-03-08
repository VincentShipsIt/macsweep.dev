import Foundation

// Note: BackgroundTasks framework is iOS/iPadOS. On macOS, we use a timer-based approach
// with UserDefaults to track last scan date and schedule via app lifecycle.

class ScanScheduler {
    static let shared = ScanScheduler()
    static let taskIdentifier = "dev.shipshit.macsweep.weeklyscan"

    private let scanIntervalSeconds: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    private var timer: Timer?

    func register() {
        scheduleIfNeeded()
    }

    func scheduleWeeklyScan() {
        // Store next scan date
        let nextScanDate = Date(timeIntervalSinceNow: scanIntervalSeconds)
        UserDefaults.standard.set(nextScanDate, forKey: "nextScheduledScan")
        scheduleTimer(for: nextScanDate)
    }

    func cancelScheduledScan() {
        timer?.invalidate()
        timer = nil
        UserDefaults.standard.removeObject(forKey: "nextScheduledScan")
    }

    private func scheduleIfNeeded() {
        if let nextDate = UserDefaults.standard.object(forKey: "nextScheduledScan") as? Date {
            if nextDate > Date() {
                scheduleTimer(for: nextDate)
            } else {
                // Overdue — run now
                Task { await runBackgroundScan() }
            }
        } else {
            // First launch — schedule for 7 days out
            scheduleWeeklyScan()
        }
    }

    private func scheduleTimer(for date: Date) {
        timer?.invalidate()
        let interval = max(date.timeIntervalSinceNow, 1)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { await self?.runBackgroundScan() }
        }
    }

    private func runBackgroundScan() async {
        let engine = ScanEngine()
        guard let items = try? await engine.scan() else {
            scheduleWeeklyScan()
            return
        }

        let totalSize = items.reduce(0) { $0 + $1.size }
        let itemCount = items.count

        // Save results
        LastScanStore.shared.lastScan = ScanSummary(
            date: Date(),
            bytesFound: totalSize,
            itemCount: itemCount
        )

        // Notify if > 100MB found
        if totalSize > 100_000_000 {
            await MainActor.run {
                NotificationManager.shared.sendScanComplete(bytesFound: totalSize)
            }
        }

        // Schedule next scan
        scheduleWeeklyScan()
    }
}
