import Foundation
import AppKit

/// Protocol for browser-specific cleanup modules
protocol BrowserModule: ScanModule {
    var browserName: String { get }
    var bundleID: String { get }
    var basePath: URL { get }

    var isInstalled: Bool { get }
    var isRunning: Bool { get }

    /// Safe to delete - auto regenerated
    var cachePaths: [URL] { get }

    /// Low risk - background scripts
    var serviceWorkerPaths: [URL] { get }

    /// Medium risk - site data, may cause logouts
    var localStoragePaths: [URL] { get }

    /// High risk - will log user out of all sites (opt-in only)
    var cookiePaths: [URL] { get }

    /// Critical risk - permanent history deletion (opt-in only)
    var historyPaths: [URL] { get }
}

extension BrowserModule {
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: basePath.path)
    }

    var isRunning: Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.contains { $0.bundleIdentifier == bundleID }
    }

    // Default empty implementations for opt-in paths
    var cookiePaths: [URL] { [] }
    var historyPaths: [URL] { [] }

    /// Get risk level for a given path
    func riskLevel(for url: URL) -> BrowserDataRiskLevel {
        let path = url.path
        if cachePaths.contains(where: { path.hasPrefix($0.path) }) {
            return .none
        }
        if serviceWorkerPaths.contains(where: { path.hasPrefix($0.path) }) {
            return .low
        }
        if localStoragePaths.contains(where: { path.hasPrefix($0.path) }) {
            return .medium
        }
        if cookiePaths.contains(where: { path.hasPrefix($0.path) }) {
            return .high
        }
        if historyPaths.contains(where: { path.hasPrefix($0.path) }) {
            return .critical
        }
        return .none
    }
}

// MARK: - Chrome Module

struct ChromeModule: BrowserModule {
    let id = "browser-chrome"
    let name = "Google Chrome"
    let description = "Chrome caches, service workers, and browsing data"
    let icon = "globe"
    let browserName = "Chrome"
    let bundleID = "com.google.Chrome"

    var basePath: URL {
        URL.libraryDirectory.appending(path: "Application Support/Google/Chrome")
    }

    var cachePaths: [URL] {
        var paths: [URL] = []
        for profile in profiles {
            paths.append(contentsOf: [
                basePath.appending(path: "\(profile)/Cache"),
                basePath.appending(path: "\(profile)/Code Cache"),
                basePath.appending(path: "\(profile)/GPUCache"),
                basePath.appending(path: "\(profile)/ShaderCache"),
            ])
        }
        paths.append(basePath.appending(path: "ShaderCache"))
        return paths
    }

    var serviceWorkerPaths: [URL] {
        profiles.map { basePath.appending(path: "\($0)/Service Worker") }
    }

    var localStoragePaths: [URL] {
        profiles.map { basePath.appending(path: "\($0)/Local Storage") }
    }

    var cookiePaths: [URL] {
        profiles.map { basePath.appending(path: "\($0)/Cookies") }
    }

    var historyPaths: [URL] {
        profiles.map { basePath.appending(path: "\($0)/History") }
    }

    /// Detect all Chrome profiles (Default, Profile 1, Profile 2, etc.)
    private var profiles: [String] {
        var found: [String] = ["Default"]
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: basePath.path) else {
            return found
        }
        for item in contents {
            if item.hasPrefix("Profile ") {
                found.append(item)
            }
        }
        return found
    }

    func scan() async throws -> [CleanupItem] {
        guard isInstalled else { return [] }

        var items: [CleanupItem] = []

        // Scan cache paths
        for cachePath in cachePaths {
            if let item = await scanPath(cachePath, category: "Cache") {
                items.append(item)
            }
        }

        // Scan service workers
        for swPath in serviceWorkerPaths {
            if let item = await scanPath(swPath, category: "Service Workers") {
                items.append(item)
            }
        }

        return items
    }

    private func scanPath(_ url: URL, category: String) async -> CleanupItem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let size = try await DiskAnalyzer.directorySize(at: url)
            guard size > 1024 else { return nil }  // Skip tiny items

            return CleanupItem(
                id: UUID(),
                path: url,
                size: size,
                type: .directory,
                module: id,
                moduleName: "\(browserName) \(category)",
                lastModified: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            )
        } catch {
            return nil
        }
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        if isRunning && !dryRun {
            throw BrowserCleanupError.browserRunning(browserName)
        }

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
                    // Remove contents but keep directory
                    let contents = try FileManager.default.contentsOfDirectory(
                        at: item.path,
                        includingPropertiesForKeys: nil
                    )
                    for content in contents {
                        try FileManager.default.removeItem(at: content)
                    }
                    processed += 1
                    freed += item.size
                } catch {
                    errors.append(CleanupError(path: item.path, message: error.localizedDescription))
                }
            }
        }

        return CleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
    }
}

