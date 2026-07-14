import Foundation

/// A visible rectangle in Space Lens' hierarchical treemap.
struct DiskTreemapSegment: Identifiable {
    let node: DiskNode
    let rect: CGRect
    let depth: Int
    let containsChildren: Bool
    let colorCategory: String

    var id: DiskNode.ID { node.id }
}

/// A visible ring segment in Space Lens' hierarchical sunburst.
struct DiskSunburstSegment: Identifiable {
    let node: DiskNode
    let startAngle: Double
    let endAngle: Double
    let innerRadius: Double
    let outerRadius: Double
    let depth: Int
    let colorCategory: String

    var id: DiskNode.ID { node.id }
}

/// Depth-limited post-order metrics for one visualization root. Keeping this
/// separate from the geometry code makes the single traversal explicit and
/// prevents segment rendering from recursively revisiting directory subtrees.
private enum DiskVisualizationAnalysis {
    struct Result {
        let visibleDepth: Int
        let colorCategories: [DiskNode.ID: String]
    }

    private struct NodeResult {
        let visibleDepth: Int
        let categoryWeights: [String: Int64]
    }

    static func analyze(root: DiskNode, maxDepth: Int) -> Result {
        var colorCategories: [DiskNode.ID: String] = [:]
        let rootResult = analyze(
            node: root,
            remainingDepth: maxDepth,
            colorCategories: &colorCategories
        )
        return Result(
            visibleDepth: rootResult.visibleDepth,
            colorCategories: colorCategories
        )
    }

    private static func analyze(
        node: DiskNode,
        remainingDepth: Int,
        colorCategories: inout [DiskNode.ID: String]
    ) -> NodeResult {
        if !node.isDirectory {
            colorCategories[node.id] = node.color
            let size = max(0, node.size)
            return NodeResult(
                visibleDepth: 0,
                categoryWeights: size > 0 ? [node.color: size] : [:]
            )
        }

        guard remainingDepth > 0, !node.children.isEmpty else {
            colorCategories[node.id] = node.color
            return NodeResult(visibleDepth: 0, categoryWeights: [:])
        }

        var visibleDepth = 0
        var categoryWeights: [String: Int64] = [:]
        for child in node.children {
            let childResult = analyze(
                node: child,
                remainingDepth: remainingDepth - 1,
                colorCategories: &colorCategories
            )
            visibleDepth = max(visibleDepth, childResult.visibleDepth + 1)
            for (category, size) in childResult.categoryWeights {
                categoryWeights[category, default: 0] += size
            }
        }

        colorCategories[node.id] = dominantCategory(in: categoryWeights) ?? node.color
        return NodeResult(
            visibleDepth: visibleDepth,
            categoryWeights: categoryWeights
        )
    }

    private static func dominantCategory(in weights: [String: Int64]) -> String? {
        weights.max { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key > rhs.key
            }
            return lhs.value < rhs.value
        }?.key
    }
}

/// Pure, testable layout logic shared by the Space Lens visualizations.
enum DiskVisualizationLayout {
    private struct TreemapContext {
        let maxDepth: Int
        let colorCategories: [DiskNode.ID: String]
    }

    private struct SunburstContext {
        let maxDepth: Int
        let innerRadius: Double
        let ringWidth: Double
        let colorCategories: [DiskNode.ID: String]
    }

    private static let folderInset: CGFloat = 4
    private static let folderHeaderHeight: CGFloat = 18
    private static let minimumNestedWidth: CGFloat = 72
    private static let minimumNestedHeight: CGFloat = 54
    private static let tileSpacing: CGFloat = 2

    static func treemap(
        root: DiskNode,
        bounds: CGRect,
        maxDepth: Int = 2
    ) -> [DiskTreemapSegment] {
        guard maxDepth > 0 else { return [] }

        let analysis = DiskVisualizationAnalysis.analyze(root: root, maxDepth: maxDepth)
        var segments: [DiskTreemapSegment] = []
        appendTreemapChildren(
            root.children,
            bounds: bounds,
            depth: 0,
            context: TreemapContext(
                maxDepth: maxDepth,
                colorCategories: analysis.colorCategories
            ),
            into: &segments
        )
        return segments
    }

    static func sunburst(root: DiskNode, maxDepth: Int = 2) -> [DiskSunburstSegment] {
        guard maxDepth > 0 else { return [] }

        let analysis = DiskVisualizationAnalysis.analyze(root: root, maxDepth: maxDepth)
        guard analysis.visibleDepth > 0 else { return [] }

        let innerRadius = 0.25
        let outerRadius = 0.90
        let ringWidth = (outerRadius - innerRadius) / Double(analysis.visibleDepth)
        var segments: [DiskSunburstSegment] = []

        appendSunburstChildren(
            root.children,
            angles: -90...270,
            depth: 0,
            context: SunburstContext(
                maxDepth: analysis.visibleDepth,
                innerRadius: innerRadius,
                ringWidth: ringWidth,
                colorCategories: analysis.colorCategories
            ),
            into: &segments
        )
        return segments
    }

    /// Returns the exact dimensions passed to a treemap tile's SwiftUI frame.
    /// Size-weighted partitions can be smaller than the visual spacing, so clamp
    /// after subtracting it rather than handing SwiftUI a negative dimension.
    static func treemapFrameSize(for rect: CGRect) -> CGSize {
        CGSize(
            width: max(0, rect.width - tileSpacing),
            height: max(0, rect.height - tileSpacing)
        )
    }

