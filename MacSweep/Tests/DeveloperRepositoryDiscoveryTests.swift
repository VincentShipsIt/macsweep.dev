import Foundation
import Testing

@testable import MacSweepCore

struct DeveloperRepositoryDiscoveryTests {
    @Test func retainsFoundRepositoriesWhenEntryBudgetExpires() throws {
        let temp = try TempTestDirectory(prefix: "DiscoveryBounds")
        for name in ["one", "two", "three"] {
            try FileManager.default.createDirectory(at: temp.url.appending(path: name + "/.git"),
                                                    withIntermediateDirectories: true)
        }
        let result = try DeveloperRepositoryDiscovery.discover(
            searchPaths: [temp.url], homeDirectory: temp.url, maximumEntries: 2)
        #expect(result.roots.count == 1)
        #expect(result.issues.contains { $0.contains("partial") })
    }

    @Test func depthAndTimeLimitsAreReported() throws {
        let temp = try TempTestDirectory(prefix: "DiscoveryDepth")
        try FileManager.default.createDirectory(at: temp.url.appending(path: "a/b/repo/.git"),
                                                withIntermediateDirectories: true)
        let depth = try DeveloperRepositoryDiscovery.discover(
            searchPaths: [temp.url], homeDirectory: temp.url, maxDepth: 1)
        #expect(depth.roots.isEmpty)
        #expect(depth.issues.contains { $0.contains("depth") })
        let time = try DeveloperRepositoryDiscovery.discover(
            searchPaths: [temp.url], homeDirectory: temp.url, timeLimit: 0)
        #expect(time.roots.isEmpty)
        #expect(time.issues.contains { $0.contains("partial") })
    }

    @Test func skipsSymlinksAndDeduplicatesRoots() throws {
        let temp = try TempTestDirectory(prefix: "DiscoveryLinks")
        let repo = temp.url.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: temp.url.appending(path: "link"), withDestinationURL: repo)
        let result = try DeveloperRepositoryDiscovery.discover(
            searchPaths: [temp.url, repo, temp.url.appending(path: "link")], homeDirectory: temp.url)
        #expect(result.roots.map { $0.resolvingSymlinksInPath().path } == [repo.resolvingSymlinksInPath().path])
        #expect(!result.issues.isEmpty)
    }

    @Test func explicitRepositoryRootsRespectGlobalBudgetAndTimeLimit() throws {
        let temp = try TempTestDirectory(prefix: "DiscoveryExplicit")
        try FileManager.default.createDirectory(at: temp.url.appending(path: ".git"), withIntermediateDirectories: true)
        let entries = try DeveloperRepositoryDiscovery.discover(
            searchPaths: [temp.url], maximumEntries: 0)
        #expect(entries.roots.isEmpty)
        #expect(!entries.issues.isEmpty)
        let time = try DeveloperRepositoryDiscovery.discover(searchPaths: [temp.url], timeLimit: 0)
        #expect(time.roots.isEmpty)
        #expect(!time.issues.isEmpty)
    }

    @Test func protectedNonRepositoryRootsAreNotTraversed() throws {
        let temp = try TempTestDirectory(prefix: "DiscoveryProtected")
        try FileManager.default.createDirectory(at: temp.url.appending(path: "protected/repo/.git"),
                                                withIntermediateDirectories: true)
        let rules = UserProtectionRules(
            ignoreContents: "", protectContents: temp.url.appending(path: "protected").path, homeURL: temp.url)
        let result = try DeveloperRepositoryDiscovery.discover(
            searchPaths: [temp.url], homeDirectory: temp.url, checker: SafetyChecker(userRules: rules))
        #expect(result.roots.isEmpty)
    }

    @Test func artifactInspectionLimitReportsPartialCoverage() async throws {
        let temp = try TempTestDirectory(prefix: "InspectionBounds")
        try FileManager.default.createDirectory(at: temp.url.appending(path: "node_modules"),
                                                withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: temp.url.appending(path: "package.json"))
        var module = DevToolsModule()
        module.searchPaths = [temp.url]
        module.includesSystemCaches = false
        module.maximumInspectionTargets = 0
        module.safety.processSnapshot = { DevProcessSnapshot() }
        do {
            _ = try await ScanDiagnostics.collect { try await module.scan() }
            Issue.record("Expected partial coverage at the target inspection limit.")
        } catch let partial as PartialModuleScanError {
            #expect(partial.items.isEmpty)
            #expect(partial.issues.contains { $0.contains("inspection reached its safety limit") })
        }
    }

    @Test func recognizesArtifactsWithoutTraversingTheirContents() throws {
        let temp = try TempTestDirectory(prefix: "DiscoveryArtifacts")
        try FileManager.default.createDirectory(at: temp.url.appending(path: "repo/node_modules/nested/repo/.git"),
                                                withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: temp.url.appending(path: "repo/package.json"))
        let result = try DeveloperRepositoryDiscovery.discoverArtifacts(
            searchPaths: [temp.url], homeDirectory: temp.url)
        #expect(result.candidates.map(\.url.lastPathComponent) == ["node_modules"])
        let repos = try DeveloperRepositoryDiscovery.discover(searchPaths: [temp.url], homeDirectory: temp.url)
        #expect(repos.roots.isEmpty)
    }
}