// MARK: - Safari Module

struct SafariModule: BrowserModule {
    let id = "browser-safari"
    let name = "Safari"
    let description = "Safari caches and website data (requires Full Disk Access)"
    let icon = "safari"
    let browserName = "Safari"
    let bundleID = "com.apple.Safari"

    var basePath: URL {
        URL.libraryDirectory.appending(path: "Safari")
    }

    var cachePaths: [URL] {
        [
            URL.libraryDirectory.appending(path: "Caches/com.apple.Safari"),
            URL.libraryDirectory.appending(path: "Caches/com.apple.Safari.SafeBrowsing"),
            basePath.appending(path: "LocalStorage"),
            basePath.appending(path: "Databases"),
        ]
    }

    var serviceWorkerPaths: [URL] {
        [basePath.appending(path: "ServiceWorkers")]
    }

    var localStoragePaths: [URL] {
        [basePath.appending(path: "LocalStorage")]
    }

    var cookiePaths: [URL] {
        [URL.libraryDirectory.appending(path: "Cookies/Cookies.binarycookies")]
    }

    var historyPaths: [URL] {
        [basePath.appending(path: "History.db")]
    }

    /// Check if we have Full Disk Access
    var hasFullDiskAccess: Bool {
        // Try to read a protected Safari file
        let testPath = basePath.appending(path: "History.db")
        return FileManager.default.isReadableFile(atPath: testPath.path)
    }

    func scan() async throws -> [CleanupItem] {
        guard isInstalled else { return [] }

        var items: [CleanupItem] = []

        for cachePath in cachePaths {
            if let item = await scanPath(cachePath, category: "Cache") {
                items.append(item)
            }
        }

        for swPath in serviceWorkerPaths {
            if let item = await scanPath(swPath, category: "Service Workers") {
                items.append(item)
            }
        }

        return items
    }

    private func scanPath(_ url: URL, category: String) async -> CleanupItem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let size = try await DiskAnalyzer.directorySize(at: url)
            guard size > 1024 else { return nil }

            return CleanupItem(
                id: UUID(),
                path: url,
                size: size,
                type: .directory,
                module: id,
                moduleName: "\(browserName) \(category)",
                lastModified: nil
            )
        } catch {
            return nil
        }
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        if isRunning && !dryRun {
            throw BrowserCleanupError.browserRunning(browserName)
        }

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
                    let contents = try FileManager.default.contentsOfDirectory(
                        at: item.path,
                        includingPropertiesForKeys: nil
                    )
                    for content in contents {
                        try FileManager.default.removeItem(at: content)
                    }
                    processed += 1
                    freed += item.size
                } catch {
                    errors.append(CleanupError(path: item.path, message: error.localizedDescription))
                }
            }
        }

        return CleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
    }
}

// MARK: - Firefox Module

struct FirefoxModule: BrowserModule {
    let id = "browser-firefox"
    let name = "Firefox"
    let description = "Firefox caches and offline storage"
    let icon = "flame"
    let browserName = "Firefox"
    let bundleID = "org.mozilla.firefox"

    var basePath: URL {
        URL.libraryDirectory.appending(path: "Application Support/Firefox")
    }

