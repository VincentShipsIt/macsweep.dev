import Foundation
import Testing
@testable import MacSweepCore

struct BuildArtifactScanStateTests {
    private func cleanupItem(id: UUID, path: String, size: Int64) -> CleanupItem {
        CleanupItem(
            id: id,
            path: URL(fileURLWithPath: path),
            size: size,
            type: .directory,
            module: "dev-tools",
            moduleName: "Developer Tools"
        )
    }

    private func gitCleanupItem(id: UUID, repositoryPath: URL) -> GitCleanupItem {
        GitCleanupItem(
            id: id,
            kind: .worktree,
            repositoryPath: repositoryPath,
            displayPath: repositoryPath.appendingPathComponent("stale-worktree"),
            branchName: "stale-branch",
            size: 16_384,
            lastActivity: nil,
            reason: "No recent activity",
            commandPreview: "git worktree remove"
        )
    }

    @Test func defaultsToAnEmptyIdleScan() {
        let state = BuildArtifactScanState()

        #expect(!state.isScanning)
        #expect(state.projects.isEmpty)
        #expect(state.projectCleanupItems.isEmpty)
        #expect(state.systemArtifacts.isEmpty)
        #expect(state.gitArtifacts.isEmpty)
        #expect(state.selectedItems.isEmpty)
        #expect(state.selectedGitItems.isEmpty)
        #expect(state.errorMessage == nil)
        #expect(state.gitToolStatus == nil)
    }

    @Test func retainsScanResultsSelectionsAndDiagnostics() throws {
        let projectPath = URL(fileURLWithPath: "/tmp/example-project")
        let artifactPath = projectPath.appendingPathComponent(".build")
        let projectItemID = try #require(UUID(uuidString: "D34BD2CB-95D8-4D4E-98E5-C96442C2FE90"))
        let systemItemID = try #require(UUID(uuidString: "59C512A5-8EF2-496C-B738-F8C03035B478"))
        let gitItemID = try #require(UUID(uuidString: "9E9CF88F-401B-4318-AD8F-866F23C43121"))
        let projectItem = cleanupItem(id: projectItemID, path: artifactPath.path, size: 4_096)
        let systemItem = cleanupItem(id: systemItemID, path: "/tmp/DerivedData", size: 8_192)
        let gitItem = gitCleanupItem(id: gitItemID, repositoryPath: projectPath)

        var state = BuildArtifactScanState()
        state.isScanning = true
        state.projects = [ProjectInfo(path: projectPath, type: .swift, artifactPaths: [artifactPath])]
        state.projectCleanupItems = [projectItem]
        state.systemArtifacts = [systemItem]
        state.gitArtifacts = [gitItem]
        state.selectedItems = [projectItemID, systemItemID]
        state.selectedGitItems = [gitItemID]
        state.errorMessage = "One scan source was unavailable"
        state.gitToolStatus = GitToolStatus(
            gitPath: "/usr/bin/git",
            ghPath: "/opt/homebrew/bin/gh",
            ghAuthenticated: true
        )

        #expect(state.isScanning)
        #expect(state.projects.count == 1)
        #expect(state.projects[0].path == projectPath)
        #expect(state.projects[0].artifactPaths == [artifactPath])
        #expect(state.projectCleanupItems == [projectItem])
        #expect(state.systemArtifacts == [systemItem])
        #expect(state.gitArtifacts == [gitItem])
        #expect(state.selectedItems == [projectItemID, systemItemID])
        #expect(state.selectedGitItems == [gitItemID])
        #expect(state.errorMessage == "One scan source was unavailable")
        #expect(state.gitToolStatus?.gitPath == "/usr/bin/git")
        #expect(state.gitToolStatus?.ghPath == "/opt/homebrew/bin/gh")
        #expect(state.gitToolStatus?.canUseGitHubCLI == true)
    }
}
