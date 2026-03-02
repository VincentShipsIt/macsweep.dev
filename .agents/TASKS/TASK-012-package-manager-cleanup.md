## Task: Package Manager Cleanup Module

**ID:** task-012
**Label:** Package Manager Cleanup
**Description:** Clean package manager caches and outdated packages (Homebrew, npm, pip, etc.).
**Type:** Feature
**Status:** Backlog
**Priority:** Medium
**Created:** 2026-01-15
**Updated:** 2026-01-19
**PRD:** [PRD-001](../PRDS/PRD-001-macsweep-native.md)

---

## Additional Notes

### Estimated Effort
3-4 hours

### Deliverables

#### 1. PackageManagerModule
```swift
struct PackageManagerModule: ScanModule {
    let id = "package-managers"
    let name = "Package Managers"
    let description = "Homebrew, npm, pip caches and outdated packages"
    let icon = "shippingbox"

    func scan() async throws -> [CleanupItem]
}
```

#### 2. Homebrew Cleanup
```swift
struct HomebrewManager {
    private let brewPath = "/opt/homebrew/bin/brew"  // Apple Silicon
    private let brewPathIntel = "/usr/local/bin/brew"

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: brewPath) ||
        FileManager.default.fileExists(atPath: brewPathIntel)
    }

    /// Get cleanup info
    func cleanupDryRun() async throws -> HomebrewCleanupInfo {
        // brew cleanup -n --prune=all
    }

    /// Perform cleanup
    func cleanup() async throws {
        // brew cleanup --prune=all
    }

    /// List outdated packages
    func outdatedPackages() async throws -> [OutdatedPackage] {
        // brew outdated --json
    }

    struct HomebrewCleanupInfo {
        let formulaeToRemove: [String]
        let casksToRemove: [String]
        let bytesToFree: Int64
    }
}
```

#### 3. npm/Node Cleanup
```swift
struct NpmManager {
    /// Global npm cache
    func cacheSize() async throws -> Int64 {
        let cachePath = URL.homeDirectory.appending(path: ".npm/_cacache")
        return await DiskAnalyzer.directorySize(at: cachePath)
    }

    /// Clean global cache
    func cleanCache() async throws {
        // npm cache clean --force
    }

    /// Also check yarn and pnpm
    let yarnCachePath = URL(fileURLWithPath: "~/Library/Caches/Yarn")
    let pnpmStorePath = URL(fileURLWithPath: "~/Library/pnpm/store")
}
```

#### 4. pip/Python Cleanup
```swift
struct PipManager {
    /// pip cache location
    let cachePath = URL(fileURLWithPath: "~/Library/Caches/pip")

    func cacheSize() async throws -> Int64

    func cleanCache() async throws {
        // pip cache purge
    }
}
```

#### 5. Ruby/Gems Cleanup
```swift
struct RubyGemsManager {
    /// Clean old gem versions
    func cleanup() async throws {
        // gem cleanup
    }

    /// Bundle cache
    let bundleCachePath = URL(fileURLWithPath: "~/.bundle/cache")
}
```

#### 6. Cargo/Rust Cleanup
```swift
struct CargoManager {
    let registryCachePath = URL(fileURLWithPath: "~/.cargo/registry/cache")
    let gitCheckoutsPath = URL(fileURLWithPath: "~/.cargo/git/checkouts")

    func cacheSize() async throws -> Int64
}
```

### Package Managers Summary

| Manager | Cache Location | Clean Command |
|---------|---------------|---------------|
| Homebrew | /opt/homebrew/Cellar (old versions) | brew cleanup |
| npm | ~/.npm/_cacache | npm cache clean --force |
| yarn | ~/Library/Caches/Yarn | yarn cache clean |
| pnpm | ~/Library/pnpm/store | pnpm store prune |
| pip | ~/Library/Caches/pip | pip cache purge |
| gem | varies | gem cleanup |
| cargo | ~/.cargo/registry/cache | cargo cache -a |
| go | ~/go/pkg/mod/cache | go clean -modcache |
| gradle | ~/.gradle/caches | (manual delete) |
| cocoapods | ~/Library/Caches/CocoaPods | pod cache clean --all |

### Acceptance Criteria
- [ ] Detects which package managers are installed
- [ ] Shows cache sizes for each
- [ ] Dry-run before actual cleanup
- [ ] Reports space freed
- [ ] Handles missing package managers gracefully

### Dependencies
- TASK-002 (Core Scanning Engine)

### Notes
- Some operations require the package manager CLI
- Version managers (nvm, pyenv, rbenv) complicate paths
- Consider warning if cleaning might break projects
