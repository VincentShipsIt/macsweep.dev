import Testing
import Foundation
@testable import MacSweepCore

/// Coverage for DiskAnalyzer.buildDiskTree after the fan-out rewrite. buildNode
/// now sizes plain files inline and only spawns (bounded) tasks for real
/// subdirectories. These tests prove the tree it produces is unchanged: file and
/// directory children are both present with correct sizes, a directory's size is
/// the exact sum of its subtree (equal to a flat `directorySize` walk), a
/// max-depth directory is summarized without children, and a symlink is treated
/// as a leaf rather than recursed into.
final class DiskAnalyzerTests {
    private let temp: TempTestDirectory
    private let root: URL

    init() throws {
        temp = try TempTestDirectory(prefix: "MacSweepDiskAnalyzerTests")
        root = temp.url
    }

    private func write(_ bytes: Int, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(count: bytes).write(to: url)
    }

    private func child(_ node: DiskNode, _ name: String) -> DiskNode? {
        node.children.first { $0.name == name }
    }

    @Test func treeMixesInlineFilesAndDirectoriesWithCorrectSizes() async throws {
        // root/f1.bin, root/a/a1.bin, root/a/b/b1.bin
        try write(1_000, to: "f1.bin")
        try write(2_000, to: "a/a1.bin")
        try write(4_000, to: "a/b/b1.bin")

        let tree = try await DiskAnalyzer.buildDiskTree(at: root, maxDepth: 3)

        // Root has an inline file child and a directory child.
        let f1 = child(tree, "f1.bin")
        let a = child(tree, "a")
        #expect(f1?.isDirectory == false)
        #expect(a?.isDirectory == true)

        // The directory's size is the exact sum of its whole subtree.
        let flat = try await DiskAnalyzer.directorySize(at: root)
        #expect(tree.size == flat)
        #expect(tree.size == (f1?.size ?? 0) + (a?.size ?? 0))

        // Nested directory sizes roll up correctly.
        let a1 = child(a!, "a1.bin")
        let b = child(a!, "b")
        #expect(a?.size == (a1?.size ?? 0) + (b?.size ?? 0))
        #expect(child(b!, "b1.bin")?.isDirectory == false)
    }

    @Test func maxDepthDirectoryIsSizedButHasNoChildren() async throws {
        try write(3_000, to: "deep/leaf/inside.bin")

        // maxDepth 1: root's children are built, but each child directory is a
        // leaf — summarized by size, not expanded.
        let tree = try await DiskAnalyzer.buildDiskTree(at: root, maxDepth: 1)
        let deep = child(tree, "deep")

        #expect(deep?.isDirectory == true)
        #expect(deep?.children.isEmpty == true)
        // Size still reflects the full subtree below the leaf (the depth-2 file).
        let deepSize = try await DiskAnalyzer.directorySize(at: root.appendingPathComponent("deep"))
        #expect(deep?.size == deepSize)
        #expect((deep?.size ?? 0) >= 3_000)
    }

    @Test func symlinkChildIsTreatedAsLeafNotRecursed() async throws {
        try write(5_000, to: "realdir/payload.bin")
        let linkURL = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: root.appendingPathComponent("realdir")
        )

        let tree = try await DiskAnalyzer.buildDiskTree(at: root, maxDepth: 3)
        let link = child(tree, "link")

        // A symlinked directory must be a leaf: recursing it would double-count the
        // target's bytes (and could loop on a self-referential link).
        #expect(link != nil)
        #expect(link?.isDirectory == false)
        #expect(link?.children.isEmpty == true)

        // The real directory is still present and sized normally.
        #expect(child(tree, "realdir")?.isDirectory == true)
    }

    @Test func childrenAreSortedBySizeDescending() async throws {
        try write(1_000, to: "small.bin")
        try write(9_000, to: "large.bin")
        try write(4_000, to: "medium.bin")

        let tree = try await DiskAnalyzer.buildDiskTree(at: root, maxDepth: 1)
        let sizes = tree.children.map(\.size)
        #expect(sizes == sizes.sorted(by: >))
        #expect(tree.children.first?.name == "large.bin")
    }
}
