import Foundation

// Note: BackgroundTasks framework is iOS/iPadOS. On macOS, we use a timer-based approach
// with UserDefaults to track last scan date and schedule via app lifecycle.

// MainActor-isolated so the rescheduled Timer is always installed on the main
// run loop. runBackgroundScan() awaits the ScanEngine actor and would otherwise
// resume on a cooperative-pool thread, scheduling the next Timer on a run loop
// that never runs — so the weekly scan would fire only once.
@MainActor
final class ScanScheduler {
    static let shared = ScanScheduler()
    static let taskIdentifier = "dev.macsweep.weeklyscan"

    /// Defaults key backing Settings → General → "Weekly background scan".
    static let enabledDefaultsKey = "backgroundScanEnabled"

    /// Enabled unless the user has explicitly turned the setting off.
    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    // Interval and next-scan date live in the shared suite domain so the `macsweep`
    // CLI (`schedule status` / `set-interval`) can read and steer this scheduler
    // even though it runs as a separate process.
    private let config = SchedulerConfig()
    private var timer: Timer?

    func register() {
        // Respect the user's setting across launches. Disabling the scan clears
        // the next-scan date, which would otherwise look like a first launch
        // here and silently re-schedule the scan the user turned off.
        guard Self.isEnabled else { return }
        scheduleIfNeeded()
    }

    func scheduleWeeklyScan() {
        // Store next scan date one interval out (interval is user-configurable via CLI).
        let nextScanDate = Date(timeIntervalSinceNow: config.intervalSeconds)
        config.setNextScheduledScan(nextScanDate)
        scheduleTimer(for: nextScanDate)
    }

    func cancelScheduledScan() {
        timer?.invalidate()
        timer = nil
        config.setNextScheduledScan(nil)
    }

    private func scheduleIfNeeded() {
        if let nextDate = config.nextScheduledScan {
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
            if Self.isEnabled {
                scheduleWeeklyScan()
            }
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

        // Notify if > 100MB found (already on the main actor).
        if totalSize > 100_000_000 {
            NotificationManager.shared.sendScanComplete(bytesFound: totalSize)
        }

        // Schedule next scan, unless the user disabled the setting mid-scan.
        if Self.isEnabled {
            scheduleWeeklyScan()
        }
    }
}
