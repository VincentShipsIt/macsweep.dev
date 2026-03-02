## Task: System Cleanup Module

**ID:** task-004
**Label:** System Cleanup
**Description:** Implement system junk cleanup (caches, logs, crash reports).
**Type:** Feature
**Status:** Done
**Priority:** High
**Order:** 1
**Created:** 2026-01-15
**Updated:** 2026-01-19
**PRD:** [PRD-001](../PRDS/PRD-001-macsweep-native.md)

---

## Additional Notes

### Estimated Effort
3-4 hours

### Deliverables

#### 1. SystemCacheModule
```swift
struct SystemCacheModule: ScanModule {
    let id = "system-cache"
    let name = "System Caches"
    let description = "Application caches and temporary files"
    let icon = "folder.badge.gearshape"

    private let targets: [URL] = [
        .libraryDirectory.appending(path: "Caches"),
        .libraryDirectory.appending(path: "Logs"),
        .libraryDirectory.appending(path: "Application Support/CrashReporter"),
        .libraryDirectory.appending(path: "Saved Application State")
    ]

    func scan() async throws -> [CleanupItem]
    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult
}
```

#### 2. Cache Targets

| Path | Description | Safe to Delete |
|------|-------------|----------------|
| ~/Library/Caches/* | App caches | Yes |
| ~/Library/Logs/* | App logs | Yes |
| ~/Library/Application Support/CrashReporter | Crash reports | Yes |
| ~/Library/Saved Application State | App snapshots | Yes |
| /private/var/folders | System temp | Partial |

#### 3. Scanning Logic
```swift
func scan() async throws -> [CleanupItem] {
    var items: [CleanupItem] = []

    for target in targets {
        guard FileManager.default.fileExists(atPath: target.path) else { continue }

        let contents = try FileManager.default.contentsOfDirectory(
            at: target,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        for url in contents {
            let size = try await DiskAnalyzer.size(of: url)
            items.append(CleanupItem(
                id: UUID(),
                path: url,
                size: size,
                type: url.hasDirectoryPath ? .directory : .file,
                module: id,
                lastModified: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            ))
        }
    }

    return items
}
```

### Acceptance Criteria
- [x] Scans all target directories
- [x] Accurate size calculation
- [x] Skips protected subdirectories
- [x] Clean actually removes files
- [x] Reports errors without crashing

### Dependencies
- TASK-002 (Core Scanning Engine)
- TASK-003 (Safety Module)

### Test Scenarios
1. Empty cache directory returns empty array
2. Large cache (>1GB) scans in <5 seconds
3. Permission denied is captured as error, not crash
4. Dry-run returns size but doesn't delete
