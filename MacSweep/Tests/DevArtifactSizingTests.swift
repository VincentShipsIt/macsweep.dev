import Foundation
import Testing

@testable import MacSweepCore

struct DevArtifactSizingTests {
    @Test func artifactSizingIsBoundedAndDoesNotFollowDependencyLinks() throws {
        let temp = try TempTestDirectory(prefix: "ArtifactSizing")
        let root = temp.url
        let target = root.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: target.appendingPathComponent("generated.bin"))
        let outside = root.appendingPathComponent("user-data")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: outside.appendingPathComponent("private.bin"))
        try FileManager.default.createSymbolicLink(
            at: target.appendingPathComponent("shared"), withDestinationURL: outside)
        let measured = try DevArtifactContent.measure(target)
        #expect(measured.size == 4096)
        #expect(throws: DevArtifactSafetyError.self) {
            try DevArtifactContent.measure(target, maximumEntries: 1)
        }
        #expect(throws: DevArtifactSafetyError.self) {
            try DevArtifactContent.measure(target, deadline: ProcessInfo.processInfo.systemUptime - 1)
        }
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("private.bin").path))
    }

    @Test func discoveryBudgetPreservesFindingsAndReportsIncompleteCoverage() async throws {
        let temp = try TempTestDirectory(prefix: "DiscoveryBudget")
        for marker in ["package.json", "turbo.json"] {
            try Data("{}".utf8).write(to: temp.url.appendingPathComponent(marker))
        }
        for name in ["node_modules", "dist", ".next", ".turbo", "coverage"] {
            let artifact = temp.url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: artifact.appendingPathComponent("generated.bin"))
        }
        var module = DevToolsModule()
        module.searchPaths = [temp.url]
        module.minimumDirectorySize = 0
        module.includesSystemCaches = false
        module.maximumDiscoveryEntries = 6
        module.safety.processSnapshot = { DevProcessSnapshot() }
        do {
            _ = try await ScanDiagnostics.collect { try await module.scan() }
            Issue.record("Expected explicit partial-scan diagnostics")
        } catch let partial as PartialModuleScanError {
            #expect(!partial.items.isEmpty)
            #expect(partial.issues.contains { $0.contains("discovery stopped at its safety limit") })
            #expect(partial.items.allSatisfy { $0.devArtifactReceipt != nil })
        }
    }

}
