import Foundation
import AppKit

/// Module for app uninstallation with leftover detection
struct AppUninstallerModule: ScanModule {
    let id = "app-uninstaller"
    let name = "App Uninstaller"
    let description = "Uninstall apps and remove leftover files"
    let icon = "xmark.app"

    func scan() async throws -> [CleanupItem] {
        // This module works differently - it returns apps, not cleanup items
        // Use AppDiscovery and LeftoverScanner instead
        return []
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        // Handled by uninstallApp method
        return CleanupResult(itemsProcessed: 0, bytesFreed: 0)
    }
}

// MARK: - Installed App Model

struct InstalledApp: Identifiable, Hashable {
    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    let id: String  // Bundle ID
    let name: String
    let bundlePath: URL
    let version: String?
    let bundleSize: Int64
    let icon: NSImage?
    let lastUsed: Date?

    var leftovers: [AppLeftover] = []

    var totalSize: Int64 {
        bundleSize + leftovers.reduce(0) { $0 + $1.size }
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    var formattedBundleSize: String {
        ByteCountFormatter.string(fromByteCount: bundleSize, countStyle: .file)
    }

    var leftoverSize: Int64 {
        leftovers.reduce(0) { $0 + $1.size }
    }

    var formattedLeftoverSize: String {
        ByteCountFormatter.string(fromByteCount: leftoverSize, countStyle: .file)
    }
}

struct AppLeftover: Identifiable {
    let id: UUID
    let path: URL
    let size: Int64
    let type: LeftoverType

    enum LeftoverType: String {
        case preferences = "Preferences"
        case applicationSupport = "App Support"
        case caches = "Caches"
        case logs = "Logs"
        case containers = "Containers"
        case savedState = "Saved State"
        case launchAgent = "Launch Agent"
        case other = "Other"
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

// MARK: - App Discovery

actor AppDiscovery {
    /// Find all installed applications
    func installedApps() async -> [InstalledApp] {
        let searchPaths = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")
        ]

        var apps: [InstalledApp] = []

        for searchPath in searchPaths {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: searchPath,
                includingPropertiesForKeys: nil
            ) else { continue }

            for url in contents {
                if url.pathExtension == "app" {
                    if let app = await parseAppBundle(at: url) {
                        apps.append(app)
                    }
                }
            }
        }

        return apps.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Parse app bundle metadata
    private func parseAppBundle(at url: URL) async -> InstalledApp? {
        guard let bundle = Bundle(url: url) else { return nil }

        let bundleID = bundle.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
        let name = (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String

        // Calculate bundle size
        let size = (try? await DiskAnalyzer.directorySize(at: url)) ?? 0

        // Get app icon
        let icon = NSWorkspace.shared.icon(forFile: url.path)

        // Get last used date (from Spotlight metadata)
        let lastUsed = await getLastUsedDate(for: bundleID)

        return InstalledApp(
            id: bundleID,
            name: name,
            bundlePath: url,
            version: version,
            bundleSize: size,
            icon: icon,
            lastUsed: lastUsed
        )
    }

    /// Get last used date from Spotlight
    private func getLastUsedDate(for bundleID: String) async -> Date? {
        // Use mdls to query Spotlight for last used date
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdls")
        process.arguments = ["-name", "kMDItemLastUsedDate", "-raw", "/Applications/\(bundleID).app"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  output != "(null)"
            else { return nil }

            // Parse date (format: 2024-01-15 10:30:00 +0000)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            return formatter.date(from: output)
        } catch {
            return nil
        }
    }
}

// MARK: - Leftover Scanner

actor LeftoverScanner {
    private let leftoverLocations: [(URL, AppLeftover.LeftoverType)] = [
        (URL.libraryDirectory.appending(path: "Preferences"), .preferences),
        (URL.libraryDirectory.appending(path: "Application Support"), .applicationSupport),
        (URL.libraryDirectory.appending(path: "Caches"), .caches),
        (URL.libraryDirectory.appending(path: "Logs"), .logs),
        (URL.libraryDirectory.appending(path: "Containers"), .containers),
        (URL.libraryDirectory.appending(path: "Saved Application State"), .savedState),
        (URL.libraryDirectory.appending(path: "LaunchAgents"), .launchAgent),
    ]

    /// Find leftovers for a specific app
    func findLeftovers(for app: InstalledApp) async -> [AppLeftover] {
        var leftovers: [AppLeftover] = []

        for (baseURL, type) in leftoverLocations {
            let found = await scanForAppData(in: baseURL, matching: app.id, appName: app.name, type: type)
            leftovers.append(contentsOf: found)
        }

        return leftovers
    }

    /// Find orphaned leftovers (no matching app installed)
    func findOrphanedLeftovers(installedBundleIDs: Set<String>) async -> [AppLeftover] {
        var orphans: [AppLeftover] = []

        for (baseURL, type) in leftoverLocations {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: baseURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }

            for item in contents {
                // Skip if matches an installed app
                let itemName = item.lastPathComponent.lowercased()
                let matchesInstalled = installedBundleIDs.contains { bundleID in
                    itemName.contains(bundleID.lowercased()) ||
                    bundleID.lowercased().contains(itemName.replacingOccurrences(of: ".plist", with: ""))
                }

                if matchesInstalled { continue }

                // Check if it looks like app data
                if looksLikeAppData(item) {
                    let size = (try? await DiskAnalyzer.size(of: item)) ?? 0
                    guard size > 1024 else { continue }  // Skip tiny items

                    orphans.append(AppLeftover(
                        id: UUID(),
                        path: item,
                        size: size,
                        type: type
                    ))
                }
            }
        }

        return orphans
    }

