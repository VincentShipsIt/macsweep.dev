import Foundation

struct ScanSummary: Codable {
    let date: Date
    let bytesFound: Int64
    let itemCount: Int
}

class LastScanStore {
    static let shared = LastScanStore()
    // Use the shared scheduler suite (not `.standard`) so all scheduler-related
    // state lives in one plist that the CLI can also read.
    private let defaults = UserDefaults(suiteName: SchedulerConfig.suiteName) ?? .standard

    var lastScan: ScanSummary? {
        get {
            guard let data = defaults.data(forKey: SchedulerConfig.lastScanKey) else { return nil }
            return try? JSONDecoder().decode(ScanSummary.self, from: data)
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: SchedulerConfig.lastScanKey)
        }
    }
}
