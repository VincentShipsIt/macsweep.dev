import Foundation
import AppKit

/// Module for privacy-related cleanup
struct PrivacyModule: ScanModule {
    let id = "privacy"
    let name = "Privacy"
    let description = "Clear browsing history, recent documents, and traces"
    let icon = "hand.raised"

    static let cleanupReviewReason =
        "Contains personal activity data. Review before clearing; MacSweep moves it to Trash."

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

    /// Builds a privacy finding with the evidence the review UI needs.
    ///
    /// Both file and directory scanners use this path so privacy artifacts
    /// consistently carry their modification date and explicit review-only
    /// rationale.
    func makeCleanupItem(
        at url: URL,
        size: Int64,
        type: CleanupItem.ItemType,
        moduleName: String
    ) -> CleanupItem {
        let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return CleanupItem(
            id: UUID(),
            path: url,
            size: size,
            type: type,
            module: id,
            moduleName: moduleName,
            lastModified: resourceValues?.contentModificationDate,
            cleanupReviewReason: Self.cleanupReviewReason
        )
    }

    /// Build a `CleanupItem` for a single privacy artifact file if it exists.
    /// Centralizes the exists → size → CleanupItem block the per-category scans
    /// repeated inline. `ScanModule.scanCacheDirectory` is deliberately not
    /// reused here: it sizes directories and drops zero-size results, while
    /// these single files must be listed even when empty.
    private func scanSingleFile(_ url: URL, moduleName: String) async -> CleanupItem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = (try? await DiskAnalyzer.size(of: url)) ?? 0
        return makeCleanupItem(
            at: url,
            size: size,
            type: .file,
            moduleName: moduleName
        )
    }

    // MARK: - Recent Documents

    private func scanRecentDocuments() async -> [CleanupItem] {
        var items: [CleanupItem] = []
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Recent documents plist
        let recentDocs = home
            .appending(
                path: "Library/Application Support/com.apple.sharedfilelist/"
                    + "com.apple.LSSharedFileList.RecentDocuments.sfl2"
            )
        if let item = await scanSingleFile(recentDocs, moduleName: "Recent Documents") {
            items.append(item)
        }

        // Recent applications
        let recentApps = home
            .appending(
                path: "Library/Application Support/com.apple.sharedfilelist/"
                    + "com.apple.LSSharedFileList.RecentApplications.sfl2"
            )
        if let item = await scanSingleFile(recentApps, moduleName: "Recent Applications") {
            items.append(item)
        }

        // Finder recents
        let finderRecents = home
            .appending(
                path: "Library/Application Support/com.apple.sharedfilelist/"
                    + "com.apple.LSSharedFileList.RecentHosts.sfl2"
            )
        if let item = await scanSingleFile(finderRecents, moduleName: "Recent Hosts") {
            items.append(item)
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

            items.append(makeCleanupItem(
                at: stateDir,
                size: size,
                type: .directory,
                moduleName: "Saved State - \(appName)"
            ))
        }

        return items
    }

    // MARK: - Recent Servers

    private func scanRecentServers() async -> [CleanupItem] {
        let recentServers = FileManager.default.homeDirectoryForCurrentUser
            .appending(
                path: "Library/Application Support/com.apple.sharedfilelist/"
                    + "com.apple.LSSharedFileList.RecentServers.sfl2"
            )

        guard let item = await scanSingleFile(recentServers, moduleName: "Recent Servers") else { return [] }
        return [item]
    }

    // MARK: - Downloads History

    private func scanDownloadsHistory() async -> [CleanupItem] {
        // Safari downloads plist
        let safariDownloads = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Safari/Downloads.plist")

        guard let item = await scanSingleFile(
            safariDownloads,
            moduleName: "Safari Downloads History"
        ) else { return [] }
        return [item]
    }

    // MARK: - Quarantine Events (GateKeeper history)

    private func scanQuarantineEvents() async -> [CleanupItem] {
        let quarantine = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2")

        guard let item = await scanSingleFile(
            quarantine,
            moduleName: "Download History (Quarantine)"
        ) else { return [] }
        return [item]
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
        await cleanItems(items, dryRun: dryRun) { item, _ in
            try CleanupFileRemover.recoverable(item.path, module: item.module)
        }
    }
}

/// Presentation-ready evidence for an individual Privacy result.
///
/// Keeping the fallback policy in Core makes the populated-results UI
/// deterministic and lets focused SwiftPM tests cover missing filesystem
/// metadata without instantiating a SwiftUI view.
struct PrivacyItemEvidence: Equatable, Sendable {
    enum Modification: Equatable, Sendable {
        case date(Date)
        case unavailable
    }

    let path: String
    let formattedSize: String
    let modification: Modification
    let reviewReason: String

    init(item: CleanupItem) {
        path = item.path.path
        formattedSize = item.formattedSize
        modification = item.lastModified.map(Modification.date) ?? .unavailable
        reviewReason = item.cleanupReviewReason ?? PrivacyModule.cleanupReviewReason
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

        if let error = errorInfo {
            throw PrivacyError.scriptFailed(error.description)
        }
    }

    /// Clear Terminal history
    static func clearTerminalHistory() async throws {
        let historyFiles = [
            ".bash_history",
            ".zsh_history",
            ".sh_history"
        ]

        let home = FileManager.default.homeDirectoryForCurrentUser

        // Attempt every history file, but surface the first failure instead of
        // swallowing it — a silent `try?` made a failed clear look successful.
        var firstError: Error?
        for file in historyFiles {
            let path = home.appending(path: file)
            if FileManager.default.fileExists(atPath: path.path) {
                do {
                    // Recoverable: shell history is not regenerable, so route
                    // through the Trash to make an accidental clear undoable.
                    try CleanupFileRemover.recoverable(path, module: "privacy")
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
        }
        if let firstError { throw firstError }
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
