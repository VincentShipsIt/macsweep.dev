import Foundation

/// Module for cleaning system caches, logs, and crash reports
struct SystemCacheModule: ScanModule {
    typealias PermanentRemover = @Sendable (URL, String) throws -> Void

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

    /// Injectable only to make deletion failures deterministic in regression tests.
    /// Production always uses the audited central remover.
    private let permanentRemover: PermanentRemover
    private let emptyDirectoryRemover: PermanentRemover

    init() {
        permanentRemover = { url, module in
            try CleanupFileRemover.permanent(url, module: module)
        }
        emptyDirectoryRemover = { url, module in
            try CleanupFileRemover.permanentEmptyDirectory(url, module: module)
        }
    }

    init(permanentRemover: @escaping PermanentRemover) {
        self.permanentRemover = permanentRemover
        emptyDirectoryRemover = { url, module in
            try CleanupFileRemover.permanentEmptyDirectory(url, module: module)
        }
    }

    init(
        permanentRemover: @escaping PermanentRemover,
        emptyDirectoryRemover: @escaping PermanentRemover
    ) {
        self.permanentRemover = permanentRemover
        self.emptyDirectoryRemover = emptyDirectoryRemover
    }

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
        var processed = 0
        var freed: Int64 = 0
        var errors: [CleanupError] = []
        let checker = SafetyChecker()

        for item in items where item.module == id {
            if dryRun {
                processed += 1
                freed += item.size
                continue
            }

            if let validationError = validationError(for: item.path, type: item.type, checker: checker) {
                errors.append(validationError)
                continue
            }

            if item.type == .directory {
                // Remove the directory's CONTENTS but keep the directory itself.
                // Each child is removed via a recursive, per-node validated walk
                // (see removeValidatedNode) rather than trusting
                // CleanupFileRemover.permanent to recurse blindly — a protected
                // subdir or symlink deep in the tree must not be swept away, and
                // the module's own protected-name list is enforced at delete
                // time, not just at scan.
                let contents: [URL]
                do {
                    contents = try FileManager.default.contentsOfDirectory(
                        at: item.path,
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                    )
                } catch {
                    errors.append(deletionError(at: item.path, error: error, action: "inspect"))
                    continue
                }

                var directoryResult = NodeRemovalResult.success
                for content in contents {
                    directoryResult.merge(await removeValidatedNode(content, checker: checker))
                }

                // The selected cache root is intentionally kept, so it cannot
                // use the atomic `rmdir` emptiness check applied to nested
                // directories. Re-enumerate it after removals: a protected or
                // otherwise unvalidated child may have arrived after the first
                // snapshot. Such a survivor keeps the actual removed-byte
                // credit, but the item must be reported as partial rather than
                // full success.
                do {
                    let survivors = try FileManager.default.contentsOfDirectory(
                        at: item.path,
                        includingPropertiesForKeys: nil,
                        options: []
                    )
                    for survivor in survivors
                    where !directoryResult.hasReportedFailure(atOrBelow: survivor) {
                        directoryResult.fullyRemoved = false
                        directoryResult.errors.append(CleanupError(
                            path: survivor,
                            message: "Cache item appeared or remained after cleanup"
                        ))
                    }
                } catch {
                    directoryResult.fullyRemoved = false
                    directoryResult.errors.append(
                        deletionError(at: item.path, error: error, action: "verify")
                    )
                }

                freed += directoryResult.bytesFreed
                errors.append(contentsOf: directoryResult.errors)
                if directoryResult.fullyRemoved {
                    processed += 1
                }
            } else {
                let result = await removeValidatedNode(item.path, checker: checker)
                freed += result.bytesFreed
                errors.append(contentsOf: result.errors)
                if result.fullyRemoved {
                    processed += 1
                }
            }
        }

        return CleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
    }

    /// Recursively remove a validated subtree and report its exact outcome.
    ///
    /// Every node is re-checked at delete time — with its real on-disk type —
    /// against BOTH the module's own protected-name list (`isProtected`) and the
    /// shared `SafetyChecker`. Protected or unsafe nodes are left in place, and
    /// any ancestor directory still holding a survivor is preserved rather than
    /// force-deleted. This closes the gap where only immediate children were
    /// validated before a blind recursive `permanent()` on the subtree.
    private func removeValidatedNode(_ url: URL, checker: SafetyChecker) async -> NodeRemovalResult {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey,
                .fileSizeKey
            ])
        } catch {
            return .failure(deletionError(at: url, error: error, action: "inspect"))
        }

        let isSymlink = values.isSymbolicLink == true
        let isDirectory = values.isDirectory == true && !isSymlink
        let nodeType: CleanupItem.ItemType =
            isSymlink ? .symbolicLink : (isDirectory ? .directory : .file)

        if let validationError = validationError(for: url, type: nodeType, checker: checker) {
            return .failure(validationError)
        }

        var result = NodeRemovalResult.success
        if isDirectory {
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
            } catch {
                return .failure(deletionError(at: url, error: error, action: "inspect"))
            }

            for child in children {
                result.merge(await removeValidatedNode(child, checker: checker))
            }
            // Only remove the directory once every child is gone; a surviving
            // protected descendant keeps its ancestors alive.
            guard result.fullyRemoved else { return result }
        }

        do {
            if isDirectory {
                // This must stay non-recursive. A child can appear after the
                // validated enumeration above; rmdir fails closed in that case
                // instead of deleting the unvalidated arrival.
                try emptyDirectoryRemover(url, id)
            } else {
                try permanentRemover(url, id)
            }
            result.bytesFreed += values.diskSize
            return result
        } catch {
            result.fullyRemoved = false
            result.errors.append(deletionError(at: url, error: error, action: "delete"))
            return result
        }
    }

    /// `nil` means the node is safe to remove; otherwise the returned error
    /// explains the precise safety veto to the user.
    private func validationError(
        for url: URL,
        type: CleanupItem.ItemType,
        checker: SafetyChecker
    ) -> CleanupError? {
        if isProtected(url) {
            return CleanupError(path: url, message: "Skipped protected cache item")
        }

        let validation = checker.validateForCleanup(url, moduleID: id, itemType: type)
        guard !validation.isSafe else { return nil }
        let reason = validation.reason.map { ": \($0)" } ?? ""
        return CleanupError(path: url, message: "Blocked by safety checks\(reason)")
    }

    private func deletionError(at url: URL, error: Error, action: String) -> CleanupError {
        CleanupError(
            path: url,
            message: "Failed to \(action): \(error.localizedDescription)",
            underlyingError: error
        )
    }

    private struct NodeRemovalResult {
        var fullyRemoved: Bool
        var bytesFreed: Int64
        var errors: [CleanupError]

        static let success = NodeRemovalResult(fullyRemoved: true, bytesFreed: 0, errors: [])

        static func failure(_ error: CleanupError) -> NodeRemovalResult {
            NodeRemovalResult(fullyRemoved: false, bytesFreed: 0, errors: [error])
        }

        mutating func merge(_ other: NodeRemovalResult) {
            fullyRemoved = fullyRemoved && other.fullyRemoved
            bytesFreed += other.bytesFreed
            errors.append(contentsOf: other.errors)
        }

        func hasReportedFailure(atOrBelow url: URL) -> Bool {
            let survivorPath = url.standardizedFileURL.path
            return errors.contains { error in
                let errorPath = error.path.standardizedFileURL.path
                return errorPath == survivorPath || errorPath.hasPrefix(survivorPath + "/")
            }
        }
    }
}

// MARK: - URL Extension for Library Directory

extension URL {
    static var libraryDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
    }
}
