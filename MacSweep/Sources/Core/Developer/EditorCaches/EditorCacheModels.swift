import Darwin
import Foundation

struct EditorApplicationInventory: Sendable {
    var installedIDs: Set<String> = []
    var runningIDs: Set<String> = []
    var jetBrainsSelectors: Set<String> = []
    var issues: [String] = []
}

enum EditorCacheKind: String, Sendable {
    case jetBrains = "JetBrains Cache"
    case configuration = "JetBrains Configuration"
    case workspace = "Dead Workspace"
    case obsoleteExtension = "Obsolete Extension"
    case electron = "Electron Cache"
}

struct EditorCacheCandidate: Sendable {
    let path: URL
    let safetyRoot: URL
    let owner: String
    let ownerIDs: Set<String>
    let kind: EditorCacheKind
    let evidence: String
    var retentionReason: String?
}

struct EditorCacheFinding: Identifiable, Sendable {
    let candidate: EditorCacheCandidate
    let identity: DevArtifactIdentity?
    let nodes: [DevArtifactNode]
    let modified: Date?
    let size: Int64
    let retentionReason: String?
    var id: String { candidate.path.path }
    var isSelectable: Bool { retentionReason == nil && identity != nil && !nodes.isEmpty }
    var cleanupItem: CleanupItem {
        CleanupItem(
            id: UUID(), path: candidate.path, size: size, type: .directory,
            module: "editor-caches", moduleName: "IDE & Editor Caches", lastModified: modified,
            cleanupReviewReason: candidate.evidence)
    }
}

struct EditorCachesReport: Sendable {
    var findings: [EditorCacheFinding] = []
    var issues: [String] = []
}

struct EditorCacheProduct: Sendable {
    let name: String
    let directory: String
    let extensionDirectory: String
    let bundleIDs: Set<String>

    static let editors: [Self] = [
        Self(
            name: "VS Code", directory: "Code", extensionDirectory: ".vscode",
            bundleIDs: ["com.microsoft.VSCode"]),
        Self(
            name: "Cursor", directory: "Cursor", extensionDirectory: ".cursor",
            bundleIDs: ["com.todesktop.230313mzl4w4u92"]),
        Self(
            name: "VSCodium", directory: "VSCodium", extensionDirectory: ".vscode-oss",
            bundleIDs: ["com.vscodium"])
    ]
    static let electron: [Self] = [
        Self(name: "Slack", directory: "Slack", extensionDirectory: "", bundleIDs: ["com.tinyspeck.slackmacgap"]),
        Self(name: "Discord", directory: "discord", extensionDirectory: "", bundleIDs: ["com.hnc.Discord"]),
        Self(name: "Notion", directory: "Notion", extensionDirectory: "", bundleIDs: ["notion.id"]),
        Self(
            name: "Figma", directory: "Figma", extensionDirectory: "",
            bundleIDs: ["com.figma.Desktop", "com.figma.agent"])
    ]
}
