import Foundation

struct ScanSummary: Codable {
    let date: Date
    let bytesFound: Int64
    let itemCount: Int
}

class LastScanStore {
    static let shared = LastScanStore()
    private let key = "lastScanSummary"

    var lastScan: ScanSummary? {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(ScanSummary.self, from: data)
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