    private func scanForAppData(in baseURL: URL, matching bundleID: String, appName: String, type: AppLeftover.LeftoverType) async -> [AppLeftover] {
        var found: [AppLeftover] = []

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil
        ) else { return [] }

        let searchTerms = [
            bundleID,
            bundleID.lowercased(),
            appName,
            appName.lowercased(),
            appName.replacingOccurrences(of: " ", with: ""),
        ]

        for item in contents {
            let itemName = item.lastPathComponent

            // Check if item name matches app
            let matches = searchTerms.contains { term in
                itemName.localizedCaseInsensitiveContains(term) ||
                term.localizedCaseInsensitiveContains(itemName.replacingOccurrences(of: ".plist", with: ""))
            }

            if matches {
                let size = (try? await DiskAnalyzer.size(of: item)) ?? 0
                guard size > 0 else { continue }

                found.append(AppLeftover(
                    id: UUID(),
                    path: item,
                    size: size,
                    type: type
                ))
            }
        }

        return found
    }

    private func looksLikeAppData(_ url: URL) -> Bool {
        let name = url.lastPathComponent

        // Check for common app data patterns
        if name.contains(".") && name.split(separator: ".").count >= 2 {
            // Looks like a bundle ID (com.company.app)
            return true
        }

        if name.hasSuffix(".plist") || name.hasSuffix(".savedState") {
            return true
        }

        return false
    }
}

// MARK: - App Uninstaller

struct AppUninstaller {
    /// Uninstall an app and optionally its leftovers
    func uninstall(_ app: InstalledApp, includeLeftovers: Bool = true) async throws -> CleanupResult {
        // Check if app is running
        let runningApps = NSWorkspace.shared.runningApplications
        if runningApps.contains(where: { $0.bundleIdentifier == app.id }) {
            throw UninstallError.appRunning(app.name)
        }

        var processedCount = 0
        var bytesFreed: Int64 = 0
        var errors: [CleanupError] = []

        // Move app to trash
        do {
            try FileManager.default.trashItem(at: app.bundlePath, resultingItemURL: nil)
            processedCount += 1
            bytesFreed += app.bundleSize
        } catch {
            throw UninstallError.cannotRemoveApp(app.name, error)
        }

        // Remove leftovers if requested
        if includeLeftovers {
            for leftover in app.leftovers {
                do {
                    try FileManager.default.trashItem(at: leftover.path, resultingItemURL: nil)
                    processedCount += 1
                    bytesFreed += leftover.size
                } catch {
                    errors.append(CleanupError(
                        path: leftover.path,
                        message: "Could not remove leftover",
                        underlyingError: error
                    ))
                }
            }
        }

        return CleanupResult(itemsProcessed: processedCount, bytesFreed: bytesFreed, errors: errors)
    }
}

enum UninstallError: LocalizedError {
    case appRunning(String)
    case cannotRemoveApp(String, Error)

    var errorDescription: String? {
        switch self {
        case .appRunning(let name):
            return "Please quit \(name) before uninstalling"
        case .cannotRemoveApp(let name, let error):
            return "Could not uninstall \(name): \(error.localizedDescription)"
        }
    }
}
