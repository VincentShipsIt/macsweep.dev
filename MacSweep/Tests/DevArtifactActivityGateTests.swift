import Darwin
import Foundation
import Testing

@testable import MacSweepCore

final class DevArtifactActivityGateTests {
    let temp: TempTestDirectory
    let root: URL

    init() throws {
        temp = try TempTestDirectory(prefix: "DevSafety")
        root = temp.url.resolvingSymlinksInPath()
    }

    @discardableResult
    private func git(_ args: [String]) async throws -> ProcessResult {
        let result = await GitArtifactScanner.run(["git", "-C", root.path] + args)
        try #require(result.didSucceed, Comment(rawValue: result.error))
        return result
    }

    private func repository() async throws {
        try await git(["init", "-q"])
        try Data("{}".utf8).write(to: root.appendingPathComponent("package.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("tsconfig.json"))
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("turbo.json"))
        try Data("node_modules/\nbuild/\ndist/\n.next/\n.turbo/\n*.tsbuildinfo\n".utf8)
            .write(to: root.appendingPathComponent(".gitignore"))
        try await git(["add", "package.json", "tsconfig.json", "turbo.json", ".gitignore"])
    }

    @discardableResult
    private func artifact(_ name: String = "node_modules") throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: url.appendingPathComponent("generated.bin"))
        return url
    }

    private func module(
        snapshot: @escaping @Sendable () async throws -> DevProcessSnapshot = { DevProcessSnapshot() },
        ledger: SafetyRemovalLedger = SafetyRemovalLedger()
    ) -> DevToolsModule {
        var module = DevToolsModule()
        module.searchPaths = [root]
        module.minimumDirectorySize = 0
        module.includesSystemCaches = false
        module.safety.processSnapshot = snapshot
        module.remove = { ledger.record($0) }
        return module
    }

    private func item(_ module: DevToolsModule, named name: String = "node_modules") async throws -> CleanupItem {
        let items = try await module.scan()
        return try #require(items.first { $0.path.lastPathComponent == name })
    }

    private func job(
        pid: pid_t = 424242, executable: String = "/tools/python3", directory: URL? = nil,
        parent: pid_t = 1, openFiles: [URL] = [], shared: [URL] = []
    ) -> DevProcessJob {
        DevProcessJob(
            identity: DevProcessIdentity(pid: pid, seconds: 123, microseconds: 4, executable: executable),
            parentPID: parent, directory: directory ?? root, arguments: [executable, "import-data.py"],
            openFiles: openFiles, sharedDependencies: shared, inspectionIssue: nil)
    }

    @Test func recentIdleProjectIsEligibleAndCarriesIdentity() async throws {
        try await repository()
        try artifact()
        let module = module()
        let selected = try await item(module)
        #expect(selected.devArtifactReceipt?.isEligible == true)
        #expect(selected.devArtifactReceipt?.identity != nil)
        #expect(selected.cleanupReviewReason == nil)
        let result = try await module.clean(items: [selected], dryRun: false)
        #expect(result.itemsProcessed == 1)
        #expect(result.errors.isEmpty)
    }

    @Test func oldTimestampsCannotAuthorizeAnActiveProject() async throws {
        try await repository()
        let target = try artifact()
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: root.appendingPathComponent("package.json").path)
        let active = job()
        let module = module(snapshot: { DevProcessSnapshot(jobs: [active]) })
        let selected = try await item(module)
        #expect(selected.devArtifactReceipt?.isEligible == false)
        #expect(selected.cleanupReviewReason?.contains("PID 424242") == true)
        let result = try await module.clean(items: [selected], dryRun: false)
        #expect(result.itemsProcessed == 0)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func jobStartingAfterScanBlocksMutation() async throws {
        try await repository()
        try artifact()
        let state = ActivitySnapshotSource()
        let ledger = SafetyRemovalLedger()
        let module = module(snapshot: { await state.get() }, ledger: ledger)
        let selected = try await item(module)
        try #require(selected.devArtifactReceipt?.isEligible == true)
        await state.set(DevProcessSnapshot(jobs: [job()]))
        let result = try await module.clean(items: [selected], dryRun: false)
        #expect(result.itemsProcessed == 0)
        #expect(result.errors.first?.message.contains("PID 424242") == true)
        #expect(ledger.paths.isEmpty)
    }

    @Test func changedIdentityOrSymlinkRetainsReplacement() async throws {
        try await repository()
        let target = try artifact()
        let ledger = SafetyRemovalLedger()
        let module = module(ledger: ledger)
        let selected = try await item(module)
        try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("original"))
        try artifact()
        let replacement = try await module.clean(items: [selected], dryRun: false)
        #expect(replacement.itemsProcessed == 0)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(
            at: target, withDestinationURL: root.appendingPathComponent("original"))
        let symlink = try await module.clean(items: [selected], dryRun: false)
        #expect(symlink.itemsProcessed == 0)
        #expect(ledger.paths.isEmpty)
    }

    @Test func trackedContentAddedAfterScanIsRetained() async throws {
        try await repository()
        let target = try artifact()
        let ledger = SafetyRemovalLedger()
        let module = module(ledger: ledger)
        let selected = try await item(module)
        try Data("user source".utf8).write(to: target.appendingPathComponent("user.ts"))
        try await git(["add", "-f", "node_modules/user.ts"])
        let result = try await module.clean(items: [selected], dryRun: false)
        #expect(result.itemsProcessed == 0)
        #expect(ledger.paths.isEmpty)
    }

    @Test(arguments: [
        "fixtures/example.bin", "src/code.ts", "tsconfig.build.json", "package-lock.json", "bun.lock", "notes.txt",
        "user.ts", "source.js"
    ])
    func ignoredGenericOutputDoesNotAuthorizeUserContent(_ filename: String) async throws {
        try await repository()
        let target = try artifact("dist")
        let file = target.appendingPathComponent(filename)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user content".utf8).write(to: file)
        let selected = try await item(module(), named: "dist")
        #expect(selected.devArtifactReceipt?.isEligible == false)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func nameAloneAndTrackedGeneratedFilesAreInsufficient() async throws {
        try await repository()
        try artifact("dist")
        try Data("node_modules/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        let module = module()
        let unignored = try await item(module, named: "dist")
        #expect(unignored.devArtifactReceipt?.isEligible == false)
        try await git(["add", "-f", "dist/generated.bin"])
        let tracked = try await item(module, named: "dist")
        #expect(tracked.devArtifactReceipt?.isEligible == false)
    }

    @Test func smallBuildInfoIsDiscoveredAndConfigurationAndTrackedDataSurvive() async throws {
        try await repository()
        let info = root.appendingPathComponent("tsconfig.tsbuildinfo")
        try Data(#"{"version":"5.9.3","fileNames":["src/index.ts"],"fileInfos":["hash"]}"#.utf8).write(to: info)
        let module = module()
        let selected = try await item(module, named: "tsconfig.tsbuildinfo")
        #expect(selected.type == .file)
        #expect(selected.size < 1_048_576)
        #expect(selected.devArtifactReceipt?.isEligible == true)
        let names = Set(try await module.scan().map { $0.path.lastPathComponent })
        #expect(!names.contains("tsconfig.json"))
        #expect(!names.contains("package.json"))
        try await git(["add", "-f", "tsconfig.tsbuildinfo"])
        let protected = try await item(module, named: "tsconfig.tsbuildinfo")
        #expect(protected.devArtifactReceipt?.isEligible == false)
    }

    @Test func malformedBuildInfoAndMissingGitEvidenceAreRetained() async throws {
        try await repository()
        let info = root.appendingPathComponent("custom.tsbuildinfo")
        try Data("user notes".utf8).write(to: info)
        let module = module()
        #expect(try await item(module, named: "custom.tsbuildinfo").devArtifactReceipt?.isEligible == false)
        try artifact()
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
        #expect(try await item(module).devArtifactReceipt?.isEligible == false)
    }

    @Test func actualScannerIncludesHiddenRootsAndPrunesDependenciesAndMetadata() async throws {
        try await repository()
        let roots = GitArtifactScanner.worktreeRoots(in: root)
        for worktrees in roots {
            let project = worktrees.appendingPathComponent(".hidden/project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            for name in ["package.json", "turbo.json"] {
                try Data("{}".utf8).write(to: project.appendingPathComponent(name))
            }
            for name in [".next", ".turbo"] {
                let output = project.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try Data([1]).write(to: output.appendingPathComponent("generated.bin"))
            }
        }
        let nested = try artifact().appendingPathComponent("nested")
        try FileManager.default.createDirectory(
            at: nested.appendingPathComponent(".turbo"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: nested.appendingPathComponent("turbo.json"))
        var module = module()
        module.homeDirectory = root
        let results = try await module.scan()
        for worktrees in roots {
            #expect(
                results.contains {
                    $0.path.standardizedFileURL.path
                        == worktrees.appendingPathComponent(".hidden/project/.next").standardizedFileURL.path
                })
            #expect(
                results.contains {
                    $0.path.standardizedFileURL.path
                        == worktrees.appendingPathComponent(".hidden/project/.turbo").standardizedFileURL.path
                })
        }
        #expect(!results.contains { $0.path.path.contains("node_modules/nested") })
        #expect(!results.contains { $0.path.path.contains("/.git/") })
    }

    @Test func retainedJobsProtectSharedDependenciesAndOpenFiles() async throws {
        try await repository()
        let target = try artifact()
        let other = root.appendingPathComponent("other-project")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: other.appendingPathComponent("package.json"))
        try FileManager.default.createSymbolicLink(
            at: other.appendingPathComponent("node_modules"), withDestinationURL: target)
        let dependencies = try DevArtifactContent.sharedDependencyTargets(from: other)
        #expect(dependencies.contains { $0.path == target.path })
        let sharedJob = job(directory: other, shared: dependencies)
        let selected = try await item(module(snapshot: { DevProcessSnapshot(jobs: [sharedJob]) }))
        #expect(selected.devArtifactReceipt?.isEligible == false)
        let openJob = job(
            directory: URL(fileURLWithPath: "/"), openFiles: [target.appendingPathComponent("generated.bin")])
        #expect(DevProcessSnapshot(jobs: [openJob]).blockers(target: target, project: root).count == 1)
    }

}

