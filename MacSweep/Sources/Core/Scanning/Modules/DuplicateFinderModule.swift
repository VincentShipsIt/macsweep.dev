import Foundation
import CryptoKit

/// Module for finding and removing duplicate files
struct DuplicateFinderModule: ScanModule {
    let id = "duplicates"
    let name = "Duplicate Files"
    let description = "Find and remove duplicate files to free space"
    let icon = "doc.on.doc"

    var searchPaths: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser,
    ]

    var minSize: Int64 = 1024  // Skip files < 1KB
    var maxSize: Int64 = 5_368_709_120  // Skip files > 5GB

    func scan() async throws -> [CleanupItem] {
        var sizeGroups: [Int64: [URL]] = [:]

        // Phase 1: Group by size
        for searchPath in searchPaths {
            await scanDirectory(searchPath, into: &sizeGroups)
        }

        // Phase 2: Hash files with matching sizes
        var duplicateGroups: [DuplicateGroup] = []

        for (size, urls) in sizeGroups where urls.count > 1 {
            let groups = await findDuplicatesInGroup(urls: urls, size: size)
            duplicateGroups.append(contentsOf: groups)
        }

        // Phase 3: Convert to CleanupItems
        let selector = DuplicateSelector()
        return duplicateGroups.flatMap { group in
            selector.autoSelect(group).map { file in
                CleanupItem(
                    id: file.id,
                    path: file.path,
                    size: file.size,
                    type: .file,
                    module: id,
                    moduleName: "Duplicate of \(group.original?.path.lastPathComponent ?? "file")",
                    lastModified: file.modifiedDate
                )
            }
        }
    }

    private func scanDirectory(_ root: URL, into sizeGroups: inout [Int64: [URL]]) async {
        let resourceKeys: Set<URLResourceKey> = [
            .fileSizeKey,
            .isDirectoryKey,
            .isSymbolicLinkKey
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        // Hoisted out of the hot per-file loop (SafetyChecker is stateless).
        let checker = SafetyChecker()
        while let url = enumerator.nextObject() as? URL {
            do {
                let values = try url.resourceValues(forKeys: resourceKeys)

                // Skip directories and symlinks
                guard values.isDirectory == false,
                      values.isSymbolicLink == false,
                      let size = values.fileSize
                else { continue }

                let size64 = Int64(size)

                // Skip files outside size range
                guard size64 >= minSize, size64 <= maxSize else { continue }

                // Skip protected paths
                guard checker.validateForScan(url, moduleID: id).isSafe else { continue }

                sizeGroups[size64, default: []].append(url)
            } catch {
                continue
            }
        }
    }

    private func findDuplicatesInGroup(urls: [URL], size: Int64) async -> [DuplicateGroup] {
        // Stage 1: bucket by a cheap hash. Small files are hashed in full;
        // large files only get a partial (head/middle/tail) hash.
        var quickGroups: [String: [URL]] = [:]
        for url in urls {
            if let hash = await computeHash(for: url, size: size) {
                quickGroups[hash, default: []].append(url)
            }
        }

        // Stage 2: confirm. A partial-hash match is NOT proof of identity — two
        // distinct large files can share head/middle/tail bytes, and acting on a
        // false positive trashes a unique file the user never duplicated. For
        // large files, re-bucket each partial-hash candidate by a full-content
        // hash before treating them as duplicates. Small files were already
        // hashed in full, so their buckets are definitive.
        var hashGroups: [String: [URL]] = [:]
        let isFullyHashed = size < 1_048_576
        for (quickHash, candidates) in quickGroups where candidates.count > 1 {
            if isFullyHashed {
                hashGroups[quickHash] = candidates
            } else {
                for url in candidates {
                    guard let full = try? streamingFullHash(url) else { continue }
                    hashGroups["\(quickHash):\(full)", default: []].append(url)
                }
            }
        }

        return hashGroups.compactMap { (hash, urls) -> DuplicateGroup? in
            guard urls.count > 1 else { return nil }

            let files = urls.compactMap { url -> DuplicateFile? in
                guard let values = try? url.resourceValues(forKeys: [
                    .fileSizeKey,
                    .creationDateKey,
                    .contentModificationDateKey
                ]) else { return nil }

                return DuplicateFile(
                    id: UUID(),
                    path: url,
                    size: Int64(values.fileSize ?? 0),
                    createdDate: values.creationDate ?? Date(),
                    modifiedDate: values.contentModificationDate ?? Date()
                )
            }

            guard files.count > 1 else { return nil }

            return DuplicateGroup(
                id: UUID(),
                hash: hash,
                size: size,
                files: files
            )
        }
    }

    private func computeHash(for url: URL, size: Int64) async -> String? {
        // For small files (< 1MB), hash entire file
        // For larger files, use partial hash (first 4KB + middle 4KB + last 4KB)

        do {
            if size < 1_048_576 {
                return try fullHash(url)
            } else {
                return try partialHash(url, size: size)
            }
        } catch {
            return nil
        }
    }

    private func fullHash(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Full-content SHA-256 read in chunks, so confirming a large-file duplicate
    /// never loads the whole file (up to 5GB) into memory at once.
    private func streamingFullHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1_048_576)  // 1MB
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func partialHash(_ url: URL, size: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()

        // First 4KB
        let first = handle.readData(ofLength: 4096)
        hasher.update(data: first)

        // Middle 4KB
        let middleOffset = UInt64(size / 2)
        try handle.seek(toOffset: middleOffset)
        let middle = handle.readData(ofLength: 4096)
        hasher.update(data: middle)

        // Last 4KB
        let lastOffset = max(0, UInt64(size) - 4096)
        try handle.seek(toOffset: lastOffset)
        let last = handle.readData(ofLength: 4096)
        hasher.update(data: last)

        let hash = hasher.finalize()
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        await cleanItems(
            items,
            dryRun: dryRun,
            errorMessage: { _ in "Failed to remove duplicate" }
        ) { item, _ in
            try FileManager.default.trashItem(at: item.path, resultingItemURL: nil)
        }
    }
}

