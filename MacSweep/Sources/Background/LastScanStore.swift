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
    private let legacyDefaults = UserDefaults.standard

    var lastScan: ScanSummary? {
        get {
            let key = SchedulerConfig.lastScanKey
            if let data = defaults.data(forKey: key) {
                return try? JSONDecoder().decode(ScanSummary.self, from: data)
            }

            guard let legacyData = legacyDefaults.data(forKey: key),
                  let summary = try? JSONDecoder().decode(ScanSummary.self, from: legacyData)
            else { return nil }

            defaults.set(legacyData, forKey: key)
            return summary
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: SchedulerConfig.lastScanKey)
        }
    }
}
