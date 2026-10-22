import Darwin
import Foundation
import Testing

@testable import MacSweepCore

final class PackageManagerModuleTests {
    let temp: TempTestDirectory
    let home: URL
    init() throws {
        temp = try TempTestDirectory(prefix: "PackageSafety")
        home = temp.url.resolvingSymlinksInPath()
    }

    private func cache(_ relative: String = ".npm/_cacache") throws -> URL {
        let path = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: path.appendingPathComponent("cached.bin"))
        return path
    }

    private func module() -> PackageManagerModule {
        var module = PackageManagerModule()
        module.homeDirectory = home
        module.processSnapshot = { DevProcessSnapshot() }
        return module
    }

    private func job(path: URL, shared: [URL] = [], name: String = "python3") -> DevProcessJob {
        DevProcessJob(
            identity: DevProcessIdentity(pid: 4242, seconds: 1, microseconds: 0, executable: "/tools/\(name)"),
            parentPID: 1, directory: home, arguments: [name], openFiles: [path], sharedDependencies: shared,
            inspectionIssue: nil)
    }

    @Test func cleanTrashesOnlyScannedCacheAndPreservesInstalledTools() async throws {
        let path = try cache()
        let installed = try cache(".bun/install/global")
        let module = module()
        let items = try await module.scan()
        #expect(items.count == 1)
        #expect(items[0].managedCleanupReceipt?.isEligible == true)
        let result = try await module.clean(items: items, dryRun: false)
        #expect(result.errors.isEmpty)
        #expect(result.itemsProcessed == 1)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(FileManager.default.fileExists(atPath: installed.path))
    }

    @Test func fabricatedAndMissingTargetsAreRejected() async throws {
        let path = try cache()
        let module = module()
        let forged = CleanupItem(
            id: UUID(), path: path, size: 4096, type: .directory, module: module.id, moduleName: "npm")
        let result = try await module.clean(items: [forged], dryRun: false)
        #expect(result.itemsProcessed == 0)
        #expect(result.errors.count == 1)
        let items = try await module.scan()
        try FileManager.default.removeItem(at: path)
        let missing = try await module.clean(items: items, dryRun: false)
        #expect(missing.itemsProcessed == 0)
        #expect(missing.errors.count == 1)
    }

    @Test func dryRunDoesNotDeleteAndRevalidatesActivity() async throws {
        let path = try cache()
        let module = module()
        let items = try await module.scan()
        let result = try await module.clean(items: items, dryRun: true)
        #expect(result.itemsProcessed == 1)
        #expect(result.bytesFreed > 0)
        #expect(FileManager.default.fileExists(atPath: path.path))
        var active = module
        active.processSnapshot = { DevProcessSnapshot(jobs: [self.job(path: path)]) }
        let blocked = try await active.clean(items: items, dryRun: true)
        #expect(blocked.itemsProcessed == 0)
    }

    @Test func sharedDependenciesAndManagerWithoutOpenFilesProtectCache() async throws {
        let path = try cache()
        var module = module()
        let sharedJob = DevProcessJob(
            identity: DevProcessIdentity(pid: 4242, seconds: 1, microseconds: 0, executable: "/tools/python3"),
            parentPID: 1, directory: home, arguments: ["python3"], openFiles: [], sharedDependencies: [path],
            inspectionIssue: nil)
        module.processSnapshot = { DevProcessSnapshot(jobs: [sharedJob]) }
        let shared = try await module.scan()
        #expect(shared[0].cleanupReviewReason?.contains("PID 4242") == true)
        module.processSnapshot = { DevProcessSnapshot(jobs: [self.job(path: self.home, name: "npm")]) }
        let active = try await module.scan()
        #expect(active[0].managedCleanupReceipt?.isEligible == false)
    }

    @Test func changedContentsAndRootReplacementAreRetained() async throws {
        let path = try cache()
        let module = module()
        let items = try await module.scan()
        try Data("changed".utf8).write(to: path.appendingPathComponent("cached.bin"))
        #expect(try await module.clean(items: items, dryRun: false).itemsProcessed == 0)
        let fresh = try await module.scan()
        try FileManager.default.moveItem(at: path, to: home.appendingPathComponent("saved"))
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: home.appendingPathComponent("saved"))
        #expect(try await module.clean(items: fresh, dryRun: false).itemsProcessed == 0)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("saved/cached.bin").path))
    }

    @Test func liveLockAndIncompleteInspectionFailClosed() async throws {
        let path = try cache()
        let descriptor = open(path.appendingPathComponent("cached.bin").path, O_RDONLY)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        var module = module()
        let locked = try await module.scan()
        #expect(locked[0].cleanupReviewReason?.contains("locked") == true)
        _ = flock(descriptor, LOCK_UN)
        module.processSnapshot = { DevProcessSnapshot(issues: ["incomplete"]) }
        let unknown = try await module.scan()
        #expect(unknown[0].managedCleanupReceipt?.isEligible == false)
    }

    @Test func externalCacheLinksRetainDependencyTarget() async throws {
        let path = try cache()
        let dependency = home.appendingPathComponent("installed-runtime")
        try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
        try Data("keep runtime".utf8).write(to: dependency.appendingPathComponent("runtime"))
        try FileManager.default.createSymbolicLink(
            at: path.appendingPathComponent("dependency"), withDestinationURL: dependency)
        let module = module()
        let items = try await module.scan()
        #expect(items.first?.managedCleanupReceipt?.isEligible == false)
        #expect(try await module.clean(items: items, dryRun: false).itemsProcessed == 0)
        #expect(FileManager.default.fileExists(atPath: dependency.appendingPathComponent("runtime").path))
    }

    @Test func otherModulesCannotBypassPackageOwnership() {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/uv")
        for owner in ["ai-analysis", "system-cache"] {
            #expect(!SafetyChecker().validateForCleanup(path, moduleID: owner, itemType: .directory).isSafe)
        }
    }
}
