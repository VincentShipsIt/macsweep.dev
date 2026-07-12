import Foundation
import Testing
@testable import MacSweepCore

final class CleanupHistoryStoreTests {
    private struct TestModule: ScanModule {
        let id = "system-cache"
        let name = "System Cache"
        let description = "Test cleanup module"
        let icon = "testtube.2"

        func scan() async throws -> [CleanupItem] { [] }

        func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
            CleanupResult(
                itemsProcessed: items.count,
                bytesFreed: items.reduce(0) { $0 + $1.size }
            )
        }
    }

    private let suiteName: String
    private let defaults: UserDefaults

    init() throws {
        suiteName = "MacSweepCleanupHistoryTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func store() -> CleanupHistoryStore {
        CleanupHistoryStore(defaults: defaults)
    }

    private func item(
        path: String = "/tmp/example.cache",
        module: String = "dev-tools",
        moduleName: String = "Developer Cache",
        size: Int64 = 4096
    ) -> CleanupItem {
        CleanupItem(
            id: UUID(),
            path: URL(fileURLWithPath: path),
            size: size,
            type: .file,
            module: module,
            moduleName: moduleName
        )
    }

    @Test func recordsCompletedAndFailedItemsWithRecoveryDetails() throws {
        let store = store()
        let completed = item(path: "/tmp/completed.cache", size: 4096)
        let failed = item(path: "/tmp/failed.cache", module: "system-cache", size: 2048)
        let result = CleanupResult(
            itemsProcessed: 1,
            bytesFreed: completed.size,
            errors: [CleanupError(path: failed.path, message: "Permission denied")]
        )

        let run = try #require(store.record(items: [completed, failed], result: result))

        #expect(run.records.count == 2)
        #expect(run.records[0].originalPath == completed.path.path)
        #expect(run.records[0].action == .moveToTrash)
        #expect(run.records[0].outcome == .completed)
        #expect(run.records[0].bytes == 4096)
        #expect(run.records[1].action == .deletePermanently)
        #expect(run.records[1].outcome == .failed)
        #expect(run.records[1].errorMessage == "Permission denied")
        #expect(run.containsTrashRecovery)
        #expect(store.history == [run])
    }

    @Test func recordsOverallCleanupFailureForEverySelectedItem() throws {
        let store = store()
        let selected = [item(), item(path: "/tmp/other.cache")]
        let error = ScanEngineError.deletionBlocked(reason: "Cleanup exceeds the deletion cap")

        let run = try #require(store.recordFailure(items: selected, error: error))

        #expect(run.completedCount == 0)
        #expect(run.failedCount == 2)
        #expect(run.records.allSatisfy { $0.errorMessage == "Cleanup exceeds the deletion cap" })
    }

    @Test func classifiesCloudDownloadsAndToolActionsFactually() {
        let cloudDownload = item(
            module: "cloud-cleanup",
            moduleName: "iCloud Local Copy"
        )
        let docker = CleanupItem(
            id: UUID(),
            action: .docker(.pruneImages),
            size: 8192
        )

        #expect(CleanupHistoryAction.action(for: cloudDownload) == .removeLocalDownload)
        #expect(CleanupHistoryAction.action(for: docker) == .runToolCleanup)
    }

    @Test func ignoresEmptyAttempts() {
        let store = store()

        #expect(store.record(items: [], result: CleanupResult(itemsProcessed: 0, bytesFreed: 0)) == nil)
        #expect(store.history.isEmpty)
    }

    @Test func scanEngineRecordsRealAttemptsButNotDryRuns() async throws {
        let store = store()
        let engine = ScanEngine(modules: [TestModule()], cleanupHistoryStore: store)
        let protectedItem = item(
            path: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures/important-photo.jpg")
                .path,
            module: "system-cache",
            moduleName: "System Cache"
        )

        _ = try await engine.clean(items: [protectedItem], dryRun: true)
        #expect(store.history.isEmpty)

        let result = try await engine.clean(items: [protectedItem], dryRun: false)
        let run = try #require(store.history.last)

        #expect(result.errors.count == 1)
        #expect(run.failedCount == 1)
        #expect(run.records[0].errorMessage?.hasPrefix("Safety check failed:") == true)
    }
}
