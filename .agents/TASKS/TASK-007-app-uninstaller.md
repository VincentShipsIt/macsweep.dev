## Task: App Uninstaller Module

**ID:** task-007
**Label:** App Uninstaller
**Description:** Complete app removal with detection of leftover files after manual uninstall.
**Type:** Feature
**Status:** Backlog
**Priority:** High
**Created:** 2026-01-15
**Updated:** 2026-01-19
**PRD:** [PRD-001](../PRDS/PRD-001-macsweep-native.md)

---

## Additional Notes

### Estimated Effort
5-6 hours

### Deliverables

#### 1. InstalledApp Model
```swift
struct InstalledApp: Identifiable {
    let id: String  // Bundle ID
    let name: String
    let bundlePath: URL
    let version: String?
    let size: Int64
    let icon: NSImage?
    let lastUsed: Date?

    var leftovers: [AppLeftover]
}

struct AppLeftover: Identifiable {
    let id: UUID
    let path: URL
    let size: Int64
    let type: LeftoverType

    enum LeftoverType {
        case preferences      // ~/Library/Preferences
        case applicationSupport  // ~/Library/Application Support
        case caches          // ~/Library/Caches
        case logs            // ~/Library/Logs
        case containers      // ~/Library/Containers
        case savedState      // ~/Library/Saved Application State
        case launchAgent     // ~/Library/LaunchAgents
        case other
    }
}
```

#### 2. App Discovery
```swift
actor AppDiscovery {
    /// Find all installed apps
    func installedApps() async -> [InstalledApp] {
        let searchPaths = [
            URL(fileURLWithPath: "/Applications"),
            URL.homeDirectory.appending(path: "Applications")
        ]

        var apps: [InstalledApp] = []
        for searchPath in searchPaths {
            apps += await scanApps(in: searchPath)
        }
        return apps
    }

    /// Get app metadata from bundle
    private func parseAppBundle(at url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier,
              let name = bundle.infoDictionary?["CFBundleName"] as? String
        else { return nil }

        return InstalledApp(
            id: bundleID,
            name: name,
            bundlePath: url,
            version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
            size: calculateSize(url),
            icon: NSWorkspace.shared.icon(forFile: url.path),
            lastUsed: getLastUsedDate(bundleID)
        )
    }
}
```

#### 3. Leftover Detection
```swift
actor LeftoverScanner {
    private let leftoverLocations: [(URL, AppLeftover.LeftoverType)] = [
        (.libraryDirectory.appending(path: "Preferences"), .preferences),
        (.libraryDirectory.appending(path: "Application Support"), .applicationSupport),
        (.libraryDirectory.appending(path: "Caches"), .caches),
        (.libraryDirectory.appending(path: "Logs"), .logs),
        (.libraryDirectory.appending(path: "Containers"), .containers),
        (.libraryDirectory.appending(path: "Saved Application State"), .savedState),
        (.libraryDirectory.appending(path: "LaunchAgents"), .launchAgent)
    ]

    /// Find leftovers for a specific app
    func findLeftovers(for app: InstalledApp) async -> [AppLeftover] {
        var leftovers: [AppLeftover] = []

        for (baseURL, type) in leftoverLocations {
            leftovers += await scanForAppData(
                in: baseURL,
                matching: app.id,
                type: type
            )
        }

        return leftovers
    }

    /// Find orphaned leftovers (no matching app installed)
    func findOrphanedLeftovers() async -> [AppLeftover] {
        let installedBundleIDs = Set(await AppDiscovery().installedApps().map(\.id))

        var orphans: [AppLeftover] = []
        for (baseURL, type) in leftoverLocations {
            let contents = try? FileManager.default.contentsOfDirectory(
                at: baseURL,
                includingPropertiesForKeys: nil
            )

            for item in contents ?? [] {
                if !matchesInstalledApp(item, installedBundleIDs) {
                    orphans.append(AppLeftover(
                        id: UUID(),
                        path: item,
                        size: await DiskAnalyzer.size(of: item),
                        type: type
                    ))
                }
            }
        }

        return orphans
    }
}
```

#### 4. Complete Uninstall
```swift
func uninstallApp(_ app: InstalledApp, includeLeftovers: Bool = true) async throws {
    // 1. Check if app is running
    if isAppRunning(bundleID: app.id) {
        throw UninstallError.appRunning
    }

    // 2. Move app to trash
    try FileManager.default.trashItem(at: app.bundlePath, resultingItemURL: nil)

    // 3. Remove leftovers if requested
    if includeLeftovers {
        for leftover in app.leftovers {
            try FileManager.default.trashItem(at: leftover.path, resultingItemURL: nil)
        }
    }
}
```

### Bundle ID Matching Strategies

| Pattern | Example | Match Logic |
|---------|---------|-------------|
| Exact | com.apple.Safari | Direct match |
| Prefix | com.apple.* | Starts with |
| Name-based | Safari | Folder name contains app name |
| Vendor | Apple | Folder contains vendor name |

### Acceptance Criteria
- [ ] Lists all installed apps with size
- [ ] Detects leftovers for each app
- [ ] Finds orphaned leftovers
- [ ] Checks if app is running before uninstall
- [ ] Moves to trash (recoverable)
- [ ] Shows total space to be recovered

### Dependencies
- TASK-002 (Core Scanning Engine)
- TASK-003 (Safety Module)

### UI Considerations
- Show app icon
- Group by: size, last used, vendor
- Differentiate orphan leftovers visually
