import Foundation

/// Module for reclaiming local storage consumed by cloud providers.
struct CloudCleanupModule: ScanModule {
    let id = "cloud-cleanup"
    let name = "Cloud Cleanup"
    let description = "Evict stale iCloud downloads and remove cloud provider cache folders"
    let icon = "icloud"

    var minimumFileSize: Int64 = 52_428_800
    var staleDays: Int = 30
    var maxResults: Int = 250

    func scan() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []
        items.append(contentsOf: try await scanCloudFiles())
        items.append(contentsOf: await scanCloudCaches())
        return items.sorted { $0.size > $1.size }
    }

    private func scanCloudFiles() async throws -> [CleanupItem] {
        let roots = [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mobile Documents"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/CloudStorage"),
        ]

        let staleCutoff = Calendar.current.date(byAdding: .day, value: -staleDays, to: Date()) ?? .distantPast
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentAccessDateKey,
            .contentModificationDateKey,
        ]

        var items: [CleanupItem] = []
        let checker = SafetyChecker()

        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                guard checker.validateForScan(url, moduleID: id).isSafe else { continue }

                let values = try? url.resourceValues(forKeys: resourceKeys)
                guard values?.isDirectory == false else { continue }
                guard values?.isUbiquitousItem == true || url.path.contains("/Mobile Documents/") else { continue }

                let size = values?.diskSize ?? 0
                guard size >= minimumFileSize else { continue }

                let activityDate = values?.contentAccessDate ?? values?.contentModificationDate ?? .distantFuture
                guard activityDate < staleCutoff else { continue }

                let provider = providerName(for: url)
                items.append(CleanupItem(
                    id: UUID(),
                    path: url,
                    size: size,
                    type: .file,
                    module: id,
                    moduleName: "\(provider) Local Copy",
                    lastModified: activityDate
                ))

                if items.count >= maxResults {
                    return items
                }
            }
        }

        return items
    }

    private func scanCloudCaches() async -> [CleanupItem] {
        // ONLY genuine regenerable caches under ~/Library/Caches.
        //
        // Deliberately excluded — these are NOT caches and removing them is data
        // loss or sync breakage:
        //   • ~/Library/CloudStorage/*  — the live File Provider mounts. These
        //     ARE the user's synced Dropbox/Google Drive/OneDrive files.
        //   • ~/Library/Application Support/Dropbox — Dropbox's sync database and
        //     config, not cache.
        //   • ~/Library/Application Support/CloudDocs — iCloud Drive sync state.
        let roots = [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/CloudKit"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/Dropbox"),
        ]

        var items: [CleanupItem] = []
        let checker = SafetyChecker()
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            // Defense-in-depth: only surface a cache root the safety gate accepts.
            guard checker.validateForScan(root, moduleID: id).isSafe else { continue }

            let size = (try? await DiskAnalyzer.directorySize(at: root)) ?? 0
            guard size >= minimumFileSize else { continue }

            let date = (try? root.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil

            items.append(CleanupItem(
                id: UUID(),
                path: root,
                size: size,
                type: .directory,
                module: id,
                moduleName: "\(providerName(for: root)) Cache",
                lastModified: date
            ))
        }

        return items
    }

    private func providerName(for url: URL) -> String {
        let path = url.path.lowercased()
        if path.contains("dropbox") { return "Dropbox" }
        if path.contains("onedrive") { return "OneDrive" }
        if path.contains("googledrive") || path.contains("google drive") { return "Google Drive" }
        if path.contains("mobile documents") || path.contains("clouddocs") || path.contains("cloudstorage") {
            return "iCloud"
        }
        return "Cloud"
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

            // Defense-in-depth: gate every item, including the iCloud evictions.
            guard checker.validateForCleanup(item.path, moduleID: id, itemType: item.type).isSafe else {
                errors.append(CleanupError(
                    path: item.path,
                    message: "Blocked by safety checks"
                ))
                continue
            }

            do {
                // Route on the AUTHORITATIVE live ubiquitous status, not a display
                // string: an iCloud-backed file must be evicted (non-destructive,
                // stays in the cloud), never permanently deleted. The scan-time
                // "Local Copy" name is only a secondary hint. Permanent deletion is
                // reserved for items positively confirmed to be regenerable provider
                // caches (not ubiquitous and not flagged a local copy), so a future
                // rename of the moduleName can never turn an eviction into deletion.
                let isUbiquitous = (try? item.path.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false
                if isUbiquitous || item.moduleName.contains("Local Copy") {
                    // Non-destructive: frees the local copy, file stays in iCloud.
                    try FileManager.default.evictUbiquitousItem(at: item.path)
                } else {
                    // Provider caches regenerate; permanent removal frees the space.
                    try CleanupFileRemover.permanent(item.path, module: item.module)
                }
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

        return CleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
    }
}
