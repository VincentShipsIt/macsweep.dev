import Foundation
import Testing

@testable import MacSweepCore

struct EditorCacheSafetyTests {
    @Test func symlinksSensitiveFilesSettingsAndUnknownScopesNeverQualify() async throws {
        let fixture = try EditorCachesFixture()
        defer { fixture.destroy() }
        let target = try fixture.cache("Library/Caches/JetBrains/IntelliJIdea2025.1")
        let sensitive = target.appending(path: "credentials.json")
        try Data("fixture".utf8).write(to: sensitive)
        #expect(await fixture.service().scan().findings.allSatisfy { !$0.isSelectable })
        try FileManager.default.removeItem(at: sensitive)
        try FileManager.default.createSymbolicLink(
            at: target.appending(path: "alias"), withDestinationURL: fixture.home)
        #expect(await fixture.service().scan().findings.allSatisfy { !$0.isSelectable })
        let checker = SafetyChecker()
        let root = fixture.home.appending(path: ".vscode/extensions")
        #expect(
            checker.validateForEditorCacheTreeNode(
                root.appending(path: "fixture.extension-1.0.0"),
                within: root, homeDirectory: fixture.home
            ).isSafe)
        #expect(
            !checker.validateForEditorCacheTreeNode(
                root.appending(path: "../settings.json"),
                within: root, homeDirectory: fixture.home
            ).isSafe)
        #expect(
            !checker.validateForEditorCacheTreeNode(
                root.appending(path: "fixture.extension-1.0.0/id_rsa"),
                within: root, homeDirectory: fixture.home
            ).isSafe)
        #expect(
            !checker.validateForEditorCacheTreeNode(
                fixture.home.appending(path: "anything"),
                within: fixture.home, homeDirectory: fixture.home
            ).isSafe)
    }

    @Test func cloudAmbiguousAndProtectedRecordedWorkspacesStayLocked() async throws {
        let fixture = try EditorCachesFixture()
        defer { fixture.destroy() }
        _ = try fixture.workspace(
            id: "cloud", value: fixture.home.appending(path: "Library/CloudStorage/Offline/missing").absoluteString)
        let protected = fixture.home.appending(path: "projects/protected")
        _ = try fixture.workspace(id: "protected", value: protected.absoluteString)
        let ambiguous = try fixture.workspace(
            id: "ambiguous", value: fixture.home.appending(path: "missing").absoluteString)
        try fixture.json(
            [
                "folder": fixture.home.appending(path: "missing").absoluteString,
                "workspace": fixture.home.appending(path: "missing.code-workspace").absoluteString
            ],
            at: ambiguous.appending(path: "workspace.json"))
        var service = fixture.service()
        service.protectionRules = {
            SafetyChecker(
                userRules: UserProtectionRules(
                    ignoreContents: "", protectContents: protected.path + "\n",
                    homeURL: fixture.home))
        }
        let report = await service.scan()
        #expect(report.findings.count == 3 && report.findings.allSatisfy { !$0.isSelectable })
    }

    @Test func incompleteApplicationInventoryRetainsEverythingAndMissingToolsAreQuiet() async throws {
        let fixture = try EditorCachesFixture()
        defer { fixture.destroy() }
        #expect(await fixture.service().scan().findings.isEmpty)
        _ = try fixture.cache("Library/Caches/JetBrains/IntelliJIdea2025.1")
        let report = await fixture.service(apps: .init(issues: ["installed app metadata inaccessible"])).scan()
        #expect(!report.issues.isEmpty && report.findings.allSatisfy { !$0.isSelectable })
    }
}
