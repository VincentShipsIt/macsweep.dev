import Foundation
import AppKit

extension DateFormatter {
    /// A `DateFormatter` pinned to `en_US_POSIX` for parsing the fixed-format
    /// timestamps emitted by shell tools (`mdls`, `git`, …). The POSIX locale is
    /// mandatory: without it, a user on a 12-hour or non-Gregorian locale fails
    /// to parse 24-hour format strings like `yyyy-MM-dd HH:mm:ss Z`.
    static func posixShellDate(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}

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
        totalSize.formattedFileSize
    }

    var formattedBundleSize: String {
        bundleSize.formattedFileSize
    }

    var leftoverSize: Int64 {
        leftovers.reduce(0) { $0 + $1.size }
    }

    var formattedLeftoverSize: String {
        leftoverSize.formattedFileSize
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
        size.formattedFileSize
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
        let lastUsed = await getLastUsedDate(at: url)

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
    private func getLastUsedDate(at bundleURL: URL) async -> Date? {
        // Query the actual bundle path. The previous code rebuilt the path as
        // "/Applications/<bundleID>.app" — but the on-disk name is the display
        // name ("Google Chrome.app"), not the bundle ID ("com.google.Chrome"),
        // and ~/Applications apps aren't under /Applications at all. So mdls
        // always hit a non-existent path and last-used was perpetually nil.
        // mdls blocks ~50-200ms per app. Run it on a detached task so it doesn't
        // pin a cooperative-pool thread for every app in a sequential scan.
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/usr/bin/mdls")
                process.arguments = ["-name", "kMDItemLastUsedDate", "-raw", bundleURL.path]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          output != "(null)"
                    else {
                        continuation.resume(returning: nil)
                        return
                    }

                    // Parse date (format: 2024-01-15 10:30:00 +0000). The POSIX
                    // locale is required: on a 12-hour or non-Gregorian user
                    // locale a plain DateFormatter fails to parse this 24-hour
                    // format and "last used" silently reads back nil.
                    let formatter = DateFormatter.posixShellDate(format: "yyyy-MM-dd HH:mm:ss Z")
                    continuation.resume(returning: formatter.date(from: output))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Leftover Scanner

actor LeftoverScanner {
    private let leftoverLocations: [(URL, AppLeftover.LeftoverType)]

    /// `leftoverLocations` is injectable so tests can point the scanner at a
    /// fixture Library tree; production callers use the real user Library.
    init(leftoverLocations: [(URL, AppLeftover.LeftoverType)]? = nil) {
        self.leftoverLocations = leftoverLocations ?? Self.defaultLeftoverLocations
    }

    private static let defaultLeftoverLocations: [(URL, AppLeftover.LeftoverType)] = [
        (URL.libraryDirectory.appending(path: "Preferences"), .preferences),
        (URL.libraryDirectory.appending(path: "Application Support"), .applicationSupport),
        (URL.libraryDirectory.appending(path: "Caches"), .caches),
        (URL.libraryDirectory.appending(path: "Logs"), .logs),
        (URL.libraryDirectory.appending(path: "Containers"), .containers),
        (URL.libraryDirectory.appending(path: "Saved Application State"), .savedState),
        (URL.libraryDirectory.appending(path: "LaunchAgents"), .launchAgent),
    ]

    /// Find leftovers for a specific app
    /// `installedApps` lets matching distinguish an app's helper data from
    /// data owned by another installed app whose bundle identifier extends the
    /// candidate's identifier (for example, `.canary` or `.beta`).
    func findLeftovers(for app: InstalledApp, among installedApps: [InstalledApp]) async -> [AppLeftover] {
        var leftovers: [AppLeftover] = []

        for (baseURL, type) in leftoverLocations {
            let found = await scanForAppData(
                in: baseURL,
                matching: app.id,
                appName: app.name,
                installedApps: installedApps,
                type: type
            )
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

    private func scanForAppData(
        in baseURL: URL,
        matching bundleID: String,
        appName: String,
        installedApps: [InstalledApp],
        type: AppLeftover.LeftoverType
    ) async -> [AppLeftover] {
        var found: [AppLeftover] = []

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: nil
        ) else { return [] }

        for item in contents {
            guard Self.leftoverMatches(
                itemName: item.lastPathComponent,
                bundleID: bundleID,
                appName: appName,
                installedApps: installedApps,
                type: type
            ) else {
                continue
            }
            let size = (try? await DiskAnalyzer.size(of: item)) ?? 0
            guard size > 0 else { continue }

            found.append(AppLeftover(
                id: UUID(),
                path: item,
                size: size,
                type: type
            ))
        }

        return found
    }

    /// Whether a Library item named `itemName` belongs to the app identified by
    /// `bundleID` / `appName`, for uninstaller leftover removal.
    ///
    /// The bundle ID is the reliable key: leftovers are named exactly after it
    /// (`com.foo.App.plist`) or carry it as a dotted prefix (`com.foo.App.savedState`,
    /// container dirs `com.foo.App`). When several installed IDs match such a
    /// prefix, exactly one app with the longest ID owns the item. This preserves
    /// unambiguous helper data while refusing to attribute an installed
    /// canary/beta app's data to its stable app. A Preferences `.plist` name is
    /// evaluated both as its raw name and as a filename with an extension; when
    /// those candidates have different owners, no app claims it. Other roots
    /// use the raw name because `.plist` can be part of an exact bundle ID.
    /// App-name matching is an exact space- and case-folded fallback, and is
    /// refused when another installed app has the same name.
    nonisolated static func leftoverMatches(
        itemName: String,
        bundleID: String,
        appName: String,
        installedApps: [InstalledApp],
        type: AppLeftover.LeftoverType = .applicationSupport
    ) -> Bool {
        let itemLower = itemName.lowercased()
        let bundleLower = bundleID.lowercased()
        let bundleCandidates: [String]
        if type == .preferences, itemLower.hasSuffix(".plist") {
            bundleCandidates = [itemLower, String(itemLower.dropLast(6))]
        } else {
            bundleCandidates = [itemLower]
        }

        let bundleOwners = bundleCandidates.compactMap { candidate in
            uniqueBundleOwner(for: candidate, installedApps: installedApps)
        }
        if !bundleOwners.isEmpty {
            // Every interpretation must resolve and agree. A raw preference
            // name can also be a valid installed bundle ID ending in `.plist`;
            // selecting either app in that case could delete the other's data.
            guard bundleOwners.count == bundleCandidates.count,
                  Set(bundleOwners).count == 1
            else {
                return false
            }
            return bundleOwners[0] == bundleLower
        }

        let appCompact = appName.lowercased().replacingOccurrences(of: " ", with: "")
        guard !appCompact.isEmpty else {
            return false
        }

        var appNameOwners: [String] = []
        for candidate in bundleCandidates {
            let matchingApps = installedApps.filter {
                $0.name.lowercased().replacingOccurrences(of: " ", with: "")
                    == candidate.replacingOccurrences(of: " ", with: "")
            }
            // A duplicate exact app name is as unsafe as a conflicting bundle
            // match, even if the other candidate has no app-name match.
            guard matchingApps.count <= 1 else {
                return false
            }
            if let app = matchingApps.first {
                appNameOwners.append(app.id.lowercased())
            }
        }
        return Set(appNameOwners).count == 1 && appNameOwners[0] == bundleLower
    }

    /// Returns an owner only when one installed app has the unique longest
    /// bundle-ID match for `candidate`; duplicate IDs remain unclaimed.
    nonisolated private static func uniqueBundleOwner(
        for candidate: String,
        installedApps: [InstalledApp]
    ) -> String? {
        let matchingApps = installedApps.filter { installedApp in
            let installedID = installedApp.id.lowercased()
            return !installedID.isEmpty && (candidate == installedID || candidate.hasPrefix(installedID + "."))
        }
        guard let longestBundleIDLength = matchingApps.map({ $0.id.count }).max() else {
            return nil
        }
        let mostSpecificOwners = matchingApps.filter { $0.id.count == longestBundleIDLength }
        guard mostSpecificOwners.count == 1 else {
            return nil
        }
        return mostSpecificOwners[0].id.lowercased()
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
    /// Running-app check; injected so tests can exercise the guard
    /// deterministically instead of depending on what the host is running.
    var isAppRunning: (InstalledApp) -> Bool = { app in
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == app.id }
    }

    /// Disposal hook; production moves items to the Trash. Injected so tests can
    /// verify the guard/accounting paths without writing to the user's Trash.
    var trashItem: (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }

    /// Uninstall an app and optionally its leftovers
    func uninstall(_ app: InstalledApp, includeLeftovers: Bool = true) async throws -> CleanupResult {
        // Check if app is running
        if isAppRunning(app) {
            throw UninstallError.appRunning(app.name)
        }

        // Check if app is in system Applications (requires elevated privileges)
        let systemAppsPath = "/Applications"
        if app.bundlePath.path.hasPrefix(systemAppsPath) {
            // Check if we can write to this location
            if !FileManager.default.isWritableFile(atPath: app.bundlePath.path) {
                throw UninstallError.insufficientPermissions(app.name)
            }
        }

        var processedCount = 0
        var bytesFreed: Int64 = 0
        var errors: [CleanupError] = []

        let safety = SafetyChecker()

        // Gate the bundle removal: confirm it really is a `.app` in a known
        // Applications root and isn't a symlink/relocated path that would
        // redirect the trash to an unintended target (#81).
        guard safety.validateForAppBundleRemoval(app.bundlePath).isSafe else {
            throw UninstallError.blockedBySafety(app.name)
        }

        // Move app to trash
        do {
            try trashItem(app.bundlePath)
            processedCount += 1
            bytesFreed += app.bundleSize
        } catch {
            throw UninstallError.cannotRemoveApp(app.name, error)
        }

        // Remove leftovers if requested. Every leftover passes the dedicated
        // uninstall-leftover gate first — it admits only direct children of the
        // seven Library data roots the scanner enumerates (Preferences included,
        // which the generic blocklist would wrongly refuse) and still rejects
        // symlinks, credential-looking names, and anything outside those roots
        // (#76) — a mismatch is recorded and skipped, not deleted.
        if includeLeftovers {
            for leftover in app.leftovers {
                guard safety.validateForUninstallLeftover(leftover.path).isSafe else {
                    errors.append(CleanupError(
                        path: leftover.path,
                        message: "Blocked by safety checks",
                        underlyingError: nil
                    ))
                    continue
                }
                do {
                    try trashItem(leftover.path)
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
    case insufficientPermissions(String)
    case blockedBySafety(String)

    var errorDescription: String? {
        switch self {
        case .appRunning(let name):
            return "Please quit \(name) before uninstalling"
        case .cannotRemoveApp(let name, let error):
            return "Could not uninstall \(name): \(error.localizedDescription)"
        case .insufficientPermissions(let name):
            return "Cannot uninstall \(name): Administrator privileges required for apps in /Applications"
        case .blockedBySafety(let name):
            return "Cannot uninstall \(name): the app bundle failed a safety check (unexpected location or symlink)"
        }
    }
}
