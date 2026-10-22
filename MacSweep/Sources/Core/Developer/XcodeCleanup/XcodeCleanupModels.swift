import Foundation

enum XcodeCleanupCategory: String, CaseIterable, Identifiable, Sendable {
    case runtimes, simulators, deviceSupport, archives, previews, applications
    var id: String { rawValue }
    var title: String {
        switch self {
        case .runtimes: return "Simulator Runtimes"
        case .simulators: return "Unavailable Simulators"
        case .deviceSupport: return "Device Support"
        case .archives: return "Archives"
        case .previews: return "Preview & Simulator Caches"
        case .applications: return "Xcode Applications"
        }
    }
}

enum XcodeCleanupMechanism: Equatable, Sendable {
    case runtime(UUID)
    case simulator(UUID)
    case trash
    var description: String {
        switch self {
        case .runtime(let id): return "xcrun simctl runtime delete \(id.uuidString)"
        case .simulator(let id): return "xcrun simctl delete \(id.uuidString)"
        case .trash: return "Move to Trash; space is recovered when Trash is emptied"
        }
    }
    var cost: String {
        switch self {
        case .runtime: return "Reinstall the runtime in Xcode to use it again."
        case .simulator: return "Simulator apps and data cannot be restored by simctl."
        case .trash: return "Restore from Trash if needed; caches or symbols may need rebuilding."
        }
    }
}

struct XcodeCleanupTarget: Identifiable, Sendable {
    let id: String
    let reviewID = UUID()
    let category: XcodeCleanupCategory
    let name: String
    let path: URL
    let bytes: Int64?
    let lastUsed: Date?
    let mechanism: XcodeCleanupMechanism
    var retentionReason: String?
    let evidence: XcodeCleanupEvidence?
    var canRemove: Bool { retentionReason == nil && bytes != nil && evidence != nil }
    var preview: CleanupItem {
        CleanupItem(
            id: reviewID, path: path, size: bytes ?? 0, type: .directory,
            module: "xcode-cleanup", moduleName: category.title, lastModified: lastUsed,
            cleanupReviewReason: retentionReason ?? mechanism.cost)
    }
}

struct XcodeCleanupEvidence: Equatable, Sendable {
    let identity: DevArtifactIdentity?
    let nodes: [DevArtifactNode]
    let nativeSignature: String?
}

struct XcodeCleanupInventory: Sendable {
    var targets: [XcodeCleanupTarget] = []
    var issues: [String] = []
    var selectedDeveloper: String?
    var nativeCommandsAvailable = false
}

struct XcodeCleanupReceipt: Sendable {
    let removedIDs: [String]
    let errors: [String]
    let removedTargetBytes: Int64
    let observation: VolumeSpaceObservation?
    let trashedBytes: Int64
}

struct XcodeCleanupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

typealias XcodeCommand = @Sendable (String, [String], TimeInterval) async throws -> ProcessResult
