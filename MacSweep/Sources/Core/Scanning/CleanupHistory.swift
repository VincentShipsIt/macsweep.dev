import Foundation

enum CleanupHistoryAction: String, Codable, Equatable, Sendable {
    case moveToTrash
    case deletePermanently
    case removeLocalDownload
    case runToolCleanup

    var displayName: String {
        switch self {
        case .moveToTrash: return "Moved to Trash"
        case .deletePermanently: return "Deleted permanently"
        case .removeLocalDownload: return "Removed local download"
        case .runToolCleanup: return "Ran tool cleanup"
        }
    }

    var isRecoverableFromTrash: Bool {
        self == .moveToTrash
    }

    static func action(for item: CleanupItem) -> CleanupHistoryAction {
        switch item.target {
        case .action:
            return .runToolCleanup
        case .fileSystem:
            break
        }

        switch item.module {
        case "system-cache", "trash-bins", "network",
             "browser-safari", "browser-chrome", "browser-firefox",
             "browser-brave", "browser-arc":
            return .deletePermanently
        case "cloud-cleanup":
            return item.moduleName.contains("Local Copy")
                ? .removeLocalDownload
                : .deletePermanently
        default:
            return .moveToTrash
        }
    }
}

enum CleanupHistoryOutcome: String, Codable, Equatable, Sendable {
    case completed
    case failed
}

struct CleanupHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let moduleID: String
    let moduleName: String
    let originalPath: String
    let action: CleanupHistoryAction
    let bytes: Int64
    let outcome: CleanupHistoryOutcome
    let errorMessage: String?

    init(
        id: UUID = UUID(),
        timestamp: Date,
        moduleID: String,
        moduleName: String,
        originalPath: String,
        action: CleanupHistoryAction,
        bytes: Int64,
        outcome: CleanupHistoryOutcome,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.moduleID = moduleID
        self.moduleName = moduleName
        self.originalPath = originalPath
        self.action = action
        self.bytes = bytes
        self.outcome = outcome
        self.errorMessage = errorMessage
    }

    var displayName: String {
        if originalPath.hasPrefix("macsweep-action://") {
            return moduleName
        }
        return URL(fileURLWithPath: originalPath).lastPathComponent
    }
}

struct CleanupHistoryRun: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let records: [CleanupHistoryRecord]

    init(id: UUID = UUID(), timestamp: Date, records: [CleanupHistoryRecord]) {
        self.id = id
        self.timestamp = timestamp
        self.records = records
    }

    var completedCount: Int {
        records.count { $0.outcome == .completed }
    }

    var failedCount: Int {
        records.count { $0.outcome == .failed }
    }

    var bytesCompleted: Int64 {
        records
            .filter { $0.outcome == .completed }
            .reduce(0) { $0 + $1.bytes }
    }

    var containsTrashRecovery: Bool {
        records.contains { $0.outcome == .completed && $0.action.isRecoverableFromTrash }
    }
}

final class CleanupHistoryStore: @unchecked Sendable {
    static let shared: CleanupHistoryStore = {
        let processName = ProcessInfo.processInfo.processName
        let isTestProcess = processName.contains("PackageTests")
            || processName.hasSuffix("Tests")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return isTestProcess ? CleanupHistoryStore(inMemory: true) : CleanupHistoryStore()
    }()

    static let historyKey = "cleanupDetailedHistory"
    private static let maxHistoryRuns = 100
    private static let maxHistoryDays = 180

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "dev.macsweep.cleanup-history")
    private var inMemoryHistory: [CleanupHistoryRun]?

    init(defaults: UserDefaults? = nil, inMemory: Bool = false) {
        self.defaults = defaults ?? UserDefaults(suiteName: SchedulerConfig.suiteName) ?? .standard
        inMemoryHistory = inMemory ? [] : nil
    }

    var history: [CleanupHistoryRun] {
        queue.sync { loadHistory() }
    }

    @discardableResult
    func record(items: [CleanupItem], result: CleanupResult) -> CleanupHistoryRun? {
        record(items: items, timestamp: result.timestamp, errors: result.errors, overallError: nil)
    }

    @discardableResult
    func recordFailure(items: [CleanupItem], error: Error, timestamp: Date = Date()) -> CleanupHistoryRun? {
        record(items: items, timestamp: timestamp, errors: [], overallError: error.localizedDescription)
    }

    private func record(
        items: [CleanupItem],
        timestamp: Date,
        errors: [CleanupError],
        overallError: String?
    ) -> CleanupHistoryRun? {
        guard !items.isEmpty else { return nil }

        let errorsByPath = Dictionary(grouping: errors, by: { $0.path.absoluteString })
        let records = items.map { item in
            let pathKey = item.path.absoluteString
            let itemError = errorsByPath[pathKey]?.first?.message ?? overallError
            return CleanupHistoryRecord(
                timestamp: timestamp,
                moduleID: item.module,
                moduleName: item.moduleName,
                originalPath: item.path.isFileURL ? item.path.path : item.path.absoluteString,
                action: CleanupHistoryAction.action(for: item),
                bytes: item.size,
                outcome: itemError == nil ? .completed : .failed,
                errorMessage: itemError
            )
        }
        let run = CleanupHistoryRun(timestamp: timestamp, records: records)

        queue.sync {
            var runs = loadHistory()
            runs.append(run)
            saveHistory(Self.pruned(runs))
        }
        return run
    }

    private func loadHistory() -> [CleanupHistoryRun] {
        if let inMemoryHistory {
            return inMemoryHistory.sorted { $0.timestamp < $1.timestamp }
        }
        guard let data = defaults.data(forKey: Self.historyKey),
              let runs = try? JSONDecoder().decode([CleanupHistoryRun].self, from: data)
        else { return [] }
        return runs.sorted { $0.timestamp < $1.timestamp }
    }

    private func saveHistory(_ runs: [CleanupHistoryRun]) {
        if inMemoryHistory != nil {
            inMemoryHistory = runs
            return
        }
        guard let data = try? JSONEncoder().encode(runs) else { return }
        defaults.set(data, forKey: Self.historyKey)
    }

    private static func pruned(_ runs: [CleanupHistoryRun]) -> [CleanupHistoryRun] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -maxHistoryDays, to: Date()) ?? .distantPast
        let recentRuns = runs
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }
        return Array(recentRuns.suffix(maxHistoryRuns))
    }
}
