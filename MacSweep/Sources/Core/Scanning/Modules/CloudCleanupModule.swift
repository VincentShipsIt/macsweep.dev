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

                let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
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
        let roots = [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/CloudKit"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/CloudDocs"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/Dropbox"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Dropbox"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/CloudStorage/Dropbox"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/CloudStorage/GoogleDrive"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/CloudStorage/OneDrive-Personal"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/CloudStorage/OneDrive"),
        ]

        var items: [CleanupItem] = []
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
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

        for item in items where item.module == id {
            if dryRun {
                processed += 1
                freed += item.size
                continue
            }

            do {
                if item.moduleName.contains("Local Copy") {
                    try FileManager.default.evictUbiquitousItem(at: item.path)
                } else {
                    try FileManager.default.trashItem(at: item.path, resultingItemURL: nil)
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
