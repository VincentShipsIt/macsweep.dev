import Foundation
import UniformTypeIdentifiers

/// Module for finding large files that consume disk space
struct LargeFilesModule: ScanModule {
    let id = "large-files"
    let name = "Large Files"
    let description = "Find large files and folders over the size threshold"
    let icon = "doc.badge.ellipsis"

    /// Injection seam for deterministic rule tests; production loads the same
    /// home-directory files as every other SafetyChecker consumer.
    var userRules: UserProtectionRules = .load()

    enum ScanKind: String, CaseIterable {
        case files = "Files"
        case folders = "Folders"
        case both = "Files & Folders"

        var includesFiles: Bool {
            self == .files || self == .both
        }

        var includesFolders: Bool {
            self == .folders || self == .both
        }
    }

    /// Minimum file size to report (default 100MB)
    var threshold: Int64 = 104_857_600

    /// Maximum number of results to return
    var maxResults: Int = 500

    /// What kind of large items to scan for
    var scanKind: ScanKind = .both

    /// Prevent expensive repeated sizing of deeply nested folders
    var maxDirectoryDepth: Int = 3

    /// Paths to search
    var searchPaths: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser
    ]

    /// Paths to exclude from search
    var excludePaths: Set<String> = [
        "Library/Mail",
        "Library/Messages",
        "Library/Calendars",
        "Library/Contacts",
        ".Trash",
        "Library/Mobile Documents",
        "Library/CloudStorage",
    ]

    func scan() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []

        let resourceKeys: Set<URLResourceKey> = [
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .contentAccessDateKey,
            .contentTypeKey
        ]

        for searchPath in searchPaths {
            let checker = SafetyChecker(userRules: userRules)
            // Size every directory under `searchPath` in a SINGLE enumeration,
            // instead of re-walking each subtree via DiskAnalyzer.directorySize at
            // every ancestor level (the old O(files × depth) hot path: a file N
            // levels deep was counted once by each of its N sized ancestors).
            // The numbers are identical to directorySize by construction — same
            // enumerator options, same symlink/hidden handling, same on-disk
            // sizing — so folder surfacing decisions are byte-for-byte unchanged.
            // Skipped entirely when folders aren't being surfaced (nothing reads it).
            let subtreeSizes = scanKind.includesFolders
                ? try Self.subtreeSizes(under: searchPath, checker: checker, moduleID: id)
                : [:]

            guard let enumerator = FileManager.default.enumerator(
                at: searchPath,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            // Hoisted out of the hot per-file loop so the two small user rule
            // files are parsed once per search root, not once per finding.
            var iterations = 0
            while let url = enumerator.nextObject() as? URL {
                // Whole-home enumeration can run for minutes; without this check
                // a cancelled scan keeps burning IO to completion.
                iterations += 1
                if iterations % 512 == 0 { try Task.checkCancellation() }

                // Check if we should skip this path
                let relativePath = url.path.replacingOccurrences(
                    of: searchPath.path + "/",
                    with: ""
                )
                if excludePaths.contains(where: { relativePath.hasPrefix($0) }) {
                    enumerator.skipDescendants()
                    continue
                }

                do {
                    let values = try url.resourceValues(forKeys: resourceKeys)

                    // Skip symlinks
                    guard values.isSymbolicLink == false else { continue }

                    guard checker.validateForScan(url, moduleID: id).isSafe else {
                        if values.isDirectory == true {
                            enumerator.skipDescendants()
                        }
                        continue
                    }

                    let activityDate = values.contentAccessDate ?? values.contentModificationDate

                    if values.isDirectory == true {
                        guard scanKind.includesFolders else { continue }

                        let depth = max(0, relativePath.split(separator: "/").count - 1)
                        guard depth <= maxDirectoryDepth else {
                            enumerator.skipDescendants()
                            continue
                        }

                        let size = subtreeSizes[url.path] ?? 0
                        guard size >= threshold else { continue }

                        let item = CleanupItem(
                            id: UUID(),
                            path: url,
                            size: size,
                            type: .directory,
                            module: id,
                            moduleName: "Folder",
                            lastModified: activityDate
                        )
                        items.append(item.markingCleanupReview(
                            reason: checker.validateForCleanup(item, moduleID: id).reason
                        ))

                        // Always skip into a surfaced directory: its contents are
                        // already counted in its size. Without this, scanKind=.both
                        // would also surface large child files, producing overlapping
                        // items — double-counted bytes in dry-run, and a trashItem
                        // failure on the child after the parent was already trashed.
                        // (Also avoids re-walking an already-sized subtree.)
                        enumerator.skipDescendants()

                        if items.count >= maxResults {
                            break
                        }

                        continue
                    }

                    guard scanKind.includesFiles else { continue }

                    // Get file size
                    let size = values.diskSize
                    guard size >= threshold else { continue }

                    let item = CleanupItem(
                        id: UUID(),
                        path: url,
                        size: size,
                        type: .file,
                        module: id,
                        moduleName: fileCategory(for: values.contentType),
                        lastModified: activityDate
                    )
                    items.append(item.markingCleanupReview(
                        reason: checker.validateForCleanup(item, moduleID: id).reason
                    ))

                    // Limit results
                    if items.count >= maxResults {
                        break
                    }
                } catch {
                    continue
                }
            }
        }

        return items.sorted { $0.size > $1.size }
    }

    /// Total on-disk size of every directory under `root`, keyed by absolute
    /// path, computed in a single enumeration. Each file's on-disk size is folded
    /// into all of its ancestor directories up to `root`.
    ///
    /// This is the crux of the performance fix: `DiskAnalyzer.directorySize(at:)`
    /// re-enumerates a whole subtree per call, so sizing a directory and then its
    /// children re-walked the same files O(depth) times. Here every file is read
    /// exactly once. The result for any directory equals `directorySize(at:)`
    /// exactly — identical enumerator options (`.skipsHiddenFiles`, packages
    /// descended into), identical symlink skipping, identical `diskSize` sizing —
    /// so the scan surfaces the same folders with the same byte counts.
    private static func subtreeSizes(
        under root: URL,
        checker: SafetyChecker,
        moduleID: String
    ) throws -> [String: Int64] {
        let resourceKeys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .isDirectoryKey,
            .isSymbolicLinkKey
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        let rootPath = root.path
        var sizes: [String: Int64] = [:]
        var processed = 0

        while let fileURL = enumerator.nextObject() as? URL {
            processed += 1
            // Periodic cooperative cancellation without a check-per-file cost.
            if processed & 0x3FFF == 0 { try Task.checkCancellation() }

            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else { continue }
            // Match directorySize: skip symlinks, count only files.
            if values.isSymbolicLink == true { continue }
            guard values.isDirectory == false else { continue }
            guard checker.validateForScan(fileURL, moduleID: moduleID).isSafe else { continue }

            let bytes = values.diskSize
            guard bytes > 0 else { continue }

            // Fold this file's bytes into each ancestor directory up to `root`.
            var dir = fileURL.deletingLastPathComponent()
            while true {
                let path = dir.path
                sizes[path, default: 0] += bytes
                if path == rootPath || path.count <= rootPath.count { break }
                dir = dir.deletingLastPathComponent()
            }
        }

        return sizes
    }

    /// Categorize file by type
    private func fileCategory(for contentType: UTType?) -> String {
        guard let type = contentType else { return "Other" }

        if type.conforms(to: .movie) || type.conforms(to: .video) {
            return "Video"
        } else if type.conforms(to: .image) {
            return "Image"
        } else if type.conforms(to: .audio) {
            return "Audio"
        } else if type.conforms(to: .archive) || type.conforms(to: .zip) {
            return "Archive"
        } else if type.conforms(to: .diskImage) {
            return "Disk Image"
        } else if type.conforms(to: .application) {
            return "Application"
        } else if type.conforms(to: .pdf) {
            return "Document"
        } else if type.conforms(to: .sourceCode) {
            return "Code"
        } else {
            return "Other"
        }
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        await cleanItems(items, dryRun: dryRun) { item, _ in
            try CleanupFileRemover.recoverable(item.path, module: item.module)
        }
    }
}

// MARK: - Large Files Filter

struct LargeFilesFilter {
    var minSize: Int64 = 104_857_600  // 100MB
    var maxSize: Int64? = nil
    var types: Set<String>? = nil      // Filter by category
    var olderThan: Date? = nil         // Last modified before
    var searchPath: URL? = nil         // Specific folder

    func apply(to items: [CleanupItem]) -> [CleanupItem] {
        items.filter { item in
            // Size filter
            if item.size < minSize { return false }
            if let max = maxSize, item.size > max { return false }

            // Type filter
            if let types = types, !types.contains(item.moduleName) {
                return false
            }

            // Age filter
            if let olderThan = olderThan,
               let modified = item.lastModified,
               modified > olderThan {
                return false
            }

            // Path filter
            if let searchPath = searchPath,
               !item.path.path.hasPrefix(searchPath.path) {
                return false
            }

            return true
        }
    }
}
