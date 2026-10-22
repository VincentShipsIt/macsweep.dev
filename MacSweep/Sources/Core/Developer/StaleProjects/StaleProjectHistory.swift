import Foundation

struct StaleProjectActionRecord: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case artifactSweep, archive, checkoutTrash }
    let id: UUID
    let timestamp: Date
    let kind: Kind
    let project: String
    let targets: [String]
    let archive: String?
    let archiveBytes: Int64?
    let estimatedTargetBytes: Int64?
    let completedCount: Int
    let errors: [String]
}

/// Archive creation is a copy, so it is deliberately separate from shared cleanup history.
final class StaleProjectHistory: @unchecked Sendable {
    static let shared = StaleProjectHistory()
    private let queue = DispatchQueue(label: "dev.macsweep.stale-project-history")
    private let defaults: UserDefaults?
    private var records: [StaleProjectActionRecord]
    private static let key = "staleProjectActionHistory"

    init(defaults: UserDefaults? = .standard, inMemory: Bool = false) {
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.arguments.contains { $0.contains("PackageTests") }
        self.defaults = inMemory || testing ? nil : defaults
        records = self.defaults?.data(forKey: Self.key).flatMap {
            try? JSONDecoder().decode([StaleProjectActionRecord].self, from: $0)
        } ?? []
    }

    func history() -> [StaleProjectActionRecord] {
        queue.sync { records }
    }

    func record(
        _ kind: StaleProjectActionRecord.Kind, project: URL, targets: [URL], archive: URL? = nil,
        archiveBytes: Int64? = nil, estimatedTargetBytes: Int64? = nil, completedCount: Int,
        errors: [String] = [],
    ) {
        queue.sync {
            records.insert(StaleProjectActionRecord(
                id: UUID(), timestamp: Date(), kind: kind, project: project.path,
                targets: targets.map(\.path), archive: archive?.path, archiveBytes: archiveBytes,
                estimatedTargetBytes: estimatedTargetBytes, completedCount: completedCount, errors: errors,
            ), at: 0)
            records = Array(records.prefix(100))
            if let data = try? JSONEncoder().encode(records) {
                defaults?.set(data, forKey: Self.key)
            }
        }
    }
}
