import Foundation
import AppKit

/// Module for managing and emptying trash bins
struct TrashBinsModule: ScanModule {
    let id = "trash-bins"
    let name = "Trash Bins"
    let description = "Empty system and volume trash bins"
    let icon = "trash"

    func scan() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []

        // User's main Trash
        let userTrash = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
        if let trashItems = await scanTrashBin(at: userTrash, name: "User Trash") {
            items.append(contentsOf: trashItems)
        }

        // Volume trash bins (external drives, etc.)
        let volumeTrashItems = await scanVolumeTrashBins()
        items.append(contentsOf: volumeTrashItems)

        return items.sorted { $0.size > $1.size }
    }

    private func scanTrashBin(at url: URL, name: String) async -> [CleanupItem]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var items: [CleanupItem] = []

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for itemURL in contents {
            let size = (try? await DiskAnalyzer.size(of: itemURL)) ?? 0
            let values = try? itemURL.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])

            items.append(CleanupItem(
                id: UUID(),
                path: itemURL,
                size: size,
                type: values?.isDirectory == true ? .directory : .file,
                module: id,
                moduleName: name,
                lastModified: values?.contentModificationDate
            ))
        }

        return items
    }

    private func scanVolumeTrashBins() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        // Get mounted volumes
        let volumeURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeIsRemovableKey],
            options: [.skipHiddenVolumes]
        ) ?? []

        for volumeURL in volumeURLs {
            // Skip the boot volume (already covered by user trash)
            if volumeURL.path == "/" { continue }

            // Check for .Trashes directory on volume
            let trashPath = volumeURL.appending(path: ".Trashes")
            guard FileManager.default.fileExists(atPath: trashPath.path) else { continue }

            // Get volume name
            let volumeName = (try? volumeURL.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? volumeURL.lastPathComponent

            // Look for user-specific trash folder (named by UID)
            let uid = getuid()
            let userTrashPath = trashPath.appending(path: "\(uid)")

            if let trashItems = await scanTrashBin(at: userTrashPath, name: "\(volumeName) Trash") {
                items.append(contentsOf: trashItems)
            }
        }

        return items
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
                    try FileManager.default.removeItem(at: item.path)
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

    /// Empty all trash bins using Finder (safer, handles protected items)
    func emptyAllTrash() async throws {
        // Use AppleScript to empty trash via Finder
        let script = """
        tell application "Finder"
            empty trash
        end tell
        """

        let appleScript = NSAppleScript(source: script)
        var errorInfo: NSDictionary?
        appleScript?.executeAndReturnError(&errorInfo)

        if let error = errorInfo {
            throw TrashError.emptyFailed(error.description)
        }
    }
}

// MARK: - Trash Summary

struct TrashSummary {
    let userTrashSize: Int64
    let userTrashCount: Int
    let volumeTrashSize: Int64
    let volumeTrashCount: Int

    var totalSize: Int64 { userTrashSize + volumeTrashSize }
    var totalCount: Int { userTrashCount + volumeTrashCount }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    static func current() async -> TrashSummary {
        let userTrash = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")

        var userSize: Int64 = 0
        var userCount = 0

        if let contents = try? FileManager.default.contentsOfDirectory(atPath: userTrash.path) {
            userCount = contents.count
            userSize = (try? await DiskAnalyzer.directorySize(at: userTrash)) ?? 0
        }

        // TODO: Count volume trash

        return TrashSummary(
            userTrashSize: userSize,
            userTrashCount: userCount,
            volumeTrashSize: 0,
            volumeTrashCount: 0
        )
    }
}

enum TrashError: LocalizedError {
    case emptyFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyFailed(let reason):
            return "Failed to empty trash: \(reason)"
        }
    }
}
