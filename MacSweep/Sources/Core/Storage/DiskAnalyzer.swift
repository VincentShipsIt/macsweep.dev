import Foundation

/// High-performance disk analyzer using URLResourceKey
actor DiskAnalyzer {

    // MARK: - Static Helpers

    /// Heavy filesystem work shares a global utility-priority budget with developer scans.
    static func size(of url: URL) async throws -> Int64 {
        try await DevArtifactIO.run {
            let values = try url.scanResourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey
            ])
            if values.isDirectory == true && values.isSymbolicLink != true {
                return try directorySizeSynchronously(at: url)
            }
            return values.diskSize
        }
    }

    static func directorySize(at url: URL) async throws -> Int64 {
        try await DevArtifactIO.run { try directorySizeSynchronously(at: url) }
    }

    private static func directorySizeSynchronously(at url: URL) throws -> Int64 {
        try Task.checkCancellation()
        if try url.scanResourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { return 0 }
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey
        ]
        guard let entries = ScanFileSystem.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        var inspected = 0
        while let path = entries.nextObject() as? URL {
            inspected += 1
            if inspected % 128 == 0 { try Task.checkCancellation() }
            guard let values = try? path.scanResourceValues(forKeys: keys), values.isSymbolicLink != true else {
                continue
            }
            if values.isDirectory == false { total += values.diskSize }
        }
        return total
    }

    static func buildDiskTree(at url: URL, maxDepth: Int = 3) async throws -> DiskNode {
        try await DevArtifactIO.run { try buildNode(at: url, depth: 0, maxDepth: maxDepth) }
    }

    /// One synchronous walk owns one permit. Recursion creates no queued directory tasks.
    private static func buildNode(at url: URL, depth: Int, maxDepth: Int) throws -> DiskNode {
        try Task.checkCancellation()
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey
        ]
        let values = try url.scanResourceValues(forKeys: keys)
        let directory = values.isDirectory == true && values.isSymbolicLink != true
        guard directory else {
            return DiskNode(
                url: url, name: url.lastPathComponent, size: values.diskSize,
                isDirectory: false, children: [], lastModified: values.contentModificationDate)
        }
        if depth >= maxDepth {
            return DiskNode(
                url: url, name: url.lastPathComponent,
                size: try directorySizeSynchronously(at: url), isDirectory: true, children: [],
                lastModified: values.contentModificationDate)
        }
        let children = try children(at: url, depth: depth, maxDepth: maxDepth, keys: keys)
        return DiskNode(
            url: url, name: url.lastPathComponent, size: children.reduce(0) { $0 + $1.size },
            isDirectory: true, children: children.sorted { $0.size > $1.size },
            lastModified: values.contentModificationDate)
    }

    private static func children(
        at url: URL, depth: Int, maxDepth: Int, keys: Set<URLResourceKey>
    ) throws -> [DiskNode] {
        guard let entries = try? ScanFileSystem.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
        else {
            return []
        }
        var nodes: [DiskNode] = []
        for path in entries {
            try Task.checkCancellation()
            do {
                nodes.append(try buildNode(at: path, depth: depth + 1, maxDepth: maxDepth))
            } catch is CancellationError { throw CancellationError() } catch {
                // Preserve the previous best-effort leaf representation and diagnostic collector.
                nodes.append(
                    DiskNode(url: path, name: path.lastPathComponent, size: 0, isDirectory: false, children: []))
            }
        }
        return nodes
    }

    // MARK: - Quick Stats

    /// Get quick disk usage stats for a path
    static func quickStats(at url: URL) async -> DiskQuickStats {
        let resourceKeys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]

        guard let values = try? url.scanResourceValues(forKeys: resourceKeys) else {
            return DiskQuickStats(total: 0, available: 0, used: 0)
        }

        let total: Int64 = Int64(values.volumeTotalCapacity ?? 0)
        let importantUsage: Int64 = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        let regularCapacity: Int64 = Int64(values.volumeAvailableCapacity ?? 0)
        let available: Int64 = importantUsage > 0 ? importantUsage : regularCapacity

        return DiskQuickStats(
            total: total,
            available: available,
            used: total - available
        )
    }

    /// Get largest items in a directory
    static func largestItems(in url: URL, limit: Int = 20) async throws -> [DiskNode] {
        let node = try await buildDiskTree(at: url, maxDepth: 1)
        return Array(node.children.sorted { $0.size > $1.size }.prefix(limit))
    }
}

// MARK: - Models

struct DiskNode: Identifiable, Hashable, Sendable {
    static func == (lhs: DiskNode, rhs: DiskNode) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    let id = UUID()
    let url: URL
    let name: String
    let size: Int64
    let isDirectory: Bool
    var children: [DiskNode]
    var lastModified: Date?

    var formattedSize: String {
        size.formattedFileSize
    }

    /// Percentage of parent's size (set externally)
    var percentage: Double = 0

    /// Color based on file type
    var color: String {
        if isDirectory { return "blue" }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp4", "mov", "avi", "mkv", "m4v", "wmv":
            return "purple"
        case "jpg", "jpeg", "png", "gif", "heic", "raw", "tiff", "bmp":
            return "green"
        case "mp3", "m4a", "wav", "flac", "aac", "ogg":
            return "orange"
        case "zip", "rar", "7z", "tar", "gz", "dmg", "iso":
            return "yellow"
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx":
            return "red"
        case "swift", "js", "ts", "py", "rb", "go", "rs", "cpp", "c", "h":
            return "cyan"
        default:
            return "gray"
        }
    }
}

struct DiskQuickStats {
    let total: Int64
    let available: Int64
    let used: Int64

    var usedPercentage: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total)
    }

    var formattedTotal: String {
        total.formattedFileSize
    }

    var formattedAvailable: String {
        available.formattedFileSize
    }

    var formattedUsed: String {
        used.formattedFileSize
    }
}

// MARK: - Resource value sizing

extension URLResourceValues {
    /// Preferred on-disk allocated size, falling back to the logical file size.
    /// Centralizes the `totalFileAllocatedSize ?? fileSize ?? 0` idiom that the
    /// scan modules and disk analyzer all need.
    var diskSize: Int64 {
        Int64(totalFileAllocatedSize ?? fileSize ?? 0)
    }
}
