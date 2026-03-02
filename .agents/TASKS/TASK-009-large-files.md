## Task: Large Files Finder Module

**ID:** task-009
**Label:** Large Files Finder
**Description:** Find and manage large files consuming disk space.
**Type:** Feature
**Status:** Backlog
**Priority:** High
**Created:** 2026-01-15
**Updated:** 2026-01-19
**PRD:** [PRD-001](../PRDS/PRD-001-macsweep-native.md)

---

## Additional Notes

### Estimated Effort
3-4 hours

### Deliverables

#### 1. LargeFilesModule
```swift
struct LargeFilesModule: ScanModule {
    let id = "large-files"
    let name = "Large Files"
    let description = "Files over the size threshold"
    let icon = "doc.badge.ellipsis"

    var threshold: Int64 = 104_857_600  // 100MB default

    func scan() async throws -> [CleanupItem]
}
```

#### 2. Large File Model
```swift
struct LargeFile: Identifiable {
    let id: UUID
    let path: URL
    let size: Int64
    let type: UTType?
    let lastModified: Date?
    let lastAccessed: Date?

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: path.path)
    }
}
```

#### 3. Scanning Implementation
```swift
func scan() async throws -> [CleanupItem] {
    let home = FileManager.default.homeDirectoryForCurrentUser

    // Exclude system and protected paths
    let excludedPaths = ProtectedPaths.neverDelete

    var largeFiles: [LargeFile] = []

    let enumerator = FileManager.default.enumerator(
        at: home,
        includingPropertiesForKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .contentTypeKey
        ],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    )

    while let url = enumerator?.nextObject() as? URL {
        // Skip excluded paths
        if excludedPaths.contains(where: { url.path.hasPrefix($0) }) {
            enumerator?.skipDescendants()
            continue
        }

        let resources = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        guard resources?.isDirectory == false,
              let size = resources?.fileSize,
              size >= threshold
        else { continue }

        largeFiles.append(LargeFile(
            id: UUID(),
            path: url,
            size: Int64(size),
            type: try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
            lastModified: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            lastAccessed: nil
        ))
    }

    return largeFiles
        .sorted { $0.size > $1.size }
        .map { /* convert to CleanupItem */ }
}
```

#### 4. Filter Options
```swift
struct LargeFilesFilter {
    var minSize: Int64 = 104_857_600  // 100MB
    var maxSize: Int64? = nil
    var types: Set<UTType>? = nil     // Filter by file type
    var olderThan: Date? = nil        // Last modified before
    var excludePaths: [URL] = []      // User exclusions
}
```

#### 5. Quick Look Integration
```swift
struct LargeFilesView: View {
    @State private var selectedFile: LargeFile?
    @State private var showingQuickLook = false

    var body: some View {
        List(largeFiles) { file in
            LargeFileRow(file: file)
                .onTapGesture {
                    selectedFile = file
                }
                .quickLookPreview($selectedFile?.path)
        }
    }
}
```

### Common Large File Types

| Type | Extensions | Notes |
|------|------------|-------|
| Videos | .mp4, .mov, .avi | Often largest |
| Disk Images | .dmg, .iso | Can be deleted after install |
| Archives | .zip, .tar.gz | Often temporary |
| Backups | .backup, .bak | May be outdated |
| VM Images | .vmdk, .vdi | Virtual machines |
| Downloads | various | Often forgotten |

### Acceptance Criteria
- [ ] Finds files over threshold
- [ ] Configurable size threshold
- [ ] Sorts by size (largest first)
- [ ] Shows file type icon
- [ ] Quick Look preview
- [ ] Batch selection + delete
- [ ] Excludes system files

### Dependencies
- TASK-002 (Core Scanning Engine)
- TASK-003 (Safety Module)

### UI Features
- Size slider for threshold adjustment
- Type filter (video, images, archives, etc.)
- Age filter (older than X days)
- Reveal in Finder