// MARK: - Models

struct DuplicateGroup: Identifiable {
    let id: UUID
    let hash: String
    let size: Int64
    let files: [DuplicateFile]

    var wastedSpace: Int64 {
        size * Int64(max(0, files.count - 1))
    }

    var original: DuplicateFile? {
        files.min(by: { $0.createdDate < $1.createdDate })
    }

    var formattedWastedSpace: String {
        ByteCountFormatter.string(fromByteCount: wastedSpace, countStyle: .file)
    }
}

struct DuplicateFile: Identifiable, Hashable {
    let id: UUID
    let path: URL
    let size: Int64
    let createdDate: Date
    let modifiedDate: Date

    var isInTrash: Bool {
        path.path.contains(".Trash")
    }

    var isInDownloads: Bool {
        path.path.contains("/Downloads/")
    }

    var displayName: String {
        path.lastPathComponent
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DuplicateFile, rhs: DuplicateFile) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Smart Selection

struct DuplicateSelector {
    /// Auto-select duplicates to delete, keeping the best one
    func autoSelect(_ group: DuplicateGroup) -> [DuplicateFile] {
        guard group.files.count > 1 else { return [] }

        let sorted = group.files.sorted { file1, file2 in
            // Priority order (higher is better to keep):
            // 1. Not in trash
            // 2. In important location (Documents > Desktop > Pictures)
            // 3. Oldest (likely original)

            if file1.isInTrash != file2.isInTrash {
                return !file1.isInTrash  // Not in trash is better
            }

            let priority1 = locationPriority(file1.path)
            let priority2 = locationPriority(file2.path)
            if priority1 != priority2 {
                return priority1 > priority2
            }

            return file1.createdDate < file2.createdDate  // Older is better
        }

        // Keep the first (best), return rest for deletion
        return Array(sorted.dropFirst())
    }

    private func locationPriority(_ url: URL) -> Int {
        let path = url.path

        // Important user folders
        if path.contains("/Documents/") { return 100 }
        if path.contains("/Desktop/") { return 90 }
        if path.contains("/Pictures/") { return 85 }
        if path.contains("/Movies/") { return 85 }
        if path.contains("/Music/") { return 85 }

        // Less important
        if path.contains("/Downloads/") { return 50 }
        if path.contains("/tmp/") { return 20 }
        if path.contains("/.Trash/") { return 0 }

        return 60  // Default
    }
}
