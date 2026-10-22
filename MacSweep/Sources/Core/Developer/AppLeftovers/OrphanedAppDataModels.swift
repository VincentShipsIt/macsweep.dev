import Darwin
import Foundation

struct AppOwnershipInventory: Sendable {
    var installed: Set<String> = []
    var running: Set<String> = []
    var installedNames: Set<String> = []
    var issues: [String] = []
}

struct OrphanedAppData: Identifiable, Sendable {
    enum Confidence: String, Sendable {
        case grounded = "Metadata grounded"
        case uncertain = "Uncertain ownership"
    }
    let path: URL
    let identifier: String?
    let category: String
    let size: Int64
    let modified: Date?
    let confidence: Confidence
    let evidence: String
    let retentionReason: String?
    let nodes: [DevArtifactNode]
    let identity: DevArtifactIdentity?
    var id: String { path.path }
    var isSelectable: Bool { retentionReason == nil && identity != nil && !nodes.isEmpty }
    func retaining(_ reason: String) -> Self {
        Self(
            path: path, identifier: identifier, category: category, size: size, modified: modified,
            confidence: confidence, evidence: evidence, retentionReason: reason, nodes: nodes, identity: identity)
    }
    var cleanupItem: CleanupItem {
        CleanupItem(
            id: UUID(), path: path, size: size,
            type: identity?.type == S_IFREG ? .file : .directory,
            module: "app-leftovers", moduleName: "App Leftovers", lastModified: modified,
            cleanupReviewReason: evidence)
    }
}

struct AppLeftoversReport: Sendable {
    var findings: [OrphanedAppData] = []
    var issues: [String] = []
}
