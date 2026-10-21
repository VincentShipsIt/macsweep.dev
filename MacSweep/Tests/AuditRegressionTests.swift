import Foundation
import Darwin
import Testing
@testable import MacSweepCore

struct AuditRegressionTests {
    @Test func serviceWorkerDiscoveryIgnoresOrdinaryApplicationSupportFiles() async throws {
        let fixture = try TempTestDirectory(prefix: "ServiceWorkerDiscovery")
        try Data("settings".utf8).write(to: fixture.url.appending(path: "settings.dat"))
        let worker = fixture.url.appending(path: "Example App/Service Worker")
        try FileManager.default.createDirectory(at: worker, withIntermediateDirectories: true)
        try Data(count: 16_384).write(to: worker.appending(path: "cache.bin"))

        let items = try await ScanDiagnostics.collect {
            await ServiceWorkerModule().scanUnknownElectronApps(in: fixture.url)
        }

        #expect(items.count == 1)
        #expect(items.first?.path.lastPathComponent == "Service Worker")
    }

    @Test func conversationArchivesAreNeverCacheCleanupTargets() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let checker = SafetyChecker(userRules: .empty)
        for path in [".codex/archived_sessions", ".codex/archived_sessions/Cache/session.jsonl", ".codex/sessions/session.jsonl", ".claude/projects/project/session.jsonl"] {
            #expect(!checker.validateForCleanup(home.appending(path: path), moduleID: "ai-analysis").isSafe)
        }
        #expect(CacheAnalyzer.parseFastScanOutput("2048\t\(home.path)/.codex/archived_sessions").isEmpty)
        #expect(checker.validateForCleanup(home.appending(path: ".codex/log"), moduleID: "ai-analysis").isSafe)
    }

    @Test func narrowlyScopedMailAttachmentsAreAllowed() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let checker = SafetyChecker(userRules: .empty)
        for path in ["Library/Mail/V10/account/Attachments/1/invoice.pdf", "Library/Mail Downloads/invoice.pdf", "Library/Application Support/Spark Desktop/core-data/attachments/invoice.pdf"] {
            #expect(checker.validateForScan(home.appending(path: path), moduleID: "mail-attachments").isSafe)
            #expect(checker.validateForCleanup(home.appending(path: path), moduleID: "mail-attachments").isSafe)
        }
        for path in ["Library/Mail/V10/account/message.emlx", "Library/Mail/V10/account/Attachments", "Library/Application Support/Spark Desktop/core-data/messages.json", "Library/Mail Downloads/store.db"] {
            #expect(!checker.validateForCleanup(home.appending(path: path), moduleID: "mail-attachments").isSafe)
        }
    }

    @Test func directorySizesIncludeHiddenFiles() async throws {
        let fixture = try TempTestDirectory(prefix: "AuditHiddenSize")
        let path = fixture.url.appending(path: ".payload")
        try Data(repeating: 0xA5, count: 8192).write(to: path)
        let expected = try path.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]).diskSize
        #expect(try await DiskAnalyzer.directorySize(at: fixture.url) == expected)
    }

    @Test func smartCareRetainsFailures() async throws {
        let service = MacSweepHeadlessService(engine: ScanEngine(modules: [FailingModule()]))
        let result = try await service.scan(request: .init(smartCare: true))
        #expect(result.summary.errors.count == 1)
    }

    @Test func modelMisclassificationCannotRecommendConversationHistory() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let response = """
        [{"path":"\(home)/.codex/archived_sessions/Cache","regenerates_automatically":true},
         {"path":"\(home)/.codex/log","regenerates_automatically":true}]
        """
        let findings = try #require(CacheAnalyzer.parseAIFindings(response, source: "AI Analysis"))
        #expect(findings.map(\.path) == [home + "/.codex/log"])
    }

    @Test func aiCleanupUsesLiveSizeCapAndLeavesFixtureIntact() async throws {
        let fixture = try TempTestDirectory(prefix: "AICleanupCap")
        let path = fixture.url.appending(path: "cache.bin")
        try Data(repeating: 0xA5, count: 8192).write(to: path)
        let findings = [CacheFinding(path: path.path, size: "0 bytes", category: .other,
            regeneratesAutomatically: true, source: .ai)]
        let items = try await AIAnalysisModule.prepare(findings)
        let engine = ScanEngine(deletionGuard: DeletionGuard(maxTotalSize: 1))
        await #expect(throws: ScanEngineError.self) {
            _ = try await engine.clean(items: items, dryRun: false, confirmedLargeDeletion: true)
        }
        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(items.first?.size ?? 0 > 1)
    }

    @Test func hiddenBuildPatternsAreDiscoveredByActualModule() async throws {
        let fixture = try TempTestDirectory(prefix: "HiddenDevArtifacts")
        for name in ["package.json", "next.config.js", "turbo.json"] {
            try Data("{}".utf8).write(to: fixture.url.appending(path: name))
        }
        for name in [".next", ".turbo", "dist"] {
            let dir = fixture.url.appending(path: name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0xA5, count: 2_097_152).write(to: dir.appending(path: "payload.bin"))
        }
        for entry in try FileManager.default.contentsOfDirectory(at: fixture.url, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: entry.path)
        }
        var module = DevToolsModule()
        module.searchPaths = [fixture.url]
        let results = try await module.scan().filter { $0.path.path.contains(fixture.url.lastPathComponent) }
        #expect(Set(results.map { $0.path.lastPathComponent }) == [".next", ".turbo", "dist"])
    }

    @Test func filesystemFailurePreservesHealthyPartialFindings() async throws {
        let fixture = try TempTestDirectory(prefix: "PartialScan")
        let file = fixture.url.appending(path: "not-a-directory")
        try Data([1]).write(to: file)
        let item = CleanupItem(id: UUID(), path: file, size: 1, type: .file, module: "fixture", moduleName: "Fixture")
        let engine = ScanEngine(modules: [ReadFailureModule(item: item)])
        let result = await engine.scanWithDiagnostics()
        #expect(result.isPartial)
        #expect(result.items.map(\.id) == [item.id])
        #expect(result.failures.first?.message.contains("not-a-directory") == true)
    }

    @Test func trashAccountingDoesNotInferPhysicalRecoveryAndDeduplicatesTargets() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "accounting-cache")
        let parent = CleanupItem(id: UUID(), path: root, size: 4096, type: .directory, module: "dev-tools", moduleName: "Fixture")
        let child = CleanupItem(id: UUID(), path: root.appending(path: "file"), size: 2048, type: .file, module: "dev-tools", moduleName: "Fixture")
        let selected = [child, parent, parent].withoutOverlappingTargets()
        #expect(selected.count == 1)
        let result = CleanupResult(itemsProcessed: 1, bytesFreed: 4096).accounting(for: selected)
        #expect(result.accounting?.movedToTrashBytes == 4096)
        #expect(result.accounting?.permanentlyRemovedTargetBytes == 0)
        #expect(result.accounting?.volumeObservations.isEmpty == true)
        let snapshot = VolumeSpaceSnapshot(timestamp: Date(), volumeID: "fixture-volume", volumePath: "/", availableBytes: 1000, errorMessage: nil)
        let after = VolumeSpaceSnapshot(timestamp: Date(), volumeID: "fixture-volume", volumePath: "/", availableBytes: 800, errorMessage: nil)
        let observation = VolumeSpaceObservation(before: snapshot, after: after)
        #expect(observation.observedAvailableChange == -200)
        let encoded = try JSONEncoder().encode(observation)
        #expect(String(decoding: encoded, as: UTF8.self).contains("observedAvailableChange"))
    }

    @Test func emptyAndIncompleteMalwareAuditsNeverClaimClean() {
        #expect(!ScanResult(scannedAt: Date(), totalScanned: 0, findings: []).isClean)
        let partial = ScanResult(scannedAt: Date(), totalScanned: 1, findings: [], collectionErrors: ["Access denied"])
        #expect(!partial.isClean)
        #expect(!partial.isComplete)
        #expect(!partial.hasThreats)
    }

    @MainActor @Test func malwareExtensionCollectionIncludesMultipleProfiles() async throws {
        let fixture = try TempTestDirectory(prefix: "MalwareProfiles")
        for profile in ["Default", "Profile 1"] {
            let path = fixture.url.appending(path: "Google/Chrome/\(profile)/Extensions/extension-id/1.0")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: path.appending(path: "manifest.json"))
        }
        let scanner = MalwareScannerService()
        let targets = await scanner.collectBrowserExtensions(in: fixture.url)
        #expect(targets.count == 2)
        #expect(scanner.collectionErrors.isEmpty)
    }

    @Test func browserCleanupAndLargeFilesAreReachable() {
        #expect(FeatureSection.cleanup.features.contains(.browserCleanup))
        #expect(FeatureSection.files.features.contains(.largeOldFiles))
    }

    @Test func cacheDiscoveryKeepsPartialOutputAndItsFailure() async {
        let result = await CacheAnalyzer.bestEffortPipelineOutput(
            stages: [ProcessPipelineStage(executable: "/bin/sh", arguments: ["-c", "printf partial; exit 7"])], timeout: 5
        )
        #expect(result.output == "partial")
        #expect(result.error?.contains("incomplete") == true)
    }

    @Test func unavailableDockerDaemonIsAnIncompleteScan() async {
        let module = DockerModule(dockerPath: { "/bin/echo" }, commandRunner: { _, _ in
            ProcessResult(status: 1, output: "", error: "daemon unavailable")
        })
        let result = await ScanEngine(modules: [module]).scanWithDiagnostics()
        #expect(result.isPartial)
        #expect(result.failures.first?.message.contains("daemon unavailable") == true)
    }

    @Test func directorySizingNeverFollowsARootSymlink() async throws {
        let fixture = try TempTestDirectory(prefix: "SizingSymlink")
        let target = fixture.url.appending(path: "target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: 8192).write(to: target.appending(path: "payload"))
        let link = fixture.url.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(try await DiskAnalyzer.directorySize(at: link) == 0)
    }

    @Test func cloneAllocationIsOnlyAnEstimateAndUnavailableMeasurementsStayUnavailable() async throws {
        let fixture = try TempTestDirectory(prefix: "CloneAccounting")
        let original = fixture.url.appending(path: "original.bin")
        let clone = fixture.url.appending(path: "clone.bin")
        try Data(repeating: 0xA5, count: 8192).write(to: original)
        let supportsCloning = try fixture.url.resourceValues(forKeys: [.volumeSupportsFileCloningKey]).volumeSupportsFileCloning == true
        if supportsCloning {
            #expect(clonefile(original.path, clone.path, 0) == 0)
        } else {
            try FileManager.default.copyItem(at: original, to: clone)
        }
        let items = try await [original, clone].asyncCleanupItems()
        let result = CleanupResult(itemsProcessed: 2, bytesFreed: items.estimatedBytes).accounting(for: items)
        #expect(result.accounting?.movedToTrashBytes == items.estimatedBytes)
        #expect(result.accounting?.volumeObservations.isEmpty == true)
        let start = VolumeSpaceSnapshot(timestamp: Date(), volumeID: "volume", volumePath: "/", availableBytes: 1000, errorMessage: nil)
        let unavailable = VolumeSpaceSnapshot(timestamp: Date(), volumeID: nil, volumePath: "/", availableBytes: nil, errorMessage: "Offline")
        #expect(VolumeSpaceObservation(before: start, after: unavailable).observedAvailableChange == nil)
    }

    @MainActor @Test func partiallyCleanedDirectoryStaysVisibleAndHistoryRecordsFailure() async throws {
        let fixture = try TempTestDirectory(prefix: "PartialCleanupReceipt")
        let item = CleanupItem(id: UUID(), path: fixture.url, size: 8192, type: .directory, module: "system-cache", moduleName: "Fixture")
        let error = CleanupError(path: fixture.url.appending(path: "protected-child"), message: "Protected child remains")
        let result = CleanupResult(itemsProcessed: 0, bytesFreed: 4096, errors: [error])
        let model = ScanFeatureModel(cleanupOperation: { _ in result })
        model.items = [item]
        model.selectedItems = [item.id]
        _ = await model.clean([item]) { $0.localizedDescription }
        #expect(model.items.map(\.id) == [item.id])
        let store = CleanupHistoryStore(inMemory: true)
        let run = try #require(store.record(items: [item], result: result))
        #expect(run.records.first?.outcome == .failed)
        #expect(run.records.first?.errorMessage == "Protected child remains")
    }

    private struct ReadFailureModule: ScanModule {
        let item: CleanupItem
        let id = "fixture", name = "Fixture", description = "Fixture", icon = "testtube.2"
        func scan() async throws -> [CleanupItem] {
            _ = try? ScanFileSystem.contentsOfDirectory(at: item.path, includingPropertiesForKeys: nil)
            return [item]
        }
        func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
            CleanupResult(itemsProcessed: 0, bytesFreed: 0)
        }
    }

    private struct FailingModule: ScanModule {
        let id = "system-cache", name = "Failing fixture", description = "Fixture", icon = "testtube.2"
        func scan() async throws -> [CleanupItem] { throw CocoaError(.fileReadNoPermission) }
        func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
            CleanupResult(itemsProcessed: 0, bytesFreed: 0)
        }
    }
}

private extension Array where Element == URL {
    func asyncCleanupItems() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []
        for path in self {
            items.append(CleanupItem(id: UUID(), path: path, size: try await DiskAnalyzer.size(of: path),
                type: .file, module: "dev-tools", moduleName: "Fixture"))
        }
        return items
    }
}
