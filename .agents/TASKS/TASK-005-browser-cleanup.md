## Task: Browser Cleanup Module

**ID:** task-005
**Label:** Browser Cleanup
**Description:** Clean browser caches, service workers, and optional data for all major browsers.
**Type:** Feature
**Status:** AI Review
**Priority:** High
**Order:** 1
**Created:** 2026-01-15
**Updated:** 2026-01-19T16:23:46.880Z
**PRD:** [PRD-001](../PRDS/PRD-001-macsweep-native.md)

---

## Additional Notes

### Estimated Effort
4-5 hours

### Deliverables

#### 1. BrowserModule Protocol
```swift
protocol BrowserModule: ScanModule {
    var browserName: String { get }
    var bundleID: String { get }
    var isInstalled: Bool { get }

    var cachePaths: [URL] { get }
    var serviceWorkerPaths: [URL] { get }
    var localStoragePaths: [URL] { get }  // Opt-in
    var cookiePaths: [URL] { get }        // Opt-in
}
```

#### 2. Supported Browsers

| Browser | Bundle ID | Base Path |
|---------|-----------|-----------|
| Chrome | com.google.Chrome | ~/Library/Application Support/Google/Chrome |
| Safari | com.apple.Safari | ~/Library/Safari |
| Firefox | org.mozilla.firefox | ~/Library/Application Support/Firefox |
| Brave | com.brave.Browser | ~/Library/Application Support/BraveSoftware/Brave-Browser |
| Arc | company.thebrowser.Browser | ~/Library/Application Support/Arc |
| Edge | com.microsoft.edgemac | ~/Library/Application Support/Microsoft Edge |

#### 3. Chrome Module Example
```swift
struct ChromeModule: BrowserModule {
    let id = "browser-chrome"
    let name = "Google Chrome"
    let browserName = "Chrome"
    let bundleID = "com.google.Chrome"
    let icon = "globe"

    private let baseURL = URL.libraryDirectory
        .appending(path: "Application Support/Google/Chrome")

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: baseURL.path)
    }

    var cachePaths: [URL] {
        [
            baseURL.appending(path: "Default/Cache"),
            baseURL.appending(path: "Default/Code Cache"),
            baseURL.appending(path: "Default/GPUCache"),
            baseURL.appending(path: "ShaderCache")
        ]
    }

    var serviceWorkerPaths: [URL] {
        [
            baseURL.appending(path: "Default/Service Worker")
        ]
    }

    // Profile-aware scanning
    func allProfiles() -> [String] {
        // Scans for Default, Profile 1, Profile 2, etc.
    }
}
```

#### 4. Service Worker Targets (Electron Apps)
```swift
struct ServiceWorkerTargets {
    static let electronApps: [String: URL] = [
        "Slack": "~/Library/Application Support/Slack/Service Worker",
        "Discord": "~/Library/Application Support/discord/Service Worker",
        "VS Code": "~/Library/Application Support/Code/Service Worker",
        "Notion": "~/Library/Application Support/Notion/Service Worker",
        "Figma": "~/Library/Application Support/Figma/Service Worker",
        "Spotify": "~/Library/Application Support/Spotify/Service Worker",
        "WhatsApp": "~/Library/Application Support/WhatsApp/Service Worker",
        "Telegram": "~/Library/Application Support/Telegram Desktop/Service Worker"
    ]
}
```

### Data Deletion Options

| Option | Description | Risk Level |
|--------|-------------|------------|
| Cache | Temporary files, auto-regenerated | None |
| Service Workers | Background scripts | Low |
| LocalStorage | Site data | Medium |
| Cookies | Session data | High |
| History | Browsing history | High |

### Acceptance Criteria
- [x] Detects all installed browsers (Chrome, Safari, Firefox, Brave, Arc, Edge)
- [x] Scans all profiles per browser (profile detection for Chromium browsers)
- [x] Service workers for Electron apps (30+ apps in ServiceWorkerModule)
- [x] Warns before high-risk deletions (BrowserDataRiskLevel enum with warnings)
- [x] Safari requires FDA warning (SafariFDAWarningBanner component)

### Dependencies
- TASK-002 (Core Scanning Engine)
- TASK-003 (Safety Module)

### Notes
- Safari data requires Full Disk Access
- Check browser is not running before deletion
- Some Electron apps store service workers differently
