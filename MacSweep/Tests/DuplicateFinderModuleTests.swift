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
    private let temp: TempTestDirectory
    private let tempDir: URL

    init() throws {
        temp = try TempTestDirectory(prefix: "MacSweepDupTests")
        tempDir = temp.url
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

    // MARK: - Parallel dispatch across size-groups

    @Test func scanFindsEveryDuplicateGroupWhenHashedConcurrently() async throws {
        // Several independent duplicate sets of DISTINCT sizes, so each lands in its
        // own size-group and the groups hash concurrently through the bounded task
        // group. The result must still be complete and correct — parallel dispatch
        // only reorders work, it must not drop or invent duplicates.

        // Pair A: two identical 2MB files (large → partial+full confirmation path).
        try write(Data(count: 2_097_152), "a1.bin")
        try write(Data(count: 2_097_152), "a2.bin")

        // Pair B: two identical 512KB files (small → full-hash path).
        try write(Data(count: 524_288), "b1.bin")
        try write(Data(count: 524_288), "b2.bin")

        // Trio C: three identical 1.5MB files → keep one, two are deletable.
        try write(Data(count: 1_572_864), "c1.bin")
        try write(Data(count: 1_572_864), "c2.bin")
        try write(Data(count: 1_572_864), "c3.bin")

        // Unique files at sizes that match nothing else → no false positives.
        try write(Data(count: 700_003), "u1.bin")
        try write(Data(count: 900_007), "u2.bin")

        var module = DuplicateFinderModule()
        module.searchPaths = [tempDir]

        let items = try await module.scan()

        // 1 (pair A) + 1 (pair B) + 2 (trio C) = 4 deletion candidates.
        #expect(items.count == 4)
        #expect(items.allSatisfy { $0.module == "duplicates" })
        // Every surfaced duplicate is one of the intended dupes, never a unique file.
        let surfaced = Set(items.map { $0.path.lastPathComponent })
        #expect(surfaced.isDisjoint(with: ["u1.bin", "u2.bin"]))
    }

    @Test func reviewGroupsIncludeKeeperAndEveryConfirmedCopy() async throws {
        try write(Data(count: 16_384), "Documents-original.bin")
        try write(Data(count: 16_384), "Downloads-copy.bin")

        var module = DuplicateFinderModule()
        module.searchPaths = [tempDir]

        let groups = try await module.scanReviewGroups()
        let group = try #require(groups.first)

        #expect(groups.count == 1)
        #expect(group.items.count == 2)
        #expect(group.items.contains { $0.id == group.suggestedKeeperID })
        #expect(group.suggestedCleanupItems.count == 1)
        #expect(group.cleanupIDs(keeping: group.suggestedKeeperID) == group.suggestedCleanupIDs)
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

    @Test func changingKeeperSelectsEveryOtherItemAndNeverTheKeeper() {
        let first = CleanupItem(
            id: UUID(),
            path: URL(fileURLWithPath: "/tmp/first.bin"),
            size: 100,
            type: .file,
            module: "duplicates",
            moduleName: "Group"
        )
        let second = CleanupItem(
            id: UUID(),
            path: URL(fileURLWithPath: "/tmp/second.bin"),
            size: 100,
            type: .file,
            module: "duplicates",
            moduleName: "Group"
        )
        let third = CleanupItem(
            id: UUID(),
            path: URL(fileURLWithPath: "/tmp/third.bin"),
            size: 100,
            type: .file,
            module: "duplicates",
            moduleName: "Group"
        )
        let reviewGroup = FileReviewGroup(
            id: UUID(),
            title: "Group",
            items: [first, second, third],
            suggestedKeeperID: first.id,
            suggestionReason: "Test"
        )

        #expect(reviewGroup.cleanupIDs(keeping: second.id) == [first.id, third.id])
        #expect(!reviewGroup.cleanupIDs(keeping: second.id).contains(second.id))
        #expect(reviewGroup.cleanupIDs(keeping: UUID()).isEmpty)
        #expect(reviewGroup.retainingItems(withIDs: [first.id, second.id])?.items.count == 2)
        #expect(reviewGroup.retainingItems(withIDs: [second.id]) == nil)
    }
}
