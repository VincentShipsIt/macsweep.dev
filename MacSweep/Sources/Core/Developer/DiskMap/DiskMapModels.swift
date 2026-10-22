import Foundation

/// Navigation destinations, never deletion authority. The application maps these to feature pages.
enum DiskMapOwner: String, Codable, Sendable {
    case developerTools, packageManagers, toolchains, xcode, virtualMachines, editorCaches

    var title: String {
        switch self {
        case .developerTools: return "Developer Tools"
        case .packageManagers: return "Package Managers"
        case .toolchains: return "Toolchains"
        case .xcode: return "Xcode"
        case .virtualMachines: return "Virtual Machines"
        case .editorCaches: return "Editor Caches"
        }
    }
}

enum DiskMapKind: String, Codable, Sendable {
    case repository, source, generated, toolchain, cache, simulator, vmData, swap, ordinary

    var title: String {
        switch self {
        case .repository: return "Repositories"
        case .source: return "Source & repository metadata"
        case .generated: return "Generated artifacts"
        case .toolchain: return "Toolchains"
        case .cache: return "Package & editor caches"
        case .simulator: return "Simulators"
        case .vmData: return "Persistent VM & container data"
        case .swap: return "System swap · no action"
        case .ordinary: return "Other files"
        }
    }
}

enum DiskMapCoverage: String, Codable, Sendable { case complete, partial, unknown }

struct DiskMapNode: Identifiable, Codable, Sendable {
    var id: String
    var url: URL?
    var name: String
    var kind: DiskMapKind = .ordinary
    var owner: DiskMapOwner?
    var logicalBytes: Int64 = 0
    var allocatedBytes: Int64 = 0
    var generatedLogical: Int64 = 0
    var generatedAllocated: Int64 = 0
    var modified: Date?
    var coverage: DiskMapCoverage = .complete
    var protectedReason: String?
    var children: [DiskMapNode] = []

    var sizeLabel: String {
        coverage == .unknown || !hasValidOwnSizes
            ? "Size unknown" : "\(coverage == .partial ? "At least " : "")\(allocatedBytes.formattedFileSize) allocated"
    }
    var logicalLabel: String {
        coverage == .unknown || !hasValidOwnSizes
            ? "Logical size unknown"
            : "\(coverage == .partial ? "At least " : "")\(logicalBytes.formattedFileSize) logical"
    }
    var canOpenOwner: Bool {
        owner != nil && coverage != .unknown && hasValidOwnSizes && kind != .source && kind != .swap
    }

    func find(_ identifier: String) -> DiskMapNode? {
        if id == identifier
            || DiskMapRoots.physicalSystemAlias(URL(fileURLWithPath: id)).path
                == DiskMapRoots.physicalSystemAlias(URL(fileURLWithPath: identifier)).path {
            return self
        }
        for child in children { if let found = child.find(identifier) { return found } }
        return nil
    }

    /// Geometry reuses the existing Space Lens layout; zero-size unknown blocks remain in the accompanying list.
    func diskNode(maxDepth: Int = 4) -> DiskNode {
        let node = normalizedSizes()
        let total = node.geometryWeightTotal(depth: max(0, maxDepth))
        let budget = Double(Int64.max / 4)
        let divisor = max(1, total / budget)
        return node.geometryNode(depth: max(0, maxDepth), divisor: divisor)
    }

    private func geometryWeightTotal(depth: Int) -> Double {
        Double(allocatedBytes)
            + (depth > 0
                ? children.reduce(0.0) {
                    $0 + $1.geometryWeightTotal(depth: depth - 1)
                } : 0)
    }

    private func geometryNode(depth: Int, divisor: Double) -> DiskNode {
        // Only layout weights are rescaled. The map's detail labels retain measured/clamped byte counts.
        let weight = divisor > 1 ? Int64(min(Double(Int64.max / 4), Double(allocatedBytes) / divisor)) : allocatedBytes
        return DiskNode(
            url: URL(fileURLWithPath: id), name: name, size: weight, isDirectory: !children.isEmpty,
            children: depth > 0 ? children.map { $0.geometryNode(depth: depth - 1, divisor: divisor) } : [],
            lastModified: modified)
    }

}

struct DiskMapReport: Codable, Sendable {
    var roots: [DiskMapNode] = []
    var issues: [String] = []
    var measuredAt = Date()
    var fullHome = false
    var cached = false
    var finished = false

    var grouped: DiskMapNode {
        let normalized = roots.map { $0.normalizedSizes() }
        let groups = Dictionary(grouping: normalized, by: \.kind).map { kind, nodes in
            var group = DiskMapNode(
                id: "group:\(kind.rawValue)", name: kind.title, kind: kind,
                coverage: Self.coverage(nodes),
                children: nodes.sorted { $0.allocatedBytes > $1.allocatedBytes })
            for node in nodes { group.accumulateSizes(from: node) }
            return group
        }.sorted { $0.allocatedBytes > $1.allocatedBytes }
        var root = DiskMapNode(
            id: "map", name: "Developer Disk Map",
            coverage: finished && issues.isEmpty ? Self.coverage(normalized) : .partial, children: groups)
        for group in groups { root.accumulateSizes(from: group) }
        return root
    }
    private static func coverage(_ nodes: [DiskMapNode]) -> DiskMapCoverage {
        if nodes.allSatisfy({ $0.coverage == .complete }) { return .complete }
        if nodes.allSatisfy({ $0.coverage == .unknown }) { return .unknown }
        return .partial
    }

}

struct DiskMapRoot: Sendable {
    let url: URL
    var kind: DiskMapKind
    var owner: DiskMapOwner?
}

struct DiskMapLimits: Sendable {
    var maximumEntries = 150_000
    var seconds: TimeInterval = 4
    var maximumDepth = 96
    var visibleDepth = 4
    var maximumVisibleNodes = 1200
    var maximumScanSeconds: TimeInterval = 25
    var maximumRoots = 128
}
