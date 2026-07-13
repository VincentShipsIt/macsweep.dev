import Foundation
import Testing
@testable import MacSweepCore

final class ScanCacheDirectoryTests {
    private struct FixtureModule: ScanModule {
        let id = "fixture-cache"
        let name = "Fixture Cache"
        let description = "Test fixture"
        let icon = "shippingbox"

        func scan() async throws -> [CleanupItem] { [] }

        func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
            CleanupResult(itemsProcessed: 0, bytesFreed: 0)
        }
    }

    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSweepCacheMetadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @Test func scannedCacheCarriesItsModificationDateForReviewUI() async throws {
        try Data("fixture".utf8).write(to: root.appendingPathComponent("cache.bin"))
        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: expected],
            ofItemAtPath: root.path
        )

        let item = await FixtureModule().scanCacheDirectory(
            at: root,
            moduleName: "Fixture Cache"
        )

        let lastModified = try #require(item?.lastModified)
        #expect(abs(lastModified.timeIntervalSince(expected)) < 1)
    }
}
