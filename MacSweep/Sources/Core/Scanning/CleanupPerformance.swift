import Foundation

struct CleanupPerformanceEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let bytesFreed: Int64
    let itemsProcessed: Int
    let errorCount: Int

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        bytesFreed: Int64,
        itemsProcessed: Int,
        errorCount: Int
    ) {
        self.id = id
        self.timestamp = timestamp
        self.bytesFreed = bytesFreed
        self.itemsProcessed = itemsProcessed
        self.errorCount = errorCount
    }

    init(result: CleanupResult) {
        self.init(
            timestamp: result.timestamp,
            bytesFreed: result.bytesFreed,
            itemsProcessed: result.itemsProcessed,
            errorCount: result.errors.count
        )
    }

    var hasCleanupWork: Bool {
        bytesFreed > 0 || itemsProcessed > 0 || errorCount > 0
    }
}

struct CleanupPerformanceSummary: Equatable, Sendable {
    let entries: [CleanupPerformanceEntry]
    let generatedAt: Date
    let windowDays: Int

    init(entries: [CleanupPerformanceEntry], generatedAt: Date = Date(), windowDays: Int = 30) {
        self.generatedAt = generatedAt
        self.windowDays = windowDays

        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -windowDays, to: generatedAt) ?? .distantPast
        self.entries = entries
            .filter { $0.timestamp >= start && $0.timestamp <= generatedAt }
            .sorted { $0.timestamp < $1.timestamp }
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    var cleanupCount: Int {
        entries.count
    }

    var totalBytesFreed: Int64 {
        entries.reduce(0) { $0 + $1.bytesFreed }
    }

    var totalItemsProcessed: Int {
        entries.reduce(0) { $0 + $1.itemsProcessed }
    }

    var totalErrors: Int {
        entries.reduce(0) { $0 + $1.errorCount }
    }

    var successRate: Double? {
        let attempts = totalItemsProcessed + totalErrors
        guard attempts > 0 else { return nil }
        return Double(totalItemsProcessed) / Double(attempts)
    }

    var lastCleanup: CleanupPerformanceEntry? {
        entries.last
    }

    var bestCleanup: CleanupPerformanceEntry? {
        entries.max { lhs, rhs in
            if lhs.bytesFreed == rhs.bytesFreed {
                return lhs.itemsProcessed < rhs.itemsProcessed
            }
            return lhs.bytesFreed < rhs.bytesFreed
        }
    }

    var recentChartEntries: [CleanupPerformanceEntry] {
        Array(entries.suffix(12))
    }
}

final class CleanupPerformanceStore: @unchecked Sendable {
    static let shared = CleanupPerformanceStore()

    static let historyKey = "cleanupPerformanceHistory"
    private static let maxHistoryEntries = 250
    private static let maxHistoryDays = 180

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: SchedulerConfig.suiteName) ?? .standard
    }

    var history: [CleanupPerformanceEntry] {
        get {
            guard let data = defaults.data(forKey: Self.historyKey),
                  let entries = try? JSONDecoder().decode([CleanupPerformanceEntry].self, from: data)
            else { return [] }

            return entries.sorted { $0.timestamp < $1.timestamp }
        }
        set {
            let pruned = Self.pruned(newValue)
            guard let data = try? JSONEncoder().encode(pruned) else { return }
            defaults.set(data, forKey: Self.historyKey)
        }
    }

    @discardableResult
    func record(_ result: CleanupResult) -> CleanupPerformanceEntry? {
        let entry = CleanupPerformanceEntry(result: result)
        guard entry.hasCleanupWork else { return nil }

        history.append(entry)
        return entry
    }

    func summary(generatedAt: Date = Date(), windowDays: Int = 30) -> CleanupPerformanceSummary {
        CleanupPerformanceSummary(entries: history, generatedAt: generatedAt, windowDays: windowDays)
    }

    private static func pruned(_ entries: [CleanupPerformanceEntry]) -> [CleanupPerformanceEntry] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -maxHistoryDays, to: Date()) ?? .distantPast
        let recentEntries = entries
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }

        return Array(recentEntries.suffix(maxHistoryEntries))
    }
}