extension DevArtifactActivityGateTests {
    @Test func changedContentsAndIgnoreRulesRequireRescanning() async throws {
        try await repository()
        let target = try artifact()
        let ledger = SafetyRemovalLedger()
        let module = module(ledger: ledger)
        let selected = try await item(module)
        try #require(selected.devArtifactReceipt?.isEligible == true)
        try Data("new content".utf8).write(to: target.appendingPathComponent("new.bin"))
        let changed = try await module.clean(items: [selected], dryRun: false)
        #expect(changed.itemsProcessed == 0)
        #expect(changed.errors.first?.message.contains("changed since scanning") == true)
        let rescanned = try await item(module)
        try Data("".utf8).write(to: root.appendingPathComponent(".gitignore"))
        let unignored = try await module.clean(items: [rescanned], dryRun: false)
        #expect(unignored.itemsProcessed == 0)
        #expect(ledger.paths.isEmpty)
    }

    @Test func lateContentChangesDuringActivityCheckAreRetained() async throws {
        try await repository()
        let target = try artifact()
        let ledger = SafetyRemovalLedger()
        let module = module(ledger: ledger)
        let selected = try await item(module)
        var changing = module
        changing.safety.processSnapshot = {
            try Data("late user content".utf8).write(to: target.appendingPathComponent("late.bin"))
            return DevProcessSnapshot()
        }
        let result = try await changing.clean(items: [selected], dryRun: false)
        #expect(result.itemsProcessed == 0)
        #expect(ledger.paths.isEmpty)
    }

