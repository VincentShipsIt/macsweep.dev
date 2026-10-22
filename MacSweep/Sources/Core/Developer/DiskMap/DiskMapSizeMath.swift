import Foundation

/// Saturation preserves a lower bound; malformed negative or inconsistent evidence stays unknown.
enum DiskMapSizeMath {
    struct Amount {
        let bytes: Int64
        let coverage: DiskMapCoverage
    }

    static func add(_ lhs: Int64, _ rhs: Int64) -> Amount {
        let sum = max(0, lhs).addingReportingOverflow(max(0, rhs))
        let coverage: DiskMapCoverage = lhs < 0 || rhs < 0 ? .unknown : sum.overflow ? .partial : .complete
        return Amount(bytes: sum.overflow ? Int64.max : sum.partialValue, coverage: coverage)
    }

    static func subtract(_ lhs: Int64, _ rhs: Int64) -> Amount {
        guard lhs >= 0, rhs >= 0, lhs >= rhs else { return Amount(bytes: 0, coverage: .unknown) }
        return Amount(bytes: lhs - rhs, coverage: .complete)
    }

    static func allocated(blocks: Int64) -> Amount {
        guard blocks >= 0 else { return Amount(bytes: 0, coverage: .unknown) }
        let product = blocks.multipliedReportingOverflow(by: 512)
        return Amount(
            bytes: product.overflow ? Int64.max : product.partialValue,
            coverage: product.overflow ? .partial : .complete)
    }
}

extension DiskMapNode {
    var hasValidOwnSizes: Bool {
        logicalBytes >= 0 && allocatedBytes >= 0 && generatedLogical >= 0 && generatedAllocated >= 0
            && generatedLogical <= logicalBytes && generatedAllocated <= allocatedBytes
    }

    mutating func applySize(_ amount: DiskMapSizeMath.Amount, to key: WritableKeyPath<DiskMapNode, Int64>) {
        self[keyPath: key] = amount.bytes
        if amount.coverage == .unknown { coverage = .unknown }
        if amount.coverage == .partial && coverage != .unknown { coverage = .partial }
    }

    mutating func accumulateSizes(from child: DiskMapNode) {
        applySize(DiskMapSizeMath.add(logicalBytes, child.logicalBytes), to: \.logicalBytes)
        applySize(DiskMapSizeMath.add(allocatedBytes, child.allocatedBytes), to: \.allocatedBytes)
        applySize(DiskMapSizeMath.add(generatedLogical, child.generatedLogical), to: \.generatedLogical)
        applySize(DiskMapSizeMath.add(generatedAllocated, child.generatedAllocated), to: \.generatedAllocated)
        if child.coverage != .complete && coverage == .complete { coverage = .partial }
    }

    func normalizedSizes() -> DiskMapNode {
        var node = self
        if !hasValidOwnSizes { node.coverage = .unknown }
        node.logicalBytes = max(0, logicalBytes)
        node.allocatedBytes = max(0, allocatedBytes)
        node.generatedLogical = min(node.logicalBytes, max(0, generatedLogical))
        node.generatedAllocated = min(node.allocatedBytes, max(0, generatedAllocated))
        node.children = children.map { $0.normalizedSizes() }
        let sum = Self.sizeSummary(node.children)
        if sum.logicalBytes > node.logicalBytes || sum.allocatedBytes > node.allocatedBytes {
            node.coverage = .unknown
        } else if sum.coverage != .complete && node.coverage == .complete {
            node.coverage = .partial
        }
        return node
    }

    static func sizeSummary(_ children: [DiskMapNode]) -> DiskMapNode {
        var sum = DiskMapNode(id: "size-summary", name: "Measured contents")
        for child in children { sum.accumulateSizes(from: child) }
        return sum
    }

    mutating func appendSizeRemainder() {
        guard !children.isEmpty else { return }
        let sum = Self.sizeSummary(children)
        var remainder = DiskMapNode(
            id: id + "#other", url: url, name: "Other measured contents", kind: kind,
            owner: owner, coverage: coverage, protectedReason: protectedReason)
        remainder.applySize(DiskMapSizeMath.subtract(logicalBytes, sum.logicalBytes), to: \.logicalBytes)
        remainder.applySize(DiskMapSizeMath.subtract(allocatedBytes, sum.allocatedBytes), to: \.allocatedBytes)
        remainder.applySize(DiskMapSizeMath.subtract(generatedLogical, sum.generatedLogical), to: \.generatedLogical)
        remainder.applySize(
            DiskMapSizeMath.subtract(generatedAllocated, sum.generatedAllocated), to: \.generatedAllocated)
        if remainder.coverage == .unknown { coverage = .unknown }
        if sum.coverage != .complete && coverage == .complete { coverage = .partial }
        if remainder.logicalBytes > 0 || remainder.allocatedBytes > 0 { children.append(remainder.normalizedSizes()) }
    }
}
