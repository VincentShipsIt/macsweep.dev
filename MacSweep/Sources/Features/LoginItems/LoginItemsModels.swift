import Foundation

enum LoginItemType: String, Codable, CaseIterable {
    case appService = "App"
    case launchAgent = "Launch Agent"
    case launchDaemon = "Launch Daemon"
}

struct LoginItem: Identifiable, Codable {
    let id: UUID
    let name: String
    let path: String
    let type: LoginItemType
    let bundleIdentifier: String?
    var isEnabled: Bool
    var aiAnalysis: AIItemAnalysis?
    /// The exact on-disk plist path captured at scan time (launch agents only).
    /// Mutations target THIS path, never a "<Label>.plist" guess, because a
    /// plist's filename frequently differs from its Label. nil for app-service
    /// items and legacy deserialized state. Declared last so the synthesized
    /// memberwise init keeps the existing argument order working.
    var plistPath: String? = nil
}

struct AIItemAnalysis: Codable {
    let summary: String         // plain English explanation
    let riskLevel: RiskLevel
    let recommendation: String  // "Safe to keep", "Consider disabling", "Suspicious"
    let lastSeenDaysAgo: Int?
}

enum RiskLevel: String, Codable {
    case safe, suspicious, unknown
}
