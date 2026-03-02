## Task: Duplicate File Finder Module

**ID:** task-016
**Label:** Duplicate Finder
**Description:** Detect and remove duplicate files to recover disk space.
**Type:** Feature
**Status:** Backlog
**Priority:** High
**Created:** 2026-01-15
**Updated:** 2026-01-19
**PRD:** [PRD-001](../PRDS/PRD-001-macsweep-native.md)

---

## Additional Notes

### Estimated Effort
4-5 hours

### Deliverables

#### 1. DuplicateFinderModule
```swift
struct DuplicateFinderModule: ScanModule {
    let id = "duplicates"
    let name = "Duplicate Files"
    let description = "Find and remove duplicate files"
    let icon = "doc.on.doc"

    var searchPaths: [URL] = [
        .homeDirectory,
        .downloadsDirectory,
        .documentsDirectory,
        .picturesDirectory
    ]

    var minSize: Int64 = 1024  // Skip files < 1KB

    func scan() async throws -> [CleanupItem]
}
```

#### 2. Duplicate Detection Strategy

**Phase 1: Size Grouping (Fast)**
```swift
// Group files by size - duplicates must have same size
var sizeGroups: [Int64: [URL]] = [:]
```

**Phase 2: Partial Hash (Medium)**
```swift
// For size matches, hash first 4KB + last 4KB
func partialHash(_ url: URL) -> String {
    // Read first 4KB
    // Read last 4KB
    // SHA256 hash combined
}
```

**Phase 3: Full Hash (Slow, only if needed)**
```swift
// Full file hash for final confirmation
func fullHash(_ url: URL) -> String {
    // Stream file through SHA256
}
```

#### 3. DuplicateGroup Model
```swift
struct DuplicateGroup: Identifiable {
    let id: UUID
    let hash: String
    let size: Int64
    let files: [DuplicateFile]

    var wastedSpace: Int64 {
        size * Int64(files.count - 1)  // Keep one, waste is the rest
    }

    var original: DuplicateFile? {
        // Oldest file is likely the original
        files.min(by: { $0.createdDate < $1.createdDate })
    }
}

struct DuplicateFile: Identifiable, Hashable {
    let id: UUID
    let path: URL
    let size: Int64
    let createdDate: Date
    let modifiedDate: Date

    var isInTrash: Bool {
        path.path.contains(".Trash")
    }
}
```

#### 4. Smart Selection
```swift
struct DuplicateSelector {
    /// Auto-select duplicates to delete, keeping the best one
    func autoSelect(_ group: DuplicateGroup) -> [DuplicateFile] {
        // Keep: oldest file (original)
        // Keep: file in most important location (Documents > Downloads > Desktop)
        // Delete: files in Trash, temp folders, Downloads

        let sorted = group.files.sorted { file1, file2 in
            // Priority: not in trash > in important folder > oldest
            if file1.isInTrash != file2.isInTrash {
                return !file1.isInTrash
            }
            return locationPriority(file1.path) > locationPriority(file2.path)
        }

        // Keep first (best), return rest for deletion
        return Array(sorted.dropFirst())
    }

    private func locationPriority(_ url: URL) -> Int {
        let path = url.path
        if path.contains("/Documents/") { return 100 }
        if path.contains("/Desktop/") { return 90 }
        if path.contains("/Pictures/") { return 80 }
        if path.contains("/Downloads/") { return 50 }
        if path.contains("/.Trash/") { return 0 }
        return 60
    }
}
```

#### 5. Scanning Implementation
```swift
func scan() async throws -> [CleanupItem] {
    // Phase 1: Enumerate and group by size
    var sizeGroups: [Int64: [URL]] = [:]

    for searchPath in searchPaths {
        let enumerator = FileManager.default.enumerator(
            at: searchPath,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            guard values?.isDirectory == false,
                  let size = values?.fileSize,
                  size >= minSize
            else { continue }

            sizeGroups[Int64(size), default: []].append(url)
        }
    }

    // Phase 2: For groups with 2+ files, compute partial hashes
    var hashGroups: [String: [URL]] = [:]

    for (_, urls) in sizeGroups where urls.count > 1 {
        for url in urls {
            let hash = try await partialHash(url)
            hashGroups[hash, default: []].append(url)
        }
    }

    // Phase 3: Verify with full hash (optional, for large files)
    var duplicateGroups: [DuplicateGroup] = []

    for (hash, urls) in hashGroups where urls.count > 1 {
        // For files > 100MB, verify with full hash
        // For smaller files, partial hash is sufficient

        let files = urls.map { url -> DuplicateFile in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
            return DuplicateFile(
                id: UUID(),
                path: url,
                size: Int64(values?.fileSize ?? 0),
                createdDate: values?.creationDate ?? Date(),
                modifiedDate: values?.contentModificationDate ?? Date()
            )
        }

        duplicateGroups.append(DuplicateGroup(
            id: UUID(),
            hash: hash,
            size: files.first?.size ?? 0,
            files: files
        ))
    }

    // Convert to CleanupItems (auto-select duplicates to remove)
    let selector = DuplicateSelector()
    return duplicateGroups.flatMap { group in
        selector.autoSelect(group).map { file in
            CleanupItem(
                id: file.id,
                path: file.path,
                size: file.size,
                type: .file,
                module: id,
                moduleName: "Duplicate of \(group.original?.path.lastPathComponent ?? "unknown")",
                lastModified: file.modifiedDate
            )
        }
    }
}
```

### Performance Considerations

| Phase | Speed | Purpose |
|-------|-------|---------|
| Size grouping | Very fast | Eliminate 99% of files |
| Partial hash | Fast | Confirm likely duplicates |
| Full hash | Slow | 100% verification for large files |

### UI Features

- Show duplicate groups visually
- Preview files before deletion
- "Keep this one" selection
- Auto-select smart recommendations
- Show total wasted space

### Acceptance Criteria
- [ ] Finds duplicates accurately (no false positives)
- [ ] Scans home directory in < 60 seconds
- [ ] Shows which file to keep (original)
- [ ] Groups duplicates visually
- [ ] Handles large files without memory issues

### Dependencies
- TASK-002 (Core Scanning Engine)
- TASK-003 (Safety Module)

### Edge Cases
- Hard links (same inode) - not duplicates
- Symbolic links - skip or follow?
- Files being written to - skip locked files
- Very large files (>1GB) - stream hash
