import Testing
import Foundation
@testable import MacSweepCore

/// Coverage for the duplicate finder. The highest-stakes behavior is the
/// two-stage hash: a partial (head/middle/tail) hash collision must NOT be
/// treated as a confirmed duplicate, because acting on a false positive trashes
/// a unique file the user never duplicated. These tests prove the confirmation
/// stage rejects a crafted partial-collision pair while still detecting a true
/// duplicate, and that `DuplicateSelector.autoSelect` keeps the higher-value
/// copy.
final class DuplicateFinderModuleTests {
    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSweepDupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - Two-stage hash confirmation

    @Test func scanDetectsTrueDuplicateButRejectsPartialCollision() async throws {
        // True duplicate: two byte-identical 2MB files. Full hash matches →
        // confirmed → autoSelect drops one → exactly 1 CleanupItem.
        let trueDupSize = 2_097_152
        try write(Data(count: trueDupSize), "real-a.bin")
        try write(Data(count: trueDupSize), "real-b.bin")

        // False positive: two 3MB files that are identical in the head [0,4096),
        // middle [size/2, size/2+4096) and tail [size-4096, size) windows the
        // partial hash samples, but differ at offset 8192 — OUTSIDE every
        // sampled window. Partial hashes collide; full hashes differ; the
        // confirmation stage must keep them apart → 0 items from this pair.
        let falseSize = 3_145_728
        try write(Data(count: falseSize), "collide-a.bin")
        var flipped = Data(count: falseSize)
        flipped[8192] = 0xFF
        try write(flipped, "collide-b.bin")

        var module = DuplicateFinderModule()
        module.searchPaths = [tempDir]

        let items = try await module.scan()
        // Only the genuine 2MB pair contributes a deletion candidate.
        #expect(items.count == 1)
        #expect(items.first?.path.lastPathComponent.hasPrefix("real-") == true)
    }

    // MARK: - DuplicateSelector keep-priority

    private func file(_ path: String, created: Date = Date()) -> DuplicateFile {
        DuplicateFile(
            id: UUID(),
            path: URL(fileURLWithPath: path),
            size: 4096,
            createdDate: created,
            modifiedDate: created
        )
    }

    private func group(_ files: [DuplicateFile]) -> DuplicateGroup {
        DuplicateGroup(id: UUID(), hash: "h", size: 4096, files: files)
    }

    @Test func autoSelectKeepsDocumentsOverDownloads() {
        let keep = file("/Users/x/Documents/photo.jpg")
        let drop = file("/Users/x/Downloads/photo.jpg")
        let selected = DuplicateSelector().autoSelect(group([drop, keep]))
        #expect(selected.count == 1)
        #expect(selected.first?.path.path == drop.path.path)
    }

    @Test func autoSelectKeepsNonTrashOverTrash() {
        let keep = file("/Users/x/Documents/doc.pdf")
        let drop = file("/Users/x/.Trash/doc.pdf")
        let selected = DuplicateSelector().autoSelect(group([drop, keep]))
        #expect(selected.count == 1)
        #expect(selected.first?.path.path == drop.path.path)
    }

    @Test func autoSelectReturnsEmptyForSingleFile() {
        let only = file("/Users/x/Documents/solo.txt")
        #expect(DuplicateSelector().autoSelect(group([only])).isEmpty)
    }
}
