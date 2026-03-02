## Task: Core Scanning Engine

**ID:** task-002
**Label:** Core Scanning Engine
**Description:** Build the modular scanning engine that all cleanup modules will use.
**Type:** Feature
**Status:** Done
**Priority:** Critical
**Created:** 2026-01-15
**Updated:** 2026-01-19
**PRD:** [PRD-001](../PRDS/PRD-001-macsweep-native.md)

---

## Additional Notes

### Estimated Effort
4-5 hours

### Deliverables

#### 1. ScanModule Protocol
```swift
protocol ScanModule: Identifiable {
    var id: String { get }
    var name: String { get }
    var description: String { get }
    var icon: String { get }  // SF Symbol name

    func scan() async throws -> [CleanupItem]
    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult
}
```

#### 2. Core Types
```swift
struct CleanupItem: Identifiable, Hashable {
    let id: UUID
    let path: URL
    let size: Int64
    let type: ItemType
    let module: String
    let lastModified: Date?

    enum ItemType {
        case file, directory, symbolicLink
    }
}

struct CleanupResult {
    let itemsProcessed: Int
    let bytesFreed: Int64
    let errors: [CleanupError]
}
```

#### 3. ScanEngine
```swift
actor ScanEngine {
    private var modules: [any ScanModule] = []

    func register(_ module: any ScanModule)
    func scan(modules: [String]? = nil) async -> [CleanupItem]
    func clean(items: [CleanupItem], dryRun: Bool) async -> CleanupResult
}
```

#### 4. File Size Calculator
```swift
struct DiskAnalyzer {
    /// Uses URLResourceKey for fast size calculation
    static func size(of url: URL) async throws -> Int64

    /// Recursively calculates directory size
    static func directorySize(at url: URL) async throws -> Int64
}
```

### Technical Notes

#### Fast Size Calculation with URLResourceKey
```swift
let resourceKeys: Set<URLResourceKey> = [
    .fileSizeKey,
    .fileAllocatedSizeKey,
    .isDirectoryKey,
    .isSymbolicLinkKey
]

let values = try url.resourceValues(forKeys: resourceKeys)
```

#### Async Scanning Pattern
```swift
func scan() async throws -> [CleanupItem] {
    try await withThrowingTaskGroup(of: [CleanupItem].self) { group in
        for path in targetPaths {
            group.addTask {
                try await self.scanPath(path)
            }
        }
        return try await group.reduce(into: []) { $0 += $1 }
    }
}
```

### Acceptance Criteria
- [ ] ScanModule protocol defined
- [ ] At least one module implemented (SystemCacheModule)
- [ ] Parallel scanning works
- [ ] Size calculations are accurate
- [ ] Errors are captured, not thrown

### Dependencies
- TASK-001 (Project Setup)

### References
- URLResourceKey: https://developer.apple.com/documentation/foundation/urlresourcekey