    var cachePaths: [URL] {
        profilePaths.flatMap { profile in
            [
                profile.appending(path: "cache2"),
                profile.appending(path: "shader-cache"),
                profile.appending(path: "startupCache"),
            ]
        }
    }

    var serviceWorkerPaths: [URL] {
        profilePaths.map { $0.appending(path: "storage/default") }
    }

    var localStoragePaths: [URL] {
        profilePaths.map { $0.appending(path: "storage/default") }
    }

    var cookiePaths: [URL] {
        profilePaths.map { $0.appending(path: "cookies.sqlite") }
    }

    var historyPaths: [URL] {
        profilePaths.map { $0.appending(path: "places.sqlite") }
    }

    /// Get all Firefox profile directories
    private var profilePaths: [URL] {
        let profilesDir = basePath.appending(path: "Profiles")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: profilesDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        return contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    func scan() async throws -> [CleanupItem] {
        guard isInstalled else { return [] }

        var items: [CleanupItem] = []

        for cachePath in cachePaths {
            if let item = await scanPath(cachePath, category: "Cache") {
                items.append(item)
            }
        }

        return items
    }

    private func scanPath(_ url: URL, category: String) async -> CleanupItem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let size = try await DiskAnalyzer.directorySize(at: url)
            guard size > 1024 else { return nil }

            return CleanupItem(
                id: UUID(),
                path: url,
                size: size,
                type: .directory,
                module: id,
                moduleName: "\(browserName) \(category)",
                lastModified: nil
            )
        } catch {
            return nil
        }
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        if isRunning && !dryRun {
            throw BrowserCleanupError.browserRunning(browserName)
        }

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
                    let contents = try FileManager.default.contentsOfDirectory(
                        at: item.path,
                        includingPropertiesForKeys: nil
                    )
                    for content in contents {
                        try FileManager.default.removeItem(at: content)
                    }
                    processed += 1
                    freed += item.size
                } catch {
                    errors.append(CleanupError(path: item.path, message: error.localizedDescription))
                }
            }
        }

        return CleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
    }
}

// MARK: - Brave Module

struct BraveModule: BrowserModule {
    let id = "browser-brave"
    let name = "Brave"
    let description = "Brave browser caches and service workers"
    let icon = "shield"
    let browserName = "Brave"
    let bundleID = "com.brave.Browser"

    var basePath: URL {
        URL.libraryDirectory.appending(path: "Application Support/BraveSoftware/Brave-Browser")
    }

    var cachePaths: [URL] {
        var paths: [URL] = []
        for profile in profiles {
            paths.append(contentsOf: [
                basePath.appending(path: "\(profile)/Cache"),
                basePath.appending(path: "\(profile)/Code Cache"),
                basePath.appending(path: "\(profile)/GPUCache"),
            ])
        }
        return paths
    }

    var serviceWorkerPaths: [URL] {
        profiles.map { basePath.appending(path: "\($0)/Service Worker") }
    }

    var localStoragePaths: [URL] {
        profiles.map { basePath.appending(path: "\($0)/Local Storage") }
    }

    var cookiePaths: [URL] {
        profiles.map { basePath.appending(path: "\($0)/Cookies") }
    }

    var historyPaths: [URL] {
        profiles.map { basePath.appending(path: "\($0)/History") }
    }

    private var profiles: [String] {
        var found: [String] = ["Default"]
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: basePath.path) else {
            return found
        }
        for item in contents where item.hasPrefix("Profile ") {
            found.append(item)
        }
        return found
    }

    func scan() async throws -> [CleanupItem] {
        guard isInstalled else { return [] }

        var items: [CleanupItem] = []

        for cachePath in cachePaths {
            if let item = await scanPath(cachePath, category: "Cache") {
                items.append(item)
            }
        }

        for swPath in serviceWorkerPaths {
            if let item = await scanPath(swPath, category: "Service Workers") {
                items.append(item)
            }
        }

        return items
    }

    private func scanPath(_ url: URL, category: String) async -> CleanupItem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let size = try await DiskAnalyzer.directorySize(at: url)
            guard size > 1024 else { return nil }

            return CleanupItem(
                id: UUID(),
                path: url,
                size: size,
                type: .directory,
                module: id,
                moduleName: "\(browserName) \(category)",
                lastModified: nil
            )
        } catch {
            return nil
        }
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        if isRunning && !dryRun {
            throw BrowserCleanupError.browserRunning(browserName)
        }

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
                    let contents = try FileManager.default.contentsOfDirectory(
                        at: item.path,
                        includingPropertiesForKeys: nil
                    )
                    for content in contents {
                        try FileManager.default.removeItem(at: content)
                    }
                    processed += 1
                    freed += item.size
                } catch {
                    errors.append(CleanupError(path: item.path, message: error.localizedDescription))
                }
            }
        }

        return CleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
    }
}

