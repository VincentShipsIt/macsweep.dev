import Testing
import Foundation
@testable import MacSweepCore

/// Correctness coverage for LargeFilesModule after the O(files × depth) sizing
/// rewrite. The scan now sizes every directory once (folding each file into its
/// ancestors) instead of re-walking each subtree via `DiskAnalyzer.directorySize`
/// at every level. These tests prove the surfaced set and the reported sizes are
/// unchanged: folders are surfaced by their FULL subtree size (deep files
/// included), a surfaced folder swallows its children, and the size a folder
/// reports equals `DiskAnalyzer.directorySize` exactly.
final class LargeFilesModuleTests {
    private let temp: TempTestDirectory
    private let root: URL

    // Comfortably clear of filesystem block rounding on both sides of the
    // threshold, so allocation-size padding can't flip a pass/fail.
    private let threshold: Int64 = 20_000
    private let bigBytes = 50_000
    private let tinyBytes = 1_000

    init() throws {
        temp = try TempTestDirectory(prefix: "MacSweepLargeFilesTests")
        root = temp.url
    }

    private func makeDir(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ bytes: Int, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(count: bytes).write(to: url)
    }

    /// Builds the shared fixture tree:
    ///   loose.bin            large  → surfaced as a file (top-level, no folder to swallow it)
    ///   big/b1.bin           large  → big/ surfaced as a folder, b1 swallowed
    ///   heavy/sub/h1.bin     large  → heavy/ surfaced by a DEPTH-2 file, subtree swallowed
    ///   mid/m1.bin           tiny   → mid/ (and inner/) stay below threshold, surface nothing
    ///   mid/inner/i1.bin     tiny
    private func buildFixture() throws {
        try write(bigBytes, to: "loose.bin")
        try write(bigBytes, to: "big/b1.bin")
        try write(bigBytes, to: "heavy/sub/h1.bin")
        try write(tinyBytes, to: "mid/m1.bin")
        try write(tinyBytes, to: "mid/inner/i1.bin")
    }

    private func module(_ kind: LargeFilesModule.ScanKind) -> LargeFilesModule {
        var module = LargeFilesModule()
        module.threshold = threshold
        module.scanKind = kind
        module.searchPaths = [root]
        return module
    }

    private func names(_ items: [CleanupItem]) -> Set<String> {
        Set(items.map { $0.path.lastPathComponent })
    }

    @Test func bothModeSurfacesTopmostLargeFilesAndFolders() async throws {
        try buildFixture()

        let items = try await module(.both).scan()

        // loose.bin (file), big/ (folder), heavy/ (folder). The mid/ subtree is
        // under threshold and contributes nothing.
        #expect(names(items) == ["loose.bin", "big", "heavy"])

        // A surfaced folder swallows its descendants — the large child files must
        // NOT also appear (that would double-count bytes and trash the child after
        // the parent was already trashed).
        #expect(!names(items).contains("b1.bin"))
        #expect(!names(items).contains("h1.bin"))
        #expect(!names(items).contains("sub"))

        // Sorted by size, descending.
        #expect(items == items.sorted { $0.size > $1.size })

        // Types are correct.
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.path.lastPathComponent, $0) })
        #expect(byName["loose.bin"]?.type == .file)
        #expect(byName["big"]?.type == .directory)
        #expect(byName["heavy"]?.type == .directory)
    }

    @Test func surfacedFolderSizeMatchesDirectorySizeExactly() async throws {
        try buildFixture()

        let items = try await module(.both).scan()
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.path.lastPathComponent, $0) })

        // The whole point of the rewrite: the size the scan reports for a folder is
        // byte-for-byte what a full independent directorySize walk produces —
        // including the depth-2 file under heavy/sub.
        let heavySize = try await DiskAnalyzer.directorySize(at: root.appendingPathComponent("heavy"))
        let bigSize = try await DiskAnalyzer.directorySize(at: root.appendingPathComponent("big"))

        #expect(byName["heavy"]?.size == heavySize)
        #expect(byName["big"]?.size == bigSize)
        // heavy/ is sized entirely by its single deep file, so it must be > 0.
        #expect((byName["heavy"]?.size ?? 0) >= Int64(bigBytes))
    }

    @Test func foldersModeSurfacesOnlyFolders() async throws {
        try buildFixture()

        let items = try await module(.folders).scan()

        #expect(names(items) == ["big", "heavy"])
        #expect(items.allSatisfy { $0.type == .directory })
    }

    @Test func filesModeSurfacesLargeFilesAtEveryDepth() async throws {
        try buildFixture()

        let items = try await module(.files).scan()

        // With folders never surfaced, nothing gets swallowed, so every large file
        // is reported wherever it lives — including inside big/ and heavy/sub/.
        #expect(names(items) == ["loose.bin", "b1.bin", "h1.bin"])
        #expect(items.allSatisfy { $0.type == .file })
    }

    @Test func belowThresholdSubtreeSurfacesNothing() async throws {
        // Only the under-threshold mid/ subtree exists: no file and no folder
        // clears the bar, so the scan is empty — and the nested sizing (mid sizes
        // inner, inner sizes its file) must not accidentally surface anything.
        try write(tinyBytes, to: "mid/m1.bin")
        try write(tinyBytes, to: "mid/inner/i1.bin")

        let items = try await module(.both).scan()
        #expect(items.isEmpty)
    }
}
