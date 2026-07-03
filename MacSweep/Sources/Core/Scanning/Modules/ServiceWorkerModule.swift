import Foundation
import AppKit

/// Module for cleaning service workers from Electron-based apps
struct ServiceWorkerModule: ScanModule {
    let id = "service-workers"
    let name = "App Service Workers"
    let description = "Service workers from Electron apps (Slack, Discord, VS Code, etc.)"
    let icon = "app.badge.checkmark"

    /// Known Electron apps and their service worker locations
    static let electronApps: [(name: String, path: String, bundleID: String)] = [
        // Communication
        ("Slack", "~/Library/Application Support/Slack/Service Worker", "com.tinyspeck.slackmacgap"),
        ("Discord", "~/Library/Application Support/discord/Service Worker", "com.hnc.Discord"),
        ("Microsoft Teams", "~/Library/Application Support/Microsoft/Teams/Service Worker", "com.microsoft.teams"),
        ("Zoom", "~/Library/Application Support/zoom.us/data/Service Worker", "us.zoom.xos"),
        ("WhatsApp", "~/Library/Application Support/WhatsApp/Service Worker", "net.whatsapp.WhatsApp"),
        ("Telegram", "~/Library/Application Support/Telegram Desktop/Service Worker", "ru.keepcoder.Telegram"),
        ("Signal", "~/Library/Application Support/Signal/Service Worker", "org.whispersystems.signal-desktop"),

        // Development
        ("VS Code", "~/Library/Application Support/Code/Service Worker", "com.microsoft.VSCode"),
        ("VS Code Insiders", "~/Library/Application Support/Code - Insiders/Service Worker", "com.microsoft.VSCodeInsiders"),
        ("Cursor", "~/Library/Application Support/Cursor/Service Worker", "com.todesktop.230313mzl4w4u92"),
        ("Atom", "~/Library/Application Support/Atom/Service Worker", "com.github.atom"),
        ("Postman", "~/Library/Application Support/Postman/Service Worker", "com.postmanlabs.mac"),
        ("Insomnia", "~/Library/Application Support/Insomnia/Service Worker", "com.insomnia.app"),
        ("GitHub Desktop", "~/Library/Application Support/GitHub Desktop/Service Worker", "com.github.GitHubClient"),
        ("GitKraken", "~/Library/Application Support/GitKraken/Service Worker", "com.axosoft.gitkraken"),

        // Productivity
        ("Notion", "~/Library/Application Support/Notion/Service Worker", "notion.id"),
        ("Obsidian", "~/Library/Application Support/obsidian/Service Worker", "md.obsidian"),
        ("Todoist", "~/Library/Application Support/Todoist/Service Worker", "com.todoist.mac.Todoist"),
        ("Evernote", "~/Library/Application Support/Evernote/Service Worker", "com.evernote.Evernote"),
        ("Trello", "~/Library/Application Support/Trello/Service Worker", "com.trello.desktop"),
        ("Asana", "~/Library/Application Support/Asana/Service Worker", "com.asana.app"),
        ("Linear", "~/Library/Application Support/Linear/Service Worker", "com.linear"),
        ("ClickUp", "~/Library/Application Support/ClickUp/Service Worker", "com.clickup.desktop-app"),

        // Media
        ("Spotify", "~/Library/Application Support/Spotify/Service Worker", "com.spotify.client"),
        ("Figma", "~/Library/Application Support/Figma/Service Worker", "com.figma.Desktop"),
        ("Framer", "~/Library/Application Support/Framer/Service Worker", "com.framer.desktop"),
        ("Loom", "~/Library/Application Support/Loom/Service Worker", "com.loom.desktop"),
        ("Miro", "~/Library/Application Support/Miro/Service Worker", "com.realtimeboard.miro"),

        // Other
        ("1Password", "~/Library/Application Support/1Password/Service Worker", "com.1password.1password"),
        ("Bitwarden", "~/Library/Application Support/Bitwarden/Service Worker", "com.bitwarden.desktop"),
        ("Keybase", "~/Library/Application Support/Keybase/Service Worker", "keybase.Keybase"),
        ("Franz", "~/Library/Application Support/Franz/Service Worker", "com.meetfranz.Franz"),
        ("Rambox", "~/Library/Application Support/Rambox/Service Worker", "com.rambox.app"),
    ]

    func scan() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []

        for app in Self.electronApps {
            let expandedPath = app.path.expandingTilde
            let url = URL(fileURLWithPath: expandedPath)

            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            do {
                let size = try await DiskAnalyzer.directorySize(at: url)
                guard size > 1024 else { continue }  // Skip tiny items

                items.append(CleanupItem(
                    id: UUID(),
                    path: url,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "\(app.name) Service Worker",
                    lastModified: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                ))
            } catch {
                continue
            }
        }

        // Also scan for unknown Electron apps
        let additionalItems = await scanUnknownElectronApps()
        items.append(contentsOf: additionalItems)

        return items.sorted { $0.size > $1.size }
    }

    /// Scan Application Support for any other Service Worker directories
    private func scanUnknownElectronApps() async -> [CleanupItem] {
        var items: [CleanupItem] = []
        let knownPaths = Set(Self.electronApps.map { $0.path.expandingTilde })

        let appSupportURL = URL.libraryDirectory.appending(path: "Application Support")

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: appSupportURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        for appDir in contents {
            let serviceWorkerPath = appDir.appending(path: "Service Worker")

            // Skip if we already know about this app
            if knownPaths.contains(serviceWorkerPath.path) { continue }

            guard FileManager.default.fileExists(atPath: serviceWorkerPath.path) else { continue }

            do {
                let size = try await DiskAnalyzer.directorySize(at: serviceWorkerPath)
                guard size > 10240 else { continue }  // Skip very small ones

                let appName = appDir.lastPathComponent

                items.append(CleanupItem(
                    id: UUID(),
                    path: serviceWorkerPath,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "\(appName) Service Worker",
                    lastModified: nil
                ))
            } catch {
                continue
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

                // Check if the app is running
                let appName = item.moduleName.replacingOccurrences(of: " Service Worker", with: "")
                if let app = Self.electronApps.first(where: { $0.name == appName }) {
                    let runningApps = NSWorkspace.shared.runningApplications
                    if runningApps.contains(where: { $0.bundleIdentifier == app.bundleID }) {
                        errors.append(CleanupError(
                            path: item.path,
                            message: "Please quit \(appName) first"
                        ))
                        continue
                    }
                }

                do {
                    let contents = try FileManager.default.contentsOfDirectory(
                        at: item.path,
                        includingPropertiesForKeys: nil
                    )
                    for content in contents {
                        try CleanupFileRemover.recoverable(content, module: item.module)
                    }
                    processed += 1
                    freed += item.size
                } catch {
                    errors.append(CleanupError(
                        path: item.path,
                        message: error.localizedDescription
                    ))
                }
            }
        }

        return CleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
    }
}
