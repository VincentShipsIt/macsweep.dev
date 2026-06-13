import Foundation

struct AssistantWatchlistModule: ScanModule {
    static let moduleID = "assistant-watchlist"

    let id = Self.moduleID
    let name = "Assistant Watchlists"
    let description = "Assistant-managed scan targets and persistent watchlists"
    let icon = "bubble.left.and.sparkles"

    private let targets: [AssistantScanTarget]
    private let checker = SafetyChecker()

    init(targets: [AssistantScanTarget] = []) {
        self.targets = targets
    }

    func scan() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []

        for target in targets {
            let expandedTarget = expand(path: target.path)
            guard FileManager.default.fileExists(atPath: expandedTarget.path) else { continue }

            let excludedRoots = Set(target.excludePaths.map { expand(path: $0).path })
            let targetItems = await scanTarget(
                expandedTarget,
                label: target.label,
                excludedRoots: excludedRoots
            )
            items.append(contentsOf: targetItems)
        }

        return items.sorted { $0.size > $1.size }
    }

    private func scanTarget(
        _ rootURL: URL,
        label: String,
        excludedRoots: Set<String>
    ) async -> [CleanupItem] {
        guard !excludedRoots.contains(where: { rootURL.path.hasPrefix($0) }) else {
            return []
        }

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .contentModificationDateKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
        ]

        do {
            let values = try rootURL.resourceValues(forKeys: resourceKeys)
            if values.isDirectory == true {
                let children = try FileManager.default.contentsOfDirectory(
                    at: rootURL,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: [.skipsHiddenFiles]
                )

                if children.isEmpty {
                    // Watchlist targets are arbitrary agent-supplied paths, so the
                    // default-deny safety gate is the backstop against a target
                    // pointing at ~/Documents, ~/.ssh, or any other protected root.
                    guard checker.validateForScan(rootURL, moduleID: id).isSafe else { return [] }
                    let size = try await DiskAnalyzer.directorySize(at: rootURL)
                    return size > 1024 ? [makeItem(url: rootURL, label: label, size: size, lastModified: values.contentModificationDate)] : []
                }

                var items: [CleanupItem] = []
                for child in children where !excludedRoots.contains(where: { child.path.hasPrefix($0) }) {
                    guard checker.validateForScan(child, moduleID: id).isSafe else { continue }
                    do {
                        let childValues = try child.resourceValues(forKeys: resourceKeys)
                        let size: Int64
                        if childValues.isDirectory == true {
                            size = try await DiskAnalyzer.directorySize(at: child)
                        } else {
                            size = Int64(childValues.totalFileAllocatedSize ?? childValues.fileSize ?? 0)
                        }

                        guard size > 1024 else { continue }
                        items.append(makeItem(url: child, label: label, size: size, lastModified: childValues.contentModificationDate))
                    } catch {
                        continue
                    }
                }

                return items
            }

            guard checker.validateForScan(rootURL, moduleID: id).isSafe else { return [] }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            guard size > 1024 else { return [] }
            return [makeItem(url: rootURL, label: label, size: size, lastModified: values.contentModificationDate)]
        } catch {
            return []
        }
    }

    private func makeItem(url: URL, label: String, size: Int64, lastModified: Date?) -> CleanupItem {
        CleanupItem(
            id: UUID(),
            path: url,
            size: size,
            type: directoryType(for: url),
            module: id,
            moduleName: "\(name) - \(label)",
            lastModified: lastModified
        )
    }

    private func directoryType(for url: URL) -> CleanupItem.ItemType {
        ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) ? .directory : .file
    }

    private func expand(path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        var processedCount = 0
        var bytesFreed: Int64 = 0
        var errors: [CleanupError] = []

        for item in items where item.module == id {
            if dryRun {
                processedCount += 1
                bytesFreed += item.size
                continue
            }

            // Re-validate at cleanup time: the watchlist holds arbitrary paths,
            // so nothing is deleted unless it still passes the default-deny gate.
            guard checker.validateForCleanup(item.path, moduleID: id, itemType: item.type).isSafe else {
                errors.append(CleanupError(
                    path: item.path,
                    message: "Blocked by safety checks"
                ))
                continue
            }

            do {
                if item.type == .directory {
                    let contents = try FileManager.default.contentsOfDirectory(at: item.path, includingPropertiesForKeys: nil)
                    for content in contents {
                        try CleanupFileRemover.recoverable(content)
                    }
                } else {
                    try CleanupFileRemover.recoverable(item.path)
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

        return CleanupResult(itemsProcessed: processedCount, bytesFreed: bytesFreed, errors: errors)
    }
}
