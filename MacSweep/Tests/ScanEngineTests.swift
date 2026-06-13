import XCTest
@testable import MacSweepCore

final class ScanEngineTests: XCTestCase {
    actor CleanupRecorder {
        private var calls: [String: [CleanupItem]] = [:]
        private var order: [String] = []

        func record(moduleID: String, items: [CleanupItem]) {
            calls[moduleID] = items
            order.append(moduleID)
        }

        func items(for moduleID: String) -> [CleanupItem] {
            calls[moduleID] ?? []
        }

        func cleanupOrder() -> [String] {
            order
        }
    }

    struct TestModule: ScanModule {
        let id: String
        let name: String
        let description: String
        let icon: String = "testtube.2"
        let recorder: CleanupRecorder

        func scan() async throws -> [CleanupItem] { [] }

        func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
            await recorder.record(moduleID: id, items: items)
            return CleanupResult(
                itemsProcessed: items.count,
                bytesFreed: items.reduce(0) { $0 + $1.size }
            )
        }
    }

    func testCleanDispatchesItemsToOwningModules() async throws {
        let recorder = CleanupRecorder()
        let engine = ScanEngine(modules: [
            TestModule(id: "alpha", name: "Alpha", description: "Alpha", recorder: recorder),
            TestModule(id: "beta", name: "Beta", description: "Beta", recorder: recorder),
        ])

        let tmp = FileManager.default.temporaryDirectory
        let alphaItem = CleanupItem(
            id: UUID(),
            path: tmp.appendingPathComponent("alpha.tmp"),
            size: 512,
            type: .file,
            module: "alpha",
            moduleName: "Alpha"
        )
        let betaItem = CleanupItem(
            id: UUID(),
            path: tmp.appendingPathComponent("beta.tmp"),
            size: 2048,
            type: .file,
            module: "beta",
            moduleName: "Beta"
        )

        let result = try await engine.clean(items: [alphaItem, betaItem], dryRun: true)

        let alphaCalls = await recorder.items(for: "alpha")
        let betaCalls = await recorder.items(for: "beta")

        XCTAssertEqual(alphaCalls, [alphaItem])
        XCTAssertEqual(betaCalls, [betaItem])
        XCTAssertEqual(result.itemsProcessed, 2)
        XCTAssertEqual(result.bytesFreed, 2560)
    }

    func testCleanBlocksProtectedPathForStandardModule() async throws {
        let recorder = CleanupRecorder()
        let engine = ScanEngine(modules: [
            TestModule(id: "system-cache", name: "System Cache", description: "System Cache", recorder: recorder),
        ])

        let protectedItem = CleanupItem(
            id: UUID(),
            path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/family-photo.jpg"),
            size: 1024,
            type: .file,
            module: "system-cache",
            moduleName: "System Cache"
        )

        let result = try await engine.clean(items: [protectedItem], dryRun: true)

        let calls = await recorder.items(for: "system-cache")
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(result.itemsProcessed, 0)
        XCTAssertEqual(result.errors.count, 1)
    }

    func testCleanAllowsUserManagedPathForSimilarPhotos() async throws {
        let recorder = CleanupRecorder()
        let engine = ScanEngine(modules: [
            TestModule(id: "similar-photos", name: "Similar Photos", description: "Similar Photos", recorder: recorder),
        ])

        let photoItem = CleanupItem(
            id: UUID(),
            path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/similar-shot.jpg"),
            size: 4096,
            type: .file,
            module: "similar-photos",
            moduleName: "Similar to IMG_0001"
        )

        let result = try await engine.clean(items: [photoItem], dryRun: true)

        let calls = await recorder.items(for: "similar-photos")
        XCTAssertEqual(calls, [photoItem])
        XCTAssertEqual(result.itemsProcessed, 1)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testCleanBlocksUserManagedDirectoryForLargeFiles() async throws {
        let recorder = CleanupRecorder()
        let engine = ScanEngine(modules: [
            TestModule(id: "large-files", name: "Large Files", description: "Large Files", recorder: recorder),
        ])

        let projectRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/project-root")
        let projectItem = CleanupItem(
            id: UUID(),
            path: projectRoot,
            size: 5_000_000,
            type: .directory,
            module: "large-files",
            moduleName: "Folder"
        )

        let result = try await engine.clean(items: [projectItem], dryRun: true)

        let calls = await recorder.items(for: "large-files")
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(result.itemsProcessed, 0)
        XCTAssertEqual(result.errors.count, 1)
    }

    func testCleanPrioritizesTrashBeforeOtherModules() async throws {
        let recorder = CleanupRecorder()
        let engine = ScanEngine(modules: [
            TestModule(id: "system-cache", name: "System Cache", description: "System Cache", recorder: recorder),
            TestModule(id: "trash-bins", name: "Trash Bins", description: "Trash Bins", recorder: recorder),
        ])

        let tmp = FileManager.default.temporaryDirectory
        let trashItem = CleanupItem(
            id: UUID(),
            path: tmp.appendingPathComponent(".Trash/old-file"),
            size: 512,
            type: .file,
            module: "trash-bins",
            moduleName: "User Trash"
        )
        let cacheItem = CleanupItem(
            id: UUID(),
            path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/example-cache"),
            size: 1024,
            type: .directory,
            module: "system-cache",
            moduleName: "System Cache"
        )

        _ = try await engine.clean(items: [cacheItem, trashItem], dryRun: true)

        let order = await recorder.cleanupOrder()
        XCTAssertEqual(order, ["trash-bins", "system-cache"])
    }

    func testCleanThrowsWhenAggregateExceedsHardLimitOnRealDelete() async {
        let recorder = CleanupRecorder()
        let engine = ScanEngine(modules: [
            TestModule(id: "system-cache", name: "System Cache", description: "System Cache", recorder: recorder),
        ])

        let tmp = FileManager.default.temporaryDirectory
        let hugeItem = CleanupItem(
            id: UUID(),
            path: tmp.appendingPathComponent("huge.cache"),
            size: 11_000_000_000,  // > 10GB hard limit
            type: .file,
            module: "system-cache",
            moduleName: "System Cache"
        )

        do {
            _ = try await engine.clean(items: [hugeItem], dryRun: false)
            XCTFail("Expected deletionBlocked to be thrown")
        } catch let error as ScanEngineError {
            guard case .deletionBlocked = error else {
                return XCTFail("Expected .deletionBlocked, got \(error)")
            }
        } catch {
            XCTFail("Expected ScanEngineError, got \(error)")
        }

        // Nothing should have been dispatched to the module.
        let calls = await recorder.items(for: "system-cache")
        XCTAssertTrue(calls.isEmpty)
    }

    func testCleanAllowsOversizedDryRunPreview() async throws {
        let recorder = CleanupRecorder()
        let engine = ScanEngine(modules: [
            TestModule(id: "system-cache", name: "System Cache", description: "System Cache", recorder: recorder),
        ])

        let tmp = FileManager.default.temporaryDirectory
        let hugeItem = CleanupItem(
            id: UUID(),
            path: tmp.appendingPathComponent("huge.cache"),
            size: 11_000_000_000,  // > 10GB hard limit, but dry-run previews are always allowed
            type: .file,
            module: "system-cache",
            moduleName: "System Cache"
        )

        let result = try await engine.clean(items: [hugeItem], dryRun: true)
        XCTAssertEqual(result.itemsProcessed, 1)
        let calls = await recorder.items(for: "system-cache")
        XCTAssertEqual(calls, [hugeItem])
    }
}