// MARK: - Arc Module

struct ArcModule: BrowserModule {
    let id = "browser-arc"
    let name = "Arc"
    let description = "Arc browser caches and data"
    let icon = "circle.hexagongrid"
    let browserName = "Arc"
    let bundleID = "company.thebrowser.Browser"

    var basePath: URL {
        URL.libraryDirectory.appending(path: "Application Support/Arc")
    }

    private var userDataPath: URL {
        basePath.appending(path: "User Data")
    }

    var cachePaths: [URL] {
        var paths: [URL] = []
        for profile in profiles {
            paths.append(contentsOf: [
                userDataPath.appending(path: "\(profile)/Cache"),
                userDataPath.appending(path: "\(profile)/Code Cache"),
                userDataPath.appending(path: "\(profile)/GPUCache"),
            ])
        }
        paths.append(userDataPath.appending(path: "ShaderCache"))
        return paths
    }

    var serviceWorkerPaths: [URL] {
        profiles.map { userDataPath.appending(path: "\($0)/Service Worker") }
    }

    var localStoragePaths: [URL] {
        profiles.map { userDataPath.appending(path: "\($0)/Local Storage") }
    }

    var cookiePaths: [URL] {
        profiles.map { userDataPath.appending(path: "\($0)/Cookies") }
    }

    var historyPaths: [URL] {
        profiles.map { userDataPath.appending(path: "\($0)/History") }
    }

    /// Detect Arc profiles
    private var profiles: [String] {
        var found: [String] = ["Default"]
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: userDataPath.path) else {
            return found
        }
        for item in contents where item.hasPrefix("Profile ") {
            found.append(item)
        }
        return found
    }

    func scan() async throws -> [CleanupItem] {
        guard isInstalled else { return [] }

        var items: [CleanupItem] = []

        for cachePath in cachePaths {
            if let item = await scanPath(cachePath, category: "Cache") {
                items.append(item)
            }
        }

        for swPath in serviceWorkerPaths {
            if let item = await scanPath(swPath, category: "Service Workers") {
                items.append(item)
            }
        }

        return items
    }

    private func scanPath(_ url: URL, category: String) async -> CleanupItem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let size = try await DiskAnalyzer.directorySize(at: url)
            guard size > 1024 else { return nil }

            return CleanupItem(
                id: UUID(),
                path: url,
                size: size,
                type: .directory,
                module: id,
                moduleName: "\(browserName) \(category)",
                lastModified: nil
            )
        } catch {
            return nil
        }
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        if isRunning && !dryRun {
            throw BrowserCleanupError.browserRunning(browserName)
        }

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
                    let contents = try FileManager.default.contentsOfDirectory(
                        at: item.path,
                        includingPropertiesForKeys: nil
                    )
                    for content in contents {
                        try FileManager.default.removeItem(at: content)
                    }
                    processed += 1
                    freed += item.size
                } catch {
                    errors.append(CleanupError(path: item.path, message: error.localizedDescription))
                }
            }
        }

        return CleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
    }
}

// MARK: - Edge Module

struct EdgeModule: BrowserModule {
    let id = "browser-edge"
    let name = "Microsoft Edge"
    let description = "Edge browser caches and service workers"
    let icon = "globe.americas"
    let browserName = "Edge"
    let bundleID = "com.microsoft.edgemac"

