import Foundation
import Testing

@testable import MacSweepCore

struct EditorCleanupOwnershipTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    @Test func everyGenericCleanupRouteRetainsEditorOwnedRootsAndAncestors() {
        let checker = SafetyChecker(userRules: .empty)
        let relative = [
            "Library/Caches/JetBrains/OldIDE/LocalHistory",
            "Library/Application Support/Code/User/workspaceStorage/old",
            ".cursor/extensions/publisher.extension-1.0",
            "Library/Application Support/Slack/Code Cache/js",
            "Library/Application Support/discord/GPUCache/data",
            "Library/Caches/JetBrains", "Library/Caches"
        ]
        for entry in relative {
            let path = home.appending(path: entry)
            for module in ["system-cache", "ai-analysis", "dev-tools", "editor-caches"] {
                #expect(!checker.validateForCleanup(path, moduleID: module).isSafe)
            }
            #expect(!checker.validateForTrash(path).isSafe)
            #expect(!checker.validateForShred(path).isSafe)
        }
    }

    @Test func neighboringCachesRemainAvailableAndAnalyzerOmitsOwnedSuggestions() {
        let owned = home.appending(path: "Library/Application Support/Figma/Code Cache")
        let neighbor = home.appending(path: "Library/Caches/UnrelatedExample/cache.bin")
        #expect(SafetyChecker(userRules: .empty).validateForCleanup(neighbor, moduleID: "system-cache").isSafe)
        let findings = CacheAnalyzer.parseFastScanOutput("2\t\(owned.path)\n3\t\(neighbor.path)")
        #expect(findings.map(\.path) == [neighbor.path])
    }
}
