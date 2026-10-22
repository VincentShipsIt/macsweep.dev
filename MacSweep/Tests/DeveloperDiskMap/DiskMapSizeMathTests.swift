import Foundation
import Testing

@testable import MacSweepCore

struct DiskMapSizeMathTests {
    private func extreme(_ id: String, kind: DiskMapKind = .cache) -> DiskMapNode {
        DiskMapNode(id: id, name: id, kind: kind, logicalBytes: Int64.max, allocatedBytes: Int64.max)
    }

    private func assertSafeLayout(_ map: DiskMapNode) {
        let disk = map.diskNode()
        func total(_ node: DiskNode) -> Int64 {
            #expect(node.size >= 0)
            var sum = node.size
            for child in node.children {
                let addition = sum.addingReportingOverflow(total(child))
                #expect(!addition.overflow)
                sum = addition.partialValue
            }
            return sum
        }
        #expect(total(disk) <= Int64.max / 2)
        let rectangles = DiskVisualizationLayout.treemap(
            root: disk, bounds: CGRect(x: 0, y: 0, width: 900, height: 600), maxDepth: 4)
        #expect(!rectangles.isEmpty)
        #expect(
            rectangles.allSatisfy {
                $0.rect.width.isFinite && $0.rect.height.isFinite && $0.rect.width >= 0 && $0.rect.height >= 0
            })
        let rings = DiskVisualizationLayout.sunburst(root: disk, maxDepth: 4)
        #expect(rings.allSatisfy { $0.startAngle.isFinite && $0.endAngle.isFinite })
    }

    @Test func extremeRootsSaturateGroupsAndWholeMapAndActualLayoutDoesNotOverflow() {
        let report = DiskMapReport(
            roots: [extreme("one"), extreme("two"), extreme("three", kind: .toolchain)], finished: true)
        let grouped = report.grouped
        #expect(grouped.logicalBytes == Int64.max && grouped.allocatedBytes == Int64.max)
        #expect(grouped.coverage == .partial)
        #expect(grouped.children.first { $0.kind == .cache }?.coverage == .partial)
        #expect(grouped.children.first { $0.kind == .cache }?.allocatedBytes == Int64.max)
        #expect(grouped.sizeLabel.hasPrefix("At least"))
        assertSafeLayout(grouped)
        #expect(report.roots[0].allocatedBytes == Int64.max)
    }

    @Test func childAggregationRemaindersAndRepositoryPartitionsStayNonnegative() {
        var repository = DiskMapNode(id: "repo", name: "Repository", kind: .repository)
        let children = [extreme("first"), extreme("second")]
        for child in children { repository.accumulateSizes(from: child) }
        repository.children = children
        repository.appendSizeRemainder()
        #expect(repository.logicalBytes == Int64.max && repository.coverage == .partial)
        let partitioned = DiskMapMeasurement().partitionRepository(repository)
        #expect(partitioned.children.first?.logicalBytes == Int64.max)
        assertSafeLayout(partitioned)
        let malformed = DiskMapNode(
            id: "bad-repo", name: "Malformed repository", kind: .repository,
            logicalBytes: 10, allocatedBytes: 20, generatedLogical: Int64.max,
            generatedAllocated: Int64.max)
        let unknown = DiskMapMeasurement().partitionRepository(malformed)
        #expect(unknown.coverage == .unknown && unknown.children.count == 2)
        #expect(unknown.children.allSatisfy { $0.logicalBytes >= 0 && $0.allocatedBytes >= 0 && $0.hasValidOwnSizes })
        #expect(unknown.children.first { $0.kind == .source }?.logicalBytes == 0)
        #expect(unknown.children.allSatisfy { $0.coverage == .unknown && !$0.canOpenOwner })
        var inconsistent = DiskMapNode(
            id: "small", name: "Small", logicalBytes: 1, allocatedBytes: 1,
            children: children)
        inconsistent.appendSizeRemainder()
        #expect(inconsistent.coverage == .unknown)
        #expect(inconsistent.children.allSatisfy { $0.logicalBytes >= 0 && $0.allocatedBytes >= 0 })
    }

    @Test func blockConversionAndSubtractionCoverSignedBoundariesWithoutGiantFiles() {
        let exact = DiskMapSizeMath.allocated(blocks: Int64.max / 512)
        #expect(exact.bytes == Int64.max - 511 && exact.coverage == .complete)
        let overflow = DiskMapSizeMath.allocated(blocks: Int64.max / 512 + 1)
        #expect(overflow.bytes == Int64.max && overflow.coverage == .partial)
        #expect(DiskMapSizeMath.allocated(blocks: Int64.min).bytes == 0)
        #expect(DiskMapSizeMath.allocated(blocks: Int64.min).coverage == .unknown)
        #expect(DiskMapSizeMath.subtract(Int64.min, Int64.max).bytes == 0)
        #expect(DiskMapSizeMath.subtract(Int64.max, Int64.min).coverage == .unknown)
        #expect(DiskMapSizeMath.add(Int64.max, Int64.max).coverage == .partial)
        #expect(DiskMapSizeMath.add(Int64.min, Int64.max).coverage == .unknown)
    }

    @Test func negativeCachedCountersAreUnknownAndCannotReachGeometryAsNegativeWeights() async throws {
        let temporary = try TempTestDirectory(prefix: "DiskMapMalformedCache")
        let file = temporary.url.appending(path: "index.json")
        let malformed = DiskMapNode(
            id: "negative", name: "Malformed cached root", kind: .cache,
            owner: .packageManagers, logicalBytes: Int64.min, allocatedBytes: -1,
            generatedLogical: Int64.max, generatedAllocated: Int64.min,
            children: [extreme("child")])
        let entry = DiskMapCache.Entry(
            key: "fixture", report: DiskMapReport(roots: [malformed], finished: true),
            records: ["negative": DiskMapCache.Record(node: malformed, hardLinks: [])])
        let data = try JSONEncoder().encode(entry)
        try data.write(to: file)
        let cache = DiskMapCache(file: file)
        let restored = try #require(await cache.get("fixture"))
        let root = try #require(restored.report.roots.first)
        #expect(root.logicalBytes == 0 && root.allocatedBytes == 0 && root.coverage == .unknown)
        #expect(root.generatedLogical == 0 && root.generatedAllocated == 0)
        #expect(root.sizeLabel == "Size unknown" && !root.canOpenOwner)
        #expect(restored.records["negative"]?.node.coverage == .unknown)
        #expect(restored.report.grouped.coverage == .unknown)
        #expect(!(await cache.put(entry, freeBytes: Int64.max)))
        #expect(try Data(contentsOf: file) == data)
        assertSafeLayout(root)
    }
}
