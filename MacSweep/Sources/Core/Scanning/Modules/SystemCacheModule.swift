import Foundation

/// Module for cleaning system caches, logs, and crash reports
struct SystemCacheModule: ScanModule {
    let id = "system-cache"
    let name = "System Caches"
    let description = "Application caches, logs, and crash reports"
    let icon = "folder.badge.gearshape"

    /// Standard user library targets
    private let libraryTargets: [(URL, String)] = [
        (URL.libraryDirectory.appending(path: "Caches"), "User Caches"),
        (URL.libraryDirectory.appending(path: "Logs"), "Application Logs"),
        (URL.libraryDirectory.appending(path: "Application Support/CrashReporter"), "Crash Reports"),
        (URL.libraryDirectory.appending(path: "Saved Application State"), "Saved App States"),
    ]

    /// Protected subdirectory names that should never be deleted
    private let protectedSubdirectories: Set<String> = [
        "CloudKit",
        "com.apple.LaunchServices",
        "com.apple.nsurlsessiond",
        "com.apple.bird",
        "TemporaryItems",
        "Metadata",
        "AssetCache",
        "com.apple.DiskUtility",
        "com.apple.appstore",
        "com.apple.softwareupdate",
    ]

    /// Protected file patterns that should never be deleted
    private let protectedFilePatterns: [String] = [
        ".DS_Store",
        ".localized",
        "lockfile",
        ".lock",
    ]

    func scan() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []

        // Scan library targets
        for (targetURL, category) in libraryTargets {
            let scannedItems = await scanDirectory(targetURL, category: category)
            items.append(contentsOf: scannedItems)
        }

        // Scan system temp folders (/private/var/folders)
        let systemTempItems = await scanSystemTempFolders()
        items.append(contentsOf: systemTempItems)

        return items.sorted { $0.size > $1.size }
    }

    /// Scan a target directory for cleanup items
    private func scanDirectory(_ targetURL: URL, category: String) async -> [CleanupItem] {
        guard FileManager.default.fileExists(atPath: targetURL.path) else { return [] }

        var items: [CleanupItem] = []

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
                // Skip protected subdirectories
                if isProtected(url) { continue }

                do {
                    let resourceValues = try url.resourceValues(forKeys: [
                        .isDirectoryKey,
                        .contentModificationDateKey
                    ])

                    let size: Int64
                    if resourceValues.isDirectory == true {
                        size = try await DiskAnalyzer.directorySize(at: url)
                    } else {
                        let sizeValues = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                        size = sizeValues.diskSize
                    }

                    // Skip tiny items (less than 1KB)
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
                } catch {
                    // Skip items we can't read
                    continue
                }
            }
        } catch {
            // Directory access failed, return empty
            return []
        }

        return items
    }

    /// Scan /private/var/folders for user-specific temp files
    private func scanSystemTempFolders() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        // Get user's temporary directory which is typically in /private/var/folders/XX/XXXXX/T/
        let userTempDir = FileManager.default.temporaryDirectory

        // Find the base folder path (parent of T)
        let userFolderBase = userTempDir.deletingLastPathComponent()

        // Safe subdirectories within var/folders: T (temp), C (cache), 0 (scratch)
        let safeSubdirs = ["T", "C", "0"]

        for subdir in safeSubdirs {
            let subdirURL = userFolderBase.appending(path: subdir)
            guard FileManager.default.fileExists(atPath: subdirURL.path) else { continue }

            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: subdirURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )

                for url in contents {
                    // Skip system items and protected items
                    if isProtected(url) { continue }

                    // Skip items modified recently (within last hour) - they might be in use
                    if let modDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       Date().timeIntervalSince(modDate) < 3600 {
                        continue
                    }

                    do {
                        let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
                        let size: Int64

                        if resourceValues.isDirectory == true {
                            size = try await DiskAnalyzer.directorySize(at: url)
                        } else {
                            let sizeValues = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                            size = sizeValues.diskSize
                        }

                        // Skip tiny items
                        guard size > 10240 else { continue }  // 10KB threshold for system temp

                        let category = subdir == "T" ? "Temporary Files" : subdir == "C" ? "System Cache" : "Scratch Files"

                        items.append(CleanupItem(
                            id: UUID(),
                            path: url,
                            size: size,
                            type: resourceValues.isDirectory == true ? .directory : .file,
                            module: id,
                            moduleName: "\(name) - \(category)",
                            lastModified: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                        ))
                    } catch {
                        continue
                    }
                }
            } catch {
                continue
            }
        }

        return items
    }

    /// Check if a path is protected and should not be deleted
    private func isProtected(_ url: URL) -> Bool {
        let filename = url.lastPathComponent

        // Check protected subdirectory names
        if protectedSubdirectories.contains(filename) {
            return true
        }

        // Check protected file patterns
        for pattern in protectedFilePatterns {
            if filename.hasSuffix(pattern) || filename == pattern {
                return true
            }
        }

        // Don't delete items with "Apple" in the name (system caches)
        if filename.lowercased().contains("apple") && filename.contains("com.apple.") {
            // Allow com.apple.Safari caches and similar user-facing app caches
            let allowedAppleCaches = ["com.apple.Safari", "com.apple.Preview", "com.apple.Notes"]
            if !allowedAppleCaches.contains(where: { filename.hasPrefix($0) }) {
                return true
            }
        }

        return false
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        var processedCount = 0
        var bytesFreed: Int64 = 0
        var errors: [CleanupError] = []
        let checker = SafetyChecker()

        for item in items {
            guard item.module == id else { continue }

            if dryRun {
                processedCount += 1
                bytesFreed += item.size
            } else {
                // Defense-in-depth: re-validate every item before deleting,
                // even though scan() already filtered to safe paths.
                guard checker.validateForCleanup(item.path, moduleID: id, itemType: item.type).isSafe else {
                    errors.append(CleanupError(
                        path: item.path,
                        message: "Blocked by safety checks"
                    ))
                    continue
                }
                do {
                    if item.type == .directory {
                        // Remove contents but keep the directory. Re-validate EACH
                        // child: between scan and clean an app may have written new
                        // files into its cache dir, and only item.path itself was
                        // gated above. Permanent deletion is intentional here — this
                        // module's role is removing regenerable cache (trashing it
                        // would just hold junk in the Trash until emptied).
                        let contents = try FileManager.default.contentsOfDirectory(
                            at: item.path,
                            includingPropertiesForKeys: nil
                        )
                        for content in contents {
                            guard checker.validateForCleanup(content, moduleID: id, itemType: .file).isSafe else {
                                continue
                            }
                            try CleanupFileRemover.permanent(content)
                        }
                    } else {
                        try CleanupFileRemover.permanent(item.path)
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
