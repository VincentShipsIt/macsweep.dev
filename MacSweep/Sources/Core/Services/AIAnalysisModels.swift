import Foundation

enum CacheCategory: String, Codable, CaseIterable, Identifiable {
    case electronChromium = "Electron/Chromium"
    case packageManager = "Package Manager"
    case devDebugLogs = "Dev Debug Logs"
    case aiToolCache = "AI Tool Cache"
    case other = "Other"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .electronChromium: return "globe"
        case .packageManager: return "shippingbox"
        case .devDebugLogs: return "doc.text"
        case .aiToolCache: return "brain"
        case .other: return "folder"
        }
    }
}

enum ScanSource: String, Codable {
    case deterministic = "Fast Scan"
    case ai = "AI Analysis"
}

struct CacheFinding: Identifiable, Codable {
    let id: UUID
    let path: String
    let size: String
    let category: CacheCategory
    let regeneratesAutomatically: Bool
    let source: ScanSource
    let reason: String?
    var isSelected: Bool

    init(
        path: String,
        size: String,
        category: CacheCategory,
        regeneratesAutomatically: Bool,
        source: ScanSource,
        reason: String? = nil
    ) {
        self.id = UUID()
        self.path = path
        self.size = size
        self.category = category
        self.regeneratesAutomatically = regeneratesAutomatically
        self.source = source
        self.reason = reason
        self.isSelected = true
    }
}
