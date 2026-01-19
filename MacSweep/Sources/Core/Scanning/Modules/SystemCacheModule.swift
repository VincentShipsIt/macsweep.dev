import Foundation

/// Module for cleaning system caches, logs, and crash reports
struct SystemCacheModule: ScanModule {
    let id = "system-cache"
    let name = "System Caches"
    let description = "Application caches, logs, and crash reports"
    let icon = "folder.badge.gearshape"

    private let targets: [(URL, String)] = [
        (URL.libraryDirectory.appending(path: "Caches"), "User Caches"),
        (URL.libraryDirectory.appending(path: "Logs"), "Application Logs"),
        (URL.libraryDirectory.appending(path: "Application Support/CrashReporter"), "Crash Reports"),
        (URL.libraryDirectory.appending(path: "Saved Application State"), "Saved App States"),
    ]

    func scan() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []

        for (targetURL, category) in targets {
            guard FileManager.default.fileExists(atPath: targetURL.path) else { continue }

            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: targetURL,
                    includingPropertiesForKeys: [
                        .fileSizeKey,
                        .totalFileAllocatedSizeKey,
                        .contentModificationDateKey,
                        .isDirectoryKey
                    ],
                    options: [.skipsHiddenFiles]
                )

                for url in contents {
                    let resourceValues = try url.resourceValues(forKeys: [
                        .isDirectoryKey,
                        .contentModificationDateKey
                    ])

                    let size: Int64
                    if resourceValues.isDirectory == true {
                        size = try await DiskAnalyzer.directorySize(at: url)
                    } else {
                        let sizeValues = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                        size = Int64(sizeValues.totalFileAllocatedSize ?? sizeValues.fileSize ?? 0)
                    }

                    // Skip tiny items
                    guard size > 1024 else { continue }

                    items.append(CleanupItem(
                        id: UUID(),
                        path: url,
                        size: size,
                        type: resourceValues.isDirectory == true ? .directory : .file,
                        module: id,
                        moduleName: "\(name) - \(category)",
                        lastModified: resourceValues.contentModificationDate
                    ))
                }
            } catch {
                // Continue with other targets if one fails
                continue
            }
        }

        return items.sorted { $0.size > $1.size }
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        var processedCount = 0
        var bytesFreed: Int64 = 0
        var errors: [CleanupError] = []

        for item in items {
            guard item.module == id else { continue }

            if dryRun {
                processedCount += 1
                bytesFreed += item.size
            } else {
                do {
                    if item.type == .directory {
                        // Remove contents but keep the directory
                        let contents = try FileManager.default.contentsOfDirectory(
                            at: item.path,
                            includingPropertiesForKeys: nil
                        )
                        for content in contents {
                            try FileManager.default.removeItem(at: content)
                        }
                    } else {
                        try FileManager.default.removeItem(at: item.path)
                    }
                    processedCount += 1
                    bytesFreed += item.size
                } catch {
                    errors.append(CleanupError(
                        path: item.path,
                        message: "Failed to delete: \(error.localizedDescription)",
                        underlyingError: error
                    ))
                }
            }
        }

        return CleanupResult(
            itemsProcessed: processedCount,
            bytesFreed: bytesFreed,
            errors: errors
        )
    }
}

// MARK: - URL Extension for Library Directory

extension URL {
    static var libraryDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
    }
}