    var basePath: URL {
        URL.libraryDirectory.appending(path: "Application Support/Microsoft Edge")
    }

    var cachePaths: [URL] {
        var paths: [URL] = []
        for profile in profiles {
            paths.append(contentsOf: [
                basePath.appending(path: "\(profile)/Cache"),
                basePath.appending(path: "\(profile)/Code Cache"),
                basePath.appending(path: "\(profile)/GPUCache"),
            ])
        }
        paths.append(basePath.appending(path: "ShaderCache"))
        return paths
    }

    var serviceWorkerPaths: [URL] {
        profiles.map { basePath.appending(path: "\($0)/Service Worker") }
    }

    var localStoragePaths: [URL] {
        profiles.map { basePath.appending(path: "\($0)/Local Storage") }
    }

    var cookiePaths: [URL] {
        profiles.map { basePath.appending(path: "\($0)/Cookies") }
    }

    var historyPaths: [URL] {
        profiles.map { basePath.appending(path: "\($0)/History") }
    }

    private var profiles: [String] {
        var found: [String] = ["Default"]
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: basePath.path) else {
            return found
        }
        for item in contents where item.hasPrefix("Profile ") {
            found.append(item)
        }
        return found
    }

    func scan() async throws -> [CleanupItem] {
        guard isInstalled else { return [] }

        var items: [CleanupItem] = []

        for cachePath in cachePaths {
            if let item = await scanPath(cachePath, category: "Cache") {
                items.append(item)
            }
        }

        for swPath in serviceWorkerPaths {
            if let item = await scanPath(swPath, category: "Service Workers") {
                items.append(item)
            }
        }

        return items
    }

    private func scanPath(_ url: URL, category: String) async -> CleanupItem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let size = try await DiskAnalyzer.directorySize(at: url)
            guard size > 1024 else { return nil }

            return CleanupItem(
                id: UUID(),
                path: url,
                size: size,
                type: .directory,
                module: id,
                moduleName: "\(browserName) \(category)",
                lastModified: nil
            )
        } catch {
            return nil
        }
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        if isRunning && !dryRun {
            throw BrowserCleanupError.browserRunning(browserName)
        }

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
                    let contents = try FileManager.default.contentsOfDirectory(
                        at: item.path,
                        includingPropertiesForKeys: nil
                    )
                    for content in contents {
                        try FileManager.default.removeItem(at: content)
                    }
                    processed += 1
                    freed += item.size
                } catch {
                    errors.append(CleanupError(path: item.path, message: error.localizedDescription))
                }
            }
        }

        return CleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
    }
}

// MARK: - Browser Cleanup Error

enum BrowserCleanupError: LocalizedError {
    case browserRunning(String)
    case noAccess(String)
    case fullDiskAccessRequired

    var errorDescription: String? {
        switch self {
        case .browserRunning(let name):
            return "Please quit \(name) before cleaning"
        case .noAccess(let path):
            return "Cannot access \(path). Full Disk Access may be required."
        case .fullDiskAccessRequired:
            return "Full Disk Access is required to clean Safari data"
        }
    }
}

// MARK: - Data Risk Level

enum BrowserDataRiskLevel: Int, Comparable {
    case none = 0      // Cache - auto regenerated
    case low = 1       // Service Workers - background scripts
    case medium = 2    // LocalStorage - site data
    case high = 3      // Cookies - session data
    case critical = 4  // History - browsing history

    static func < (lhs: BrowserDataRiskLevel, rhs: BrowserDataRiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String {
        switch self {
        case .none: return "Safe to delete"
        case .low: return "Low risk"
        case .medium: return "May log you out of websites"
        case .high: return "Will log you out of all websites"
        case .critical: return "Permanently deletes browsing history"
        }
    }

    var warningMessage: String? {
        switch self {
        case .none, .low:
            return nil
        case .medium:
            return "Deleting LocalStorage may log you out of some websites and reset site preferences."
        case .high:
            return "Deleting cookies will log you out of ALL websites. You will need to sign in again."
        case .critical:
            return "Deleting browsing history is permanent and cannot be undone."
        }
    }
}
