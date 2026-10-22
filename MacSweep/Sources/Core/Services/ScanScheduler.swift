import Foundation

@MainActor
final class ScanScheduler {
    static let shared = ScanScheduler()
    static let taskIdentifier = "dev.macsweep.weeklyscan"
    nonisolated static let enabledDefaultsKey = "backgroundScanEnabled"

    private let config: SchedulerConfig
    private let isEnabled: () -> Bool
    private let scan: () async -> PartialScanResult
    private let saveSummary: (ScanSummary) -> Void
    private let notify: @MainActor (Int64) -> Void
    private let now: () -> Date
    private var timer: Timer?
    private var activeScan: Task<Void, Never>?
    private var generation = UUID()

    init(
        config: SchedulerConfig = SchedulerConfig(),
        isEnabled: @escaping () -> Bool = {
            UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
        },
        scan: @escaping () async -> PartialScanResult = { await ScanEngine().scanWithDiagnostics() },
        saveSummary: @escaping (ScanSummary) -> Void = { LastScanStore.shared.lastScan = $0 },
        notify: @escaping @MainActor (Int64) -> Void = { NotificationManager.shared.sendScanComplete(bytesFound: $0) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.config = config
        self.isEnabled = isEnabled
        self.scan = scan
        self.saveSummary = saveSummary
        self.notify = notify
        self.now = now
    }

    func register() {
        guard isEnabled() else {
            cancelScheduledScan()
            return
        }
        if let date = config.nextScheduledScan {
            if date > now() { scheduleTimer(for: date) } else { startBackgroundScan() }
        } else {
            scheduleNextScan()
        }
    }

    func scheduleNextScan() {
        invalidateActiveScan()
        guard isEnabled() else {
            config.setNextScheduledScan(nil)
            return
        }
        let date = now().addingTimeInterval(config.intervalSeconds)
        config.setNextScheduledScan(date)
        scheduleTimer(for: date)
    }

    func updateIntervalDays(_ days: Int) {
        invalidateActiveScan()
        if let date = config.updateIntervalDays(days, scheduleEnabled: isEnabled(), now: now()) {
            scheduleTimer(for: date)
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    func cancelScheduledScan() {
        invalidateActiveScan()
        timer?.invalidate()
        timer = nil
        config.setNextScheduledScan(nil)
    }

    private func invalidateActiveScan() {
        generation = UUID()
        activeScan?.cancel()
        activeScan = nil
    }

    private func scheduleTimer(for date: Date) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: max(date.timeIntervalSince(now()), 1), repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.startBackgroundScan() }
        }
    }

    private func startBackgroundScan() {
        guard isEnabled(), activeScan == nil else { return }
        let token = generation
        activeScan = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await scan()
            guard token == generation, isEnabled(), !Task.isCancelled else { return }
            activeScan = nil
            if !result.isPartial {
                let summary = ScanSummary(
                    date: now(), bytesFound: result.items.estimatedBytes,
                    itemCount: result.items.count)
                saveSummary(summary)
                if summary.bytesFound > 100_000_000 { notify(summary.bytesFound) }
            }
            scheduleNextScan()
        }
    }
}
