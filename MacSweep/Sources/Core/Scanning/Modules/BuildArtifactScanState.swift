import Foundation

/// Scan-owned state lives above `FeaturePageShell` because that shell changes
/// from a landing-page scroll container to the results container when a scan
/// completes. Keeping these values in `BuildArtifactsView` caused SwiftUI to
/// recreate the child at that boundary and replace real findings with an empty
/// result state.
struct BuildArtifactScanState {
    var isScanning = false
    var projects: [ProjectInfo] = []
    var projectCleanupItems: [CleanupItem] = []
    var systemArtifacts: [CleanupItem] = []
    var gitArtifacts: [GitCleanupItem] = []
    var selectedItems: Set<UUID> = []
    var selectedGitItems: Set<UUID> = []
    var errorMessage: String?
    var gitToolStatus: GitToolStatus?
}
