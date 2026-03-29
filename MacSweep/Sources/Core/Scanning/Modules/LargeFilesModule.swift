import Foundation
import UniformTypeIdentifiers

/// Module for finding large files that consume disk space
struct LargeFilesModule: ScanModule {
    let id = "large-files"
    let name = "Large Files"
    let description = "Find large files and folders over the size threshold"
    let icon = "doc.badge.ellipsis"

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
            guard let enumerator = FileManager.default.enumerator(
                at: searchPath,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
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

                    let checker = SafetyChecker()
                    guard checker.validateForScan(url, moduleID: id).isSafe else { continue }

                    let activityDate = values.contentAccessDate ?? values.contentModificationDate

                    if values.isDirectory == true {
                        guard scanKind.includesFolders else { continue }

                        let depth = max(0, relativePath.split(separator: "/").count - 1)
                        guard depth <= maxDirectoryDepth else {
                            enumerator.skipDescendants()
                            continue
                        }

                        let size = try await DiskAnalyzer.directorySize(at: url)
                        guard size >= threshold else { continue }

                        items.append(CleanupItem(
                            id: UUID(),
                            path: url,
                            size: size,
                            type: .directory,
                            module: id,
                            moduleName: "Folder",
                            lastModified: activityDate
                        ))

                        if depth >= maxDirectoryDepth {
                            enumerator.skipDescendants()
                        }

                        if items.count >= maxResults {
                            break
                        }

                        continue
                    }

                    guard scanKind.includesFiles else { continue }

                    // Get file size
                    let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                    guard size >= threshold else { continue }

                    items.append(CleanupItem(
                        id: UUID(),
                        path: url,
                        size: size,
                        type: .file,
                        module: id,
                        moduleName: fileCategory(for: values.contentType),
                        lastModified: activityDate
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
        var processed = 0
        var freed: Int64 = 0
        var errors: [CleanupError] = []

        for item in items where item.module == id {
            if dryRun {
                processed += 1
                freed += item.size
            } else {
                do {
                    // Move to trash instead of permanent delete
                    try FileManager.default.trashItem(at: item.path, resultingItemURL: nil)
                    processed += 1
                    freed += item.size
                } catch {
                    errors.append(CleanupError(
                        path: item.path,
                        message: error.localizedDescription,
                        underlyingError: error
                    ))
                }
            }
        }

        return CleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
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
