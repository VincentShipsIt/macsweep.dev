import Foundation
import Testing
@testable import MacSweepCore

struct DiskVisualizationLayoutTests {
    private func file(_ name: String, size: Int64) -> DiskNode {
        DiskNode(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            size: size,
            isDirectory: false,
            children: []
        )
    }

    private func directory(_ name: String, children: [DiskNode]) -> DiskNode {
        DiskNode(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            size: children.reduce(0) { $0 + $1.size },
            isDirectory: true,
            children: children
        )
    }

    @Test func treemapIncludesFilesInsideTopLevelFolders() throws {
        let source = file("main.swift", size: 700)
        let archive = file("release.zip", size: 300)
        let project = directory("project", children: [source, archive])
        let root = directory("home", children: [project])

        let segments = DiskVisualizationLayout.treemap(
            root: root,
            bounds: CGRect(x: 0, y: 0, width: 600, height: 400)
        )

        #expect(segments.map(\.node.name) == ["project", "main.swift", "release.zip"])
        #expect(segments.map(\.depth) == [0, 1, 1])

        let projectRect = try #require(segments.first?.rect)
        for child in segments.dropFirst() {
            #expect(projectRect.contains(child.rect))
        }
    }

    @Test func treemapKeepsTinyFoldersAsSingleReadableTiles() {
        let nested = directory("nested", children: [file("photo.jpg", size: 100)])
        let root = directory("home", children: [nested])

        let segments = DiskVisualizationLayout.treemap(
            root: root,
            bounds: CGRect(x: 0, y: 0, width: 60, height: 40)
        )

        #expect(segments.map(\.node.name) == ["nested"])
        #expect(segments.first?.containsChildren == false)
    }

    @Test func sunburstUsesASecondRingForNestedFiles() throws {
        let source = file("main.swift", size: 700)
        let archive = file("release.zip", size: 300)
        let project = directory("project", children: [source, archive])
        let root = directory("home", children: [project])

        let segments = DiskVisualizationLayout.sunburst(root: root)
        let projectSegment = try #require(segments.first { $0.node.name == "project" })
        let sourceSegment = try #require(segments.first { $0.node.name == "main.swift" })

        #expect(projectSegment.depth == 0)
        #expect(sourceSegment.depth == 1)
        #expect(sourceSegment.innerRadius == projectSegment.outerRadius)
        #expect(sourceSegment.startAngle >= projectSegment.startAngle)
        #expect(sourceSegment.endAngle <= projectSegment.endAngle)
    }

    @Test func layoutSegmentsCacheTheirDominantVisibleFileCategory() throws {
        let project = directory("project", children: [
            file("demo.mov", size: 900),
            file("thumbnail.jpg", size: 100)
        ])
        let root = directory("home", children: [project])

        let treemap = DiskVisualizationLayout.treemap(
            root: root,
            bounds: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        let sunburst = DiskVisualizationLayout.sunburst(root: root)

        let treemapProject = try #require(treemap.first { $0.node.name == "project" })
        let sunburstProject = try #require(sunburst.first { $0.node.name == "project" })

        #expect(treemapProject.colorCategory == "purple")
        #expect(sunburstProject.colorCategory == "purple")
    }

    @Test func categoryAggregationStopsAtTheVisibleDepth() throws {
        let hiddenVideo = file("hidden.mov", size: 900)
        let hiddenFolder = directory("hidden", children: [hiddenVideo])
        let visibleImage = file("visible.jpg", size: 100)
        let project = directory("project", children: [hiddenFolder, visibleImage])
        let root = directory("home", children: [project])

        let segments = DiskVisualizationLayout.treemap(
            root: root,
            bounds: CGRect(x: 0, y: 0, width: 600, height: 400),
            maxDepth: 2
        )

        let projectSegment = try #require(segments.first { $0.node.name == "project" })
        let hiddenSegment = try #require(segments.first { $0.node.name == "hidden" })

        #expect(projectSegment.colorCategory == "green")
        #expect(hiddenSegment.colorCategory == "blue")
    }

    @Test func treemapFrameSizeNeverBecomesNegative() {
        let tiny = DiskVisualizationLayout.treemapFrameSize(
            for: CGRect(x: 0, y: 0, width: 1, height: 0.5)
        )
        let regular = DiskVisualizationLayout.treemapFrameSize(
            for: CGRect(x: 0, y: 0, width: 80, height: 60)
        )

        #expect(tiny == .zero)
        #expect(regular == CGSize(width: 78, height: 58))
    }
}
