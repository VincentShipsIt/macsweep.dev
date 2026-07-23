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
        let contentModificationDate = try #require(item?.contentModificationDate)
        #expect(abs(contentModificationDate.timeIntervalSince(expected)) < 1)
    }

    // MARK: - threshold (ServiceWorker >1024/>10240, Network >1024, Docker >0)

    /// The `threshold` is a STRICT exclusive lower bound (`size > threshold`).
    /// A directory whose measured size equals the threshold is excluded; one
    /// byte under it is included. This is what lets each migrated `> N` site pass
    /// its literal `N` verbatim.
    @Test func thresholdIsAStrictExclusiveLowerBound() async throws {
        try Data(repeating: 0, count: 4096).write(to: root.appendingPathComponent("cache.bin"))
        let module = FixtureModule()

        // Measure the directory's actual size through the default (threshold 0).
        let baseline = try #require(
            await module.scanCacheDirectory(at: root, moduleName: "Fixture Cache")
        )
        let size = baseline.size
        #expect(size > 0)

        // size == threshold → excluded (strict `>`).
        let atSize = await module.scanCacheDirectory(
            at: root, moduleName: "Fixture Cache", threshold: size
        )
        #expect(atSize == nil)

        // size == threshold + 1 → included. Covers CloudCleanup's inclusive
        // `size >= minimumFileSize` bound, mapped to `threshold: minimum - 1`.
        let belowSize = try #require(
            await module.scanCacheDirectory(at: root, moduleName: "Fixture Cache", threshold: size - 1)
        )
        #expect(belowSize.size == size)
    }

    // MARK: - safetyCheck (CloudCleanup validateForScan gate)

    /// The optional `safetyCheck` gate skips a directory that would otherwise
    /// qualify, mirroring CloudCleanupModule's `validateForScan` defense-in-depth.
    @Test func safetyCheckRejectingPathSkipsQualifyingDirectory() async throws {
        try Data(repeating: 0, count: 4096).write(to: root.appendingPathComponent("cache.bin"))
        let module = FixtureModule()

        let rejected = await module.scanCacheDirectory(
            at: root, moduleName: "Fixture Cache", safetyCheck: { _ in false }
        )
        #expect(rejected == nil)

        let accepted = try #require(
            await module.scanCacheDirectory(
                at: root, moduleName: "Fixture Cache", safetyCheck: { _ in true }
            )
        )
        #expect(accepted.size > 0)
    }

    /// `safetyCheck` receives the exact URL under evaluation, so a gate keyed on
    /// path (as CloudCleanupModule's is) sees the real cache root.
    @Test func safetyCheckReceivesTheScannedURL() async throws {
        try Data(repeating: 0, count: 4096).write(to: root.appendingPathComponent("cache.bin"))
        let seen = SeenPath()
        let scannedRoot = root

        _ = await FixtureModule().scanCacheDirectory(
            at: scannedRoot,
            moduleName: "Fixture Cache",
            safetyCheck: { url in
                seen.record(url)
                return true
            }
        )

        #expect(seen.value?.path == scannedRoot.path)
    }
}

/// Minimal thread-safe box so the `@Sendable` safetyCheck closure can report the
/// URL it was handed back to the test.
private final class SeenPath: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?

    func record(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        stored = url
    }

    var value: URL? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
