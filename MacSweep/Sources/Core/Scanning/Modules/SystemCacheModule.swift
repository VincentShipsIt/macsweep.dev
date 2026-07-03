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

                    let size = try await DiskAnalyzer.size(of: url)

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
                        let size = try await DiskAnalyzer.size(of: url)

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
        await cleanItems(
            items,
            dryRun: dryRun,
            errorMessage: { "Failed to delete: \($0.localizedDescription)" }
        ) { item, checker in
            if item.type == .directory {
                // Remove the directory's CONTENTS but keep the directory itself.
                // Each child is removed via a recursive, per-node validated walk
                // (see removeValidatedNode) rather than trusting
                // CleanupFileRemover.permanent to recurse blindly — a protected
                // subdir or symlink deep in the tree must not be swept away, and
                // the module's own protected-name list is enforced at delete
                // time, not just at scan.
                let contents = try FileManager.default.contentsOfDirectory(
                    at: item.path,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                for content in contents {
                    removeValidatedNode(content, checker: checker)
                }
            } else {
                try CleanupFileRemover.permanent(item.path)
            }
        }
    }

    /// Recursively remove a validated subtree, returning whether `url` was fully
    /// removed.
    ///
    /// Every node is re-checked at delete time — with its real on-disk type —
    /// against BOTH the module's own protected-name list (`isProtected`) and the
    /// shared `SafetyChecker`. Protected or unsafe nodes are left in place, and
    /// any ancestor directory still holding a survivor is preserved rather than
    /// force-deleted. This closes the gap where only immediate children were
    /// validated before a blind recursive `permanent()` on the subtree.
    @discardableResult
    private func removeValidatedNode(_ url: URL, checker: SafetyChecker) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let isSymlink = values?.isSymbolicLink == true
        let isDirectory = values?.isDirectory == true && !isSymlink
        let nodeType: CleanupItem.ItemType = isSymlink ? .symbolicLink : (isDirectory ? .directory : .file)

        guard !isProtected(url) else { return false }
        guard checker.validateForCleanup(url, moduleID: id, itemType: nodeType).isSafe else { return false }

        if isDirectory {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )) ?? []
            var allChildrenRemoved = true
            for child in children where !removeValidatedNode(child, checker: checker) {
                allChildrenRemoved = false
            }
            // Only remove the directory once every child is gone; a surviving
            // protected descendant keeps its ancestors alive.
            guard allChildrenRemoved else { return false }
        }

        do {
            try CleanupFileRemover.permanent(url)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - URL Extension for Library Directory

extension URL {
    static var libraryDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
    }
}
