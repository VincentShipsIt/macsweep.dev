import Darwin
import Foundation
import Testing

@testable import MacSweepCore

final class DeveloperCLILogsTests {
    let temp: TempTestDirectory
    let home: URL
    let reference = Date(timeIntervalSince1970: 1_800_000_000)
    init() throws {
        temp = try TempTestDirectory(prefix: "GcloudRetention")
        home = temp.url.resolvingSymlinksInPath()
    }
    private func log(_ name: String = "12.30.00.123456.log", age: Double = 31, size: Int = 4096) throws -> URL {
        let path = home.appendingPathComponent(".config/gcloud/logs/2026.01.01/\(name)")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: size).write(to: path)
        try FileManager.default.setAttributes(
            [.modificationDate: reference.addingTimeInterval(-age * 86_400)], ofItemAtPath: path.path)
        return path
    }
    private func module() -> DeveloperCLILogsModule {
        var module = DeveloperCLILogsModule()
        module.homeDirectory = home
        module.now = { self.reference }
        module.retention.retainedBytes = 0
        module.processSnapshot = { DevProcessSnapshot() }
        return module
    }
    private func writer(_ path: URL) -> DevProcessJob {
        DevProcessJob(
            identity: DevProcessIdentity(pid: 4321, seconds: 1, microseconds: 0, executable: "/tools/python3"),
            parentPID: 1, directory: home, arguments: ["python3"], openFiles: [path], sharedDependencies: [],
            inspectionIssue: nil)
    }
    @Test func exactLogAllowlistPreservesCredentialAndConfigurationSiblings() async throws {
        let eligible = try log()
        let unexpected = try log("credentials.db")
        let adjacent = home.appendingPathComponent(".config/gcloud/credentials.db")
        try Data("secret".utf8).write(to: adjacent)
        let config = home.appendingPathComponent(".config/gcloud/configurations")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data("account".utf8).write(to: config.appendingPathComponent("config_default"))
        let module = module()
        #expect(DeveloperCLILogsModule.isLogPath(eligible, home: home))
        let validation = SafetyChecker().validateForCleanup(eligible, moduleID: module.id, itemType: .file)
        #expect(validation.isSafe, Comment(rawValue: validation.reason ?? ""))
        let items = try await module.scan()
        try #require(items.count == 1)
        #expect(items[0].path == eligible)
        #expect(items[0].managedCleanupReceipt?.preview.contains("gcloud") == true)
        let result = try await module.clean(items: items, dryRun: false)
        #expect(result.itemsProcessed == 1)
        #expect(!FileManager.default.fileExists(atPath: eligible.path))
        #expect(FileManager.default.fileExists(atPath: unexpected.path))
        #expect(try Data(contentsOf: adjacent) == Data("secret".utf8))
        #expect(FileManager.default.fileExists(atPath: config.path))
    }
    @Test func ageBoundaryAndRetainedSizeAreConservative() async throws {
        let boundary = try log(age: 30)
        let recent = try log("12.30.01.123456.log", age: 1)
        let old = try log("12.30.02.123456.log", age: 31)
        var module = module()
        let items = try await module.scan()
        #expect(items.first { $0.path == boundary }?.managedCleanupReceipt?.isEligible == false)
        #expect(items.first { $0.path == recent }?.managedCleanupReceipt?.isEligible == false)
        #expect(items.first { $0.path == old }?.managedCleanupReceipt?.isEligible == true)
        module.retention.retainedBytes = 20_000
        #expect(try await module.scan().allSatisfy { $0.managedCleanupReceipt?.isEligible == false })
    }
    @Test func activeWriterBeforeOrAfterScanRetainsLog() async throws {
        let path = try log()
        var module = module()
        let items = try await module.scan()
        module.processSnapshot = { DevProcessSnapshot(jobs: [self.writer(path)]) }
        let active = try await module.scan()
        #expect(active[0].cleanupReviewReason?.contains("PID 4321") == true)
        #expect(try await module.clean(items: items, dryRun: false).itemsProcessed == 0)
        #expect(FileManager.default.fileExists(atPath: path.path))
    }
    @Test func changedFileAndSymlinkReplacementAreRejected() async throws {
        let path = try log()
        let module = module()
        let items = try await module.scan()
        try Data("written since preview".utf8).write(to: path)
        #expect(try await module.clean(items: items, dryRun: false).itemsProcessed == 0)
        _ = try log()
        let fresh = try await module.scan()
        let protected = home.appendingPathComponent("credentials.db")
        try Data("keep".utf8).write(to: protected)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: protected)
        #expect(try await module.clean(items: fresh, dryRun: false).itemsProcessed == 0)
        #expect(try Data(contentsOf: protected) == Data("keep".utf8))
    }
    @Test func symlinkRootAndHardlinkedCredentialFixturesAreNotScanned() async throws {
        let path = try log()
        let secret = home.appendingPathComponent("credentials.db")
        try FileManager.default.linkItem(at: path, to: secret)
        let module = module()
        #expect(try await module.scan().isEmpty)
        let saved = home.appendingPathComponent("saved")
        try FileManager.default.moveItem(at: module.root, to: saved)
        try FileManager.default.createSymbolicLink(at: module.root, withDestinationURL: saved)
        do {
            _ = try await module.scan()
            Issue.record("Symlink log root must fail")
        } catch {}
        #expect(FileManager.default.fileExists(atPath: secret.path))
    }
    @Test func dryRunAndPartialFailuresReportOnlyCompletedFiles() async throws {
        let first = try log()
        let second = try log("12.30.02.123456.log")
        var module = module()
        let items = try await module.scan()
        #expect(try await module.clean(items: items, dryRun: true).itemsProcessed == 2)
        #expect(FileManager.default.fileExists(atPath: first.path))
        module.remove = { path in
            if path == second { throw DevArtifactSafetyError("fixture failure") }
            try FileManager.default.removeItem(at: path)
        }
        let result = try await module.clean(items: items, dryRun: false)
        #expect(result.itemsProcessed == 1)
        #expect(result.bytesFreed == 4096)
        #expect(result.errors.count == 1)
        #expect(FileManager.default.fileExists(atPath: second.path))
    }
    @Test func heldLockIsVisibleAndProtectsOldLog() async throws {
        let path = try log()
        let descriptor = open(path.path, O_RDONLY)
        defer { close(descriptor) }
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let module = module()
        let items = try await module.scan()
        let item = try #require(items.first)
        #expect(item.cleanupReviewReason?.contains("locked") == true)
        #expect(try await module.clean(items: items, dryRun: false).itemsProcessed == 0)
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test func realHomeSafetyScopeAllowsOnlyExactLogsAfterUserRules() {
        let real = FileManager.default.homeDirectoryForCurrentUser
        let good = real.appendingPathComponent(".config/gcloud/logs/2026.01.01/12.30.00.123456.log")
        let bad = real.appendingPathComponent(".config/gcloud/credentials.db")
        #expect(DeveloperCLILogsModule.isLogPath(good))
        #expect(SafetyChecker().validateForCleanup(good, moduleID: "developer-cli-logs", itemType: .file).isSafe)
        #expect(!SafetyChecker().validateForCleanup(bad, moduleID: "developer-cli-logs", itemType: .file).isSafe)
        #expect(!SafetyChecker().validateForCleanup(good, moduleID: "ai-analysis", itemType: .file).isSafe)
    }
}
