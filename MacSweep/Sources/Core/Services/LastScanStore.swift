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
    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults

    init(defaults: UserDefaults? = nil, legacyDefaults: UserDefaults = .standard) {
        self.defaults = defaults ?? UserDefaults(suiteName: SchedulerConfig.suiteName) ?? .standard
        self.legacyDefaults = legacyDefaults
        migrateLegacyLastScanIfNeeded()
    }

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

    private func migrateLegacyLastScanIfNeeded() {
        guard defaults !== legacyDefaults else { return }

        let key = SchedulerConfig.lastScanKey
        if let data = defaults.data(forKey: key),
           (try? JSONDecoder().decode(ScanSummary.self, from: data)) != nil {
            legacyDefaults.removeObject(forKey: key)
            return
        }

        guard defaults.data(forKey: key) == nil,
              let legacyData = legacyDefaults.data(forKey: key),
              (try? JSONDecoder().decode(ScanSummary.self, from: legacyData)) != nil
        else { return }

        // Migrate once at initialization so reads stay side-effect free, then
        // remove the validated legacy copy after it has been persisted.
        defaults.set(legacyData, forKey: key)
        guard defaults.data(forKey: key) == legacyData else { return }
        legacyDefaults.removeObject(forKey: key)
    }
}
