import Foundation
import Testing
@testable import MacSweepCore

/// Regression tests for #83: dev-artifact cleanup now skips artifacts whose
/// project shows recent activity (a build may be in progress), via
/// `DevToolsModule.projectHasRecentActivity(forArtifactAt:)`.
final class DevArtifactActivityGateTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSweepDevArtifact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func setModificationDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Build a project dir with a `package.json` and a `node_modules` artifact,
    /// returning the artifact URL.
    private func makeNodeProject(indicatorAge: TimeInterval) throws -> URL {
        let project = root.appendingPathComponent("app")
        let nodeModules = project.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)

        let packageJSON = project.appendingPathComponent("package.json")
        try "{}".write(to: packageJSON, atomically: true, encoding: .utf8)
        try setModificationDate(Date().addingTimeInterval(-indicatorAge), of: packageJSON)

        // The artifact dir itself is always "fresh" (just created) — the gate must
        // ignore it and look only at non-artifact files.
        return nodeModules
    }

    @Test func recentlyTouchedProjectIsActive() throws {
        // package.json modified 1 hour ago → active.
        let artifact = try makeNodeProject(indicatorAge: 60 * 60)
        #expect(DevToolsModule.projectHasRecentActivity(forArtifactAt: artifact) == true)
    }

    @Test func staleProjectIsNotActive() throws {
        // package.json modified 10 days ago → not active.
        let artifact = try makeNodeProject(indicatorAge: 10 * 24 * 60 * 60)
        // Also backdate the project directory entry itself.
        try setModificationDate(
            Date().addingTimeInterval(-10 * 24 * 60 * 60),
            of: artifact.deletingLastPathComponent()
        )
        #expect(DevToolsModule.projectHasRecentActivity(forArtifactAt: artifact) == false)
    }

    @Test func freshArtifactDirAloneDoesNotCountAsActivity() throws {
        // Only the artifact dir is recent; the sole source file is old. The gate
        // excludes artifact directories, so the project reads as inactive.
        let artifact = try makeNodeProject(indicatorAge: 30 * 24 * 60 * 60)
        try setModificationDate(
            Date().addingTimeInterval(-30 * 24 * 60 * 60),
            of: artifact.deletingLastPathComponent()
        )
        // node_modules stays fresh (just created) but must be ignored.
        #expect(DevToolsModule.projectHasRecentActivity(forArtifactAt: artifact) == false)
    }
}