    @Test func lateIndexChangesCannotTurnTrackedFilesIntoCleanupCandidates() async throws {
        try await repository()
        try artifact()
        let ledger = SafetyRemovalLedger()
        var module = module(ledger: ledger)
        let selected = try await item(module)
        let directory = root
        module.safety.processSnapshot = {
            let added = try await ProcessRunner.run(
                executable: "/usr/bin/git",
                arguments: ["-C", directory.path, "add", "-f", "node_modules/generated.bin"])
            guard added.didSucceed else { throw DevArtifactSafetyError(added.error) }
            return DevProcessSnapshot()
        }
        let result = try await module.clean(items: [selected], dryRun: false)
        #expect(result.itemsProcessed == 0)
        #expect(result.errors.first?.message.contains("Git index or ignore evidence changed") == true)
        #expect(ledger.paths.isEmpty)
    }

    @Test func customTypeScriptConfigurationAndCanonicalProjectGrouping() async throws {
        try await repository()
        try FileManager.default.removeItem(at: root.appendingPathComponent("package.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("tsconfig.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("tsconfig.build.json"))
        try Data(#"{"version":"5.9.3","fileNames":["a.ts"],"fileInfos":["hash"]}"#.utf8)
            .write(to: root.appendingPathComponent("custom.tsbuildinfo"))
        let results = try await module().scan()
        let info = try #require(results.first { $0.path.lastPathComponent == "custom.tsbuildinfo" })
        #expect(info.devArtifactReceipt?.isEligible == true)
        let projects = ProjectScanner.projects(from: results)
        #expect(projects.count == 1)
        #expect(projects.first?.artifactPaths == [info.path])
    }

    @Test func persistentDeveloperDataAndForgedFindingsCannotBeRemoved() async throws {
        let library = root.appendingPathComponent("Library")
        let archive = library.appendingPathComponent("Developer/Xcode/Archives")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        var module = module()
        module.safety.libraryDirectory = library
        let receipt = await module.safety.assess(archive)
        #expect(!receipt.isEligible)
        #expect(receipt.reason.contains("owning developer tool"))
        try await repository()
        let target = try artifact()
        let forged = CleanupItem(
            id: UUID(), path: target, size: 4096, type: .directory,
            module: "dev-tools", moduleName: "node_modules")
        let result = try await module.clean(items: [forged], dryRun: false)
        #expect(result.itemsProcessed == 0)
        #expect(result.errors.first?.message.contains("verified artifact scan") == true)
    }

    @Test func nestedCachesUseRepositoryActivityWhenProjectMarkersAreAbsent() async throws {
        try await repository()
        for name in ["package.json", "tsconfig.json", "turbo.json"] {
            try FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
        try Data("__pycache__/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        let target = try artifact("src/pkg/__pycache__")
        let active = job()
        let selected = try await item(module(snapshot: { DevProcessSnapshot(jobs: [active]) }), named: "__pycache__")
        #expect(selected.devArtifactReceipt?.isEligible == false)
        #expect(selected.devArtifactReceipt?.blockers.first?.identity == active.identity)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func inspectionFailureCannotBecomePermissionToClean() async throws {
        try await repository()
        try artifact()
        let selected = try await item(module(snapshot: { DevProcessSnapshot(issues: ["coverage unavailable"]) }))
        #expect(selected.devArtifactReceipt?.isEligible == false)
        #expect(selected.cleanupReviewReason?.contains("coverage unavailable") == true)
    }
}

actor ActivitySnapshotSource {
    private var value = DevProcessSnapshot()
    func get() -> DevProcessSnapshot { value }
    func set(_ newValue: DevProcessSnapshot) { value = newValue }
}

final class SafetyRemovalLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    var paths: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    func record(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(url)
    }
}
