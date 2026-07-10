import Foundation

/// High-performance disk analyzer using URLResourceKey
actor DiskAnalyzer {

    // MARK: - Static Helpers

    /// Get size of a file or directory
    static func size(of url: URL) async throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey])

        if values.isDirectory == true {
            return try await directorySize(at: url)
        } else {
            return values.diskSize
        }
    }

    /// Calculate total size of a directory
    static func directorySize(at url: URL) async throws -> Int64 {
        let resourceKeys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .isDirectoryKey,
            .isSymbolicLinkKey
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0

        var iterations = 0
        while let fileURL = enumerator.nextObject() as? URL {
            // Subtree sizing is called from long scans; keep it cancellable so
            // an abandoned scan stops burning IO.
            iterations += 1
            if iterations % 512 == 0 { try Task.checkCancellation() }
            do {
                let values = try fileURL.resourceValues(forKeys: resourceKeys)

                // Skip symlinks to avoid infinite loops
                if values.isSymbolicLink == true { continue }

                // Only count files, not directories themselves
                if values.isDirectory == false {
                    total += values.diskSize
                }
            } catch {
                continue
            }
        }

        return total
    }

    // MARK: - Disk Tree Analysis

    /// Build a tree structure for disk visualization
    static func buildDiskTree(at url: URL, maxDepth: Int = 3) async throws -> DiskNode {
        try await buildNode(at: url, depth: 0, maxDepth: maxDepth)
    }

    private static func buildNode(at url: URL, depth: Int, maxDepth: Int) async throws -> DiskNode {
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]

        let values = try url.resourceValues(forKeys: resourceKeys)
        // A symlinked directory must be treated as a leaf: following it would let
        // a self-referential link (e.g. ~/foo -> ~) recurse forever, and any link
        // pointing inside the tree would double-count its target's bytes.
        let isDirectory = values.isDirectory == true && values.isSymbolicLink != true

        if !isDirectory {
            // It's a file (or a symlink, counted by its own small on-disk size)
            let size = values.diskSize
            return DiskNode(
                url: url,
                name: url.lastPathComponent,
                size: size,
                isDirectory: false,
                children: [],
                lastModified: values.contentModificationDate
            )
        }

        // It's a directory
        var children: [DiskNode] = []
        var totalSize: Int64 = 0

        if depth < maxDepth {
            // Enumerate children
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else {
                return DiskNode(url: url, name: url.lastPathComponent, size: 0, isDirectory: true, children: [])
            }

            // Process children in parallel batches
            let childNodes = await withTaskGroup(of: DiskNode?.self, returning: [DiskNode].self) { group in
                for childURL in contents {
                    group.addTask {
                        try? await buildNode(at: childURL, depth: depth + 1, maxDepth: maxDepth)
                    }
                }

                var results: [DiskNode] = []
                for await node in group {
                    if let node = node {
                        results.append(node)
                    }
                }
                return results
            }

            children = childNodes.sorted { $0.size > $1.size }
            totalSize = children.reduce(0) { $0 + $1.size }
        } else {
            // At max depth, just calculate size without children
            totalSize = (try? await directorySize(at: url)) ?? 0
        }

        return DiskNode(
            url: url,
            name: url.lastPathComponent,
            size: totalSize,
            isDirectory: true,
            children: children,
            lastModified: values.contentModificationDate
        )
    }

    // MARK: - Quick Stats

    /// Get quick disk usage stats for a path
    static func quickStats(at url: URL) async -> DiskQuickStats {
        let resourceKeys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]

        guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
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

struct DiskNode: Identifiable, Hashable {
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
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
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
        ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    var formattedAvailable: String {
        ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
    }

    var formattedUsed: String {
        ByteCountFormatter.string(fromByteCount: used, countStyle: .file)
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
