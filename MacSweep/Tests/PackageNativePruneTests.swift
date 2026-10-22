import Foundation
import Testing

@testable import MacSweepCore

final class PackageNativePruneTests {
    let temp: TempTestDirectory
    let home: URL
    init() throws {
        temp = try TempTestDirectory(prefix: "NativePrune")
        home = temp.url.resolvingSymlinksInPath()
    }
    private func module(
        manager: String = "uv", runner: @escaping PackageCacheCommandRunner
    ) throws -> PackageManagerModule {
        let path = home.appendingPathComponent(manager == "uv" ? ".cache/uv" : ".bun/install/cache")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: path.appendingPathComponent("cached.bin"))
        var module = PackageManagerModule()
        module.homeDirectory = home
        module.processSnapshot = { DevProcessSnapshot() }
        module.toolPath = { _ in "/tools/\(manager)" }
        module.commandRunner = runner
        return module
    }
    private func response(_ args: [String], status: Int32 = 0, version: String = "uv 0.11.0") -> ProcessResult {
        if args == ["--version"] { return ProcessResult(status: 0, output: version, error: "") }
        if args.last == "--help" {
            return ProcessResult(
                status: 0, output: "Usage: uv cache prune --cache-dir --no-config --offline", error: "")
        }
        return ProcessResult(status: status, output: "", error: "")
    }
    @Test func uvIsFirstClassAndUsesExactNativePruneWithHonestAccounting() async throws {
        let commands = NativeCommandLedger()
        let module = try module { _, args in
            commands.add(args)
            return self.response(args)
        }
        let items = try await module.scan()
        #expect(items.count == 1)
        #expect(PackageManagerInfo.all.contains { $0.id == "uv" })
        #expect(items[0].managedCleanupReceipt?.preview.contains("no Trash recovery") == true)
        let result = try await module.clean(items: items, dryRun: false)
        #expect(result.itemsProcessed == 1)
        #expect(result.bytesFreed == 0)
        #expect(result.historyActions[items[0].id] == .runToolCleanup)
        #expect(
            commands.values.contains(["cache", "prune", "--cache-dir", items[0].path.path, "--no-config", "--offline"]))
        #expect(!commands.values.flatMap { $0 }.contains("--force"))
        #expect(FileManager.default.fileExists(atPath: items[0].path.path))
    }
    @Test func missingAndUnsupportedManagersRetainCache() async throws {
        var module = try module { _, args in self.response(args, version: "unknown") }
        let unsupported = try await module.scan()
        #expect(unsupported[0].managedCleanupReceipt?.isEligible == false)
        module.toolPath = { _ in nil }
        let missing = try await module.scan()
        #expect(missing[0].cleanupReviewReason?.contains("missing") == true)
        #expect(try await module.clean(items: missing, dryRun: false).itemsProcessed == 0)
    }
    @Test func commandFailureHasNoFallbackAndNoByteCredit() async throws {
        let module = try module { _, args in self.response(args, status: 1) }
        let items = try await module.scan()
        let result = try await module.clean(items: items, dryRun: false)
        #expect(result.itemsProcessed == 0)
        #expect(result.bytesFreed == 0)
        #expect(result.errors.first?.message.contains("may have changed") == true)
        #expect(FileManager.default.fileExists(atPath: items[0].path.appendingPathComponent("cached.bin").path))
    }
    @Test func timeoutReportsPossiblePartialChangeWithoutFallback() async throws {
        let module = try module { _, args in
            if args == ["--version"] || args.last == "--help" { return self.response(args) }
            throw ProcessRunnerError.timedOut(
                after: 15,
                partialResult: ProcessResult(status: -1, output: "partial", error: ""))
        }
        let items = try await module.scan()
        let result = try await module.clean(items: items, dryRun: false)
        #expect(result.itemsProcessed == 0)
        #expect(result.bytesFreed == 0)
        #expect(result.errors.first?.message.contains("may have changed") == true)
        #expect(FileManager.default.fileExists(atPath: items[0].path.path))
    }

    @Test func bunPruneRequiresVerifiedVersionAndKeepsGlobalStoreScope() async throws {
        let commands = NativeCommandLedger()
        let module = try module(manager: "bun") { _, args in
            commands.add(args)
            return ProcessResult(status: 0, output: args == ["--version"] ? "1.4.3" : "bun pm cache prune", error: "")
        }
        let items = try await module.scan()
        #expect(items[0].managedCleanupReceipt?.isEligible == true)
        #expect(try await module.clean(items: items, dryRun: false).itemsProcessed == 1)
        #expect(
            commands.values.contains(["pm", "cache", "prune", "--max-age", "30", "--cache-dir", items[0].path.path]))
        #expect(!commands.values.flatMap { $0 }.contains("rm"))
        #expect(!PackageManagerModule.supportsBunPrune("1.4.2"))
        #expect(!PackageManagerModule.supportsBunPrune("1.4.3-canary"))
    }
    @Test func dryRunNeverInvokesPruneAndCapabilityChangesBlockMutation() async throws {
        let commands = NativeCommandLedger()
        var module = try module { _, args in
            commands.add(args)
            return self.response(args)
        }
        let items = try await module.scan()
        #expect(try await module.clean(items: items, dryRun: true).itemsProcessed == 1)
        #expect(!commands.values.contains { $0.contains("prune") && $0.last != "--help" })
        module.commandRunner = { _, args in self.response(args, version: "uv 0.12.0") }
        #expect(try await module.clean(items: items, dryRun: false).itemsProcessed == 0)
    }
    @Test func uvCachedEnvironmentsAndInstalledToolLinksAreRetained() async throws {
        let module = try module { _, args in self.response(args) }
        let cache = home.appendingPathComponent(".cache/uv")
        let environment = cache.appendingPathComponent("environments-v2/fixture")
        try FileManager.default.createDirectory(at: environment, withIntermediateDirectories: true)
        #expect(try await module.scan().first?.cleanupReviewReason?.contains("environments") == true)
        try FileManager.default.removeItem(at: environment.deletingLastPathComponent())
        let tool = home.appendingPathComponent(".local/share/uv/tools/fixture")
        try FileManager.default.createDirectory(at: tool, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: tool.appendingPathComponent("dependency"), withDestinationURL: cache)
        #expect(try await module.scan().first?.cleanupReviewReason?.contains("tool links") == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSWEEP_TEST_UV"] != nil))
    func realUVPrunesDisposableOrphansThroughModule() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["MACSWEEP_TEST_UV"])
        let module = try module { command, args in
            try await ProcessRunner.run(
                executable: command, arguments: args, currentDirectory: URL(fileURLWithPath: "/"), timeout: 15)
        }
        var real = module
        real.toolPath = { _ in executable }
        let orphan = home.appendingPathComponent(".cache/uv/archive-v0/unused-fixture")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("owned disposable fixture".utf8).write(to: orphan.appendingPathComponent("value"))
        let items = try await real.scan()
        let item = try #require(items.first)
        try #require(
            item.managedCleanupReceipt?.isEligible == true,
            Comment(rawValue: item.cleanupReviewReason ?? ""))
        let result = try await real.clean(items: items, dryRun: false)
        #expect(result.itemsProcessed == 1)
        #expect(result.bytesFreed == 0)
        #expect(result.errors.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: item.path.path))
    }

}

final class NativeCommandLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[String]] = []
    func add(_ args: [String]) {
        lock.lock()
        defer { lock.unlock() }
        commands.append(args)
    }
    var values: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return commands
    }
}
