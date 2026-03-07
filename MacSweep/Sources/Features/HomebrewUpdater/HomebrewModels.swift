import Foundation

struct BrewPackage: Identifiable, Codable {
    let id: UUID
    let name: String
    let currentVersion: String
    let latestVersion: String
    let isOutdated: Bool
    var isSelected: Bool
    var aiInsight: BrewUpdateInsight?
}

struct BrewUpdateInsight: Codable {
    let changesSummary: String
    let hasBreakingChanges: Bool
    let breakingChangesDetail: String?
    let upgradeRecommendation: String
    let upgradeOrder: Int?
}

// MARK: - Brew JSON Parsing Helpers

struct BrewOutdatedResponse: Decodable {
    let formulae: [BrewFormulaEntry]
    let casks: [BrewCaskEntry]
}

struct BrewFormulaEntry: Decodable {
    let name: String
    let installedVersions: [String]
    let currentVersion: String
    let pinned: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
        case pinned
    }
}

struct BrewCaskEntry: Decodable {
    let name: String
    let installedVersions: [String]
    let currentVersion: String

    enum CodingKeys: String, CodingKey {
        case name
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
    }
}