    private static func appendTreemapChildren(
        _ children: [DiskNode],
        bounds: CGRect,
        depth: Int,
        context: TreemapContext,
        into segments: inout [DiskTreemapSegment]
    ) {
        let rects = partition(items: children, bounds: bounds)

        for (child, rect) in zip(children, rects) {
            let canNest = depth + 1 < context.maxDepth
                && !child.children.isEmpty
                && rect.width >= minimumNestedWidth
                && rect.height >= minimumNestedHeight

            segments.append(DiskTreemapSegment(
                node: child,
                rect: rect,
                depth: depth,
                containsChildren: canNest,
                colorCategory: context.colorCategories[child.id] ?? child.color
            ))

            guard canNest else { continue }
            let childBounds = CGRect(
                x: rect.minX + folderInset,
                y: rect.minY + folderHeaderHeight,
                width: max(0, rect.width - folderInset * 2),
                height: max(0, rect.height - folderHeaderHeight - folderInset)
            )
            appendTreemapChildren(
                child.children,
                bounds: childBounds,
                depth: depth + 1,
                context: context,
                into: &segments
            )
        }
    }

    private static func partition(items: [DiskNode], bounds: CGRect) -> [CGRect] {
        guard !items.isEmpty else { return [] }

        let totalSize = items.reduce(Int64(0)) { $0 + max(0, $1.size) }
        guard totalSize > 0 else { return items.map { _ in .zero } }

        var rects: [CGRect] = []
        var remaining = bounds
        var remainingItems = items

        while !remainingItems.isEmpty {
            let rowItems = takeRow(from: &remainingItems)
            let isHorizontal = remaining.width >= remaining.height
            let rowTotal = rowItems.reduce(Int64(0)) { $0 + max(0, $1.size) }
            let remainingTotal = remainingItems.reduce(Int64(0)) { $0 + max(0, $1.size) }
            guard rowTotal > 0 else {
                rects.append(contentsOf: rowItems.map { _ in .zero })
                continue
            }
            let rowRatio = CGFloat(rowTotal) / CGFloat(rowTotal + remainingTotal)
            let rowBounds = removeRow(
                ratio: rowRatio,
                horizontal: isHorizontal,
                from: &remaining
            )
            rects.append(contentsOf: itemRects(
                rowItems,
                total: rowTotal,
                bounds: rowBounds,
                horizontal: isHorizontal
            ))
        }

        return rects
    }

    private static func takeRow(from items: inout [DiskNode]) -> [DiskNode] {
        guard items.count > 1 else {
            defer { items = [] }
            return items
        }

        let targetSize = items.reduce(Int64(0)) { $0 + max(0, $1.size) } / 2
        var rowSize: Int64 = 0
        var splitIndex = 1
        for (index, item) in items.enumerated() {
            rowSize += max(0, item.size)
            if rowSize >= targetSize {
                splitIndex = max(1, index)
                break
            }
        }

        let row = Array(items.prefix(splitIndex + 1))
        items = Array(items.dropFirst(splitIndex + 1))
        return row
    }

    private static func removeRow(
        ratio: CGFloat,
        horizontal: Bool,
        from remaining: inout CGRect
    ) -> CGRect {
        if horizontal {
            let width = remaining.width * ratio
            let row = CGRect(
                x: remaining.minX,
                y: remaining.minY,
                width: width,
                height: remaining.height
            )
            remaining = CGRect(
                x: remaining.minX + width,
                y: remaining.minY,
                width: remaining.width - width,
                height: remaining.height
            )
            return row
        }

        let height = remaining.height * ratio
        let row = CGRect(
            x: remaining.minX,
            y: remaining.minY,
            width: remaining.width,
            height: height
        )
        remaining = CGRect(
            x: remaining.minX,
            y: remaining.minY + height,
            width: remaining.width,
            height: remaining.height - height
        )
        return row
    }

    private static func itemRects(
        _ items: [DiskNode],
        total: Int64,
        bounds: CGRect,
        horizontal: Bool
    ) -> [CGRect] {
        var offset: CGFloat = 0
        return items.map { item in
            let ratio = CGFloat(max(0, item.size)) / CGFloat(total)
            if horizontal {
                let height = bounds.height * ratio
                defer { offset += height }
                return CGRect(
                    x: bounds.minX,
                    y: bounds.minY + offset,
                    width: bounds.width,
                    height: height
                )
            }

            let width = bounds.width * ratio
            defer { offset += width }
            return CGRect(
                x: bounds.minX + offset,
                y: bounds.minY,
                width: width,
                height: bounds.height
            )
        }
    }

    private static func appendSunburstChildren(
        _ children: [DiskNode],
        angles: ClosedRange<Double>,
        depth: Int,
        context: SunburstContext,
        into segments: inout [DiskSunburstSegment]
    ) {
        let totalSize = children.reduce(Int64(0)) { $0 + max(0, $1.size) }
        guard totalSize > 0 else { return }

        var currentAngle = angles.lowerBound
        let availableSweep = angles.upperBound - angles.lowerBound

        for child in children {
            let sweep = availableSweep * (Double(max(0, child.size)) / Double(totalSize))
            let childEndAngle = currentAngle + sweep
            segments.append(DiskSunburstSegment(
                node: child,
                startAngle: currentAngle,
                endAngle: childEndAngle,
                innerRadius: context.innerRadius + Double(depth) * context.ringWidth,
                outerRadius: context.innerRadius + Double(depth + 1) * context.ringWidth,
                depth: depth,
                colorCategory: context.colorCategories[child.id] ?? child.color
            ))

            if depth + 1 < context.maxDepth, !child.children.isEmpty {
                appendSunburstChildren(
                    child.children,
                    angles: currentAngle...childEndAngle,
                    depth: depth + 1,
                    context: context,
                    into: &segments
                )
            }
            currentAngle = childEndAngle
        }
    }

}
