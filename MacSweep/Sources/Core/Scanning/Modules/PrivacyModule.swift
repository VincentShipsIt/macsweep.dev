import Foundation
import AppKit

/// Module for privacy-related cleanup
struct PrivacyModule: ScanModule {
    let id = "privacy"
    let name = "Privacy"
    let description = "Clear browsing history, recent documents, and traces"
    let icon = "hand.raised"

    func scan() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []

        // Scan all privacy categories
        items.append(contentsOf: await scanRecentDocuments())
        items.append(contentsOf: await scanSavedApplicationState())
        items.append(contentsOf: await scanRecentServers())
        items.append(contentsOf: await scanDownloadsHistory())
        items.append(contentsOf: await scanQuarantineEvents())
        items.append(contentsOf: await scanRecentPlaces())

        return items.sorted { $0.size > $1.size }
    }

    // MARK: - Recent Documents

    private func scanRecentDocuments() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        // Recent documents plist
        let recentDocs = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentDocuments.sfl2")

        if FileManager.default.fileExists(atPath: recentDocs.path) {
            let size = (try? await DiskAnalyzer.size(of: recentDocs)) ?? 0
            items.append(CleanupItem(
                id: UUID(),
                path: recentDocs,
                size: size,
                type: .file,
                module: id,
                moduleName: "Recent Documents"
            ))
        }

        // Recent applications
        let recentApps = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentApplications.sfl2")

        if FileManager.default.fileExists(atPath: recentApps.path) {
            let size = (try? await DiskAnalyzer.size(of: recentApps)) ?? 0
            items.append(CleanupItem(
                id: UUID(),
                path: recentApps,
                size: size,
                type: .file,
                module: id,
                moduleName: "Recent Applications"
            ))
        }

        // Finder recents
        let finderRecents = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentHosts.sfl2")

        if FileManager.default.fileExists(atPath: finderRecents.path) {
            let size = (try? await DiskAnalyzer.size(of: finderRecents)) ?? 0
            items.append(CleanupItem(
                id: UUID(),
                path: finderRecents,
                size: size,
                type: .file,
                module: id,
                moduleName: "Recent Hosts"
            ))
        }

        return items
    }

    // MARK: - Saved Application State

    private func scanSavedApplicationState() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        let savedStateDir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Saved Application State")

        guard FileManager.default.fileExists(atPath: savedStateDir.path) else { return [] }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: savedStateDir,
            includingPropertiesForKeys: nil
        ) else { return [] }

        for stateDir in contents {
            let size = (try? await DiskAnalyzer.directorySize(at: stateDir)) ?? 0
            guard size > 1024 else { continue }  // Skip tiny items

            let appName = stateDir.lastPathComponent.replacingOccurrences(of: ".savedState", with: "")

            items.append(CleanupItem(
                id: UUID(),
                path: stateDir,
                size: size,
                type: .directory,
                module: id,
                moduleName: "Saved State - \(appName)"
            ))
        }

        return items
    }

    // MARK: - Recent Servers

    private func scanRecentServers() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        let recentServers = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.RecentServers.sfl2")

        if FileManager.default.fileExists(atPath: recentServers.path) {
            let size = (try? await DiskAnalyzer.size(of: recentServers)) ?? 0
            items.append(CleanupItem(
                id: UUID(),
                path: recentServers,
                size: size,
                type: .file,
                module: id,
                moduleName: "Recent Servers"
            ))
        }

        return items
    }

    // MARK: - Downloads History

    private func scanDownloadsHistory() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        // Safari downloads plist
        let safariDownloads = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Safari/Downloads.plist")

        if FileManager.default.fileExists(atPath: safariDownloads.path) {
            let size = (try? await DiskAnalyzer.size(of: safariDownloads)) ?? 0
            items.append(CleanupItem(
                id: UUID(),
                path: safariDownloads,
                size: size,
                type: .file,
                module: id,
                moduleName: "Safari Downloads History"
            ))
        }

        return items
    }

    // MARK: - Quarantine Events (GateKeeper history)

    private func scanQuarantineEvents() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        let quarantine = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2")

        if FileManager.default.fileExists(atPath: quarantine.path) {
            let size = (try? await DiskAnalyzer.size(of: quarantine)) ?? 0
            items.append(CleanupItem(
                id: UUID(),
                path: quarantine,
                size: size,
                type: .file,
                module: id,
                moduleName: "Download History (Quarantine)"
            ))
        }

        return items
    }

    // MARK: - Recent Places (Finder sidebar)

    private func scanRecentPlaces() async -> [CleanupItem] {
        // Intentionally returns nothing. Finder "Favorites" / recent places live in
        // ~/Library/Application Support/com.apple.sharedfilelist/...FavoriteItems.sfl2,
        // but those are user-curated bookmarks, not reclaimable cruft — we never
        // propose deleting them. Kept as a named no-op so the scan surface stays
        // explicit and future informational-only reporting has a home.
        return []
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
                    try CleanupFileRemover.recoverable(item.path)
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

// MARK: - Privacy Actions (System-level)

struct PrivacyActions {
    /// Clear recent documents from Finder
    static func clearRecentDocuments() async throws {
        let script = """
        tell application "System Events"
            tell appearance preferences
                set recent documents limit to 0
            end tell
        end tell
        """

        let appleScript = NSAppleScript(source: script)
        var errorInfo: NSDictionary?
        appleScript?.executeAndReturnError(&errorInfo)

        if let error = errorInfo {
            throw PrivacyError.scriptFailed(error.description)
        }
    }

    /// Clear recent applications
    static func clearRecentApplications() async throws {
        let script = """
        tell application "System Events"
            tell appearance preferences
                set recent applications limit to 0
            end tell
        end tell
        """

        let appleScript = NSAppleScript(source: script)
        var errorInfo: NSDictionary?
        appleScript?.executeAndReturnError(&errorInfo)
    }

    /// Clear Terminal history
    static func clearTerminalHistory() async throws {
        let historyFiles = [
            ".bash_history",
            ".zsh_history",
            ".sh_history"
        ]

        let home = FileManager.default.homeDirectoryForCurrentUser

        for file in historyFiles {
            let path = home.appending(path: file)
            if FileManager.default.fileExists(atPath: path.path) {
                // Recoverable: shell history is not regenerable, so route through
                // the Trash to make an accidental clear undoable.
                try? CleanupFileRemover.recoverable(path)
            }
        }
    }

    /// Clear clipboard
    static func clearClipboard() {
        NSPasteboard.general.clearContents()
    }
}

enum PrivacyError: LocalizedError {
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let reason):
            return "Privacy action failed: \(reason)"
        }
    }
}

// MARK: - Privacy Categories for UI

enum PrivacyCategory: String, CaseIterable, Identifiable {
    case recentDocuments = "Recent Documents"
    case recentApplications = "Recent Applications"
    case savedState = "Saved Application State"
    case downloadHistory = "Download History"
    case recentServers = "Recent Servers"
    case terminalHistory = "Terminal History"
    case clipboard = "Clipboard"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .recentDocuments: return "doc.text"
        case .recentApplications: return "app.badge"
        case .savedState: return "square.stack.3d.up"
        case .downloadHistory: return "arrow.down.circle"
        case .recentServers: return "server.rack"
        case .terminalHistory: return "terminal"
        case .clipboard: return "doc.on.clipboard"
        }
    }

    var description: String {
        switch self {
        case .recentDocuments:
            return "List of recently opened files in Finder and apps"
        case .recentApplications:
            return "List of recently launched applications"
        case .savedState:
            return "Window positions and document state for apps"
        case .downloadHistory:
            return "Record of downloaded files and their sources"
        case .recentServers:
            return "Recently connected network servers"
        case .terminalHistory:
            return "Command history from Terminal/shell"
        case .clipboard:
            return "Current clipboard contents"
        }
    }
}
