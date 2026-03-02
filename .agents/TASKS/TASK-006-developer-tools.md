## Task: Developer Tools Cleanup Module

**ID:** task-006
**Label:** Developer Tools Cleanup
**Description:** Clean development build artifacts (node_modules, DerivedData, etc.) with project context awareness.
**Type:** Feature
**Status:** Done
**Priority:** High
**Order:** 2
**Created:** 2026-01-15
**Updated:** 2026-01-19
**PRD:** [PRD-001](../PRDS/PRD-001-macsweep-native.md)

---

## Additional Notes

### Estimated Effort
4-5 hours

### Deliverables

#### 1. DevFilesModule
```swift
struct DevFilesModule: ScanModule {
    let id = "dev-files"
    let name = "Developer Files"
    let description = "Build artifacts and dependency caches"
    let icon = "hammer"

    func scan() async throws -> [CleanupItem]
}
```

#### 2. Target Directories

| Directory | Project Marker | Description |
|-----------|----------------|-------------|
| node_modules | package.json | npm/yarn/pnpm packages |
| DerivedData | *.xcodeproj, *.xcworkspace | Xcode builds |
| .build | Package.swift | Swift PM |
| Pods | Podfile | CocoaPods |
| target | Cargo.toml | Rust |
| __pycache__ | *.py | Python bytecode |
| .pytest_cache | pytest.ini | pytest cache |
| .gradle | build.gradle* | Gradle |
| .next | next.config.* | Next.js |
| .nuxt | nuxt.config.* | Nuxt.js |
| dist | package.json | Build output |
| vendor/bundle | Gemfile | Ruby gems |
| .turbo | turbo.json | Turborepo |
| .cache | various | General cache |

#### 3. Scanning Strategy
```swift
struct DevProject: Identifiable {
    let id: UUID
    let rootPath: URL
    let type: ProjectType
    let cleanableItems: [DevCleanupTarget]
    var totalSize: Int64

    enum ProjectType {
        case node, xcode, swift, rust, python, ruby, gradle
    }
}

struct DevCleanupTarget {
    let path: URL
    let size: Int64
    let canRegenerate: Bool  // true if can be restored with build command
}
```

#### 4. Smart Scanning
```swift
func scan() async throws -> [CleanupItem] {
    let searchRoots = [
        FileManager.default.homeDirectoryForCurrentUser,
        URL(fileURLWithPath: "/Users") // All users
    ]

    // Find all project markers
    let projects = await findProjects(in: searchRoots)

    // For each project, identify cleanable artifacts
    var items: [CleanupItem] = []
    for project in projects {
        items += await scanProject(project)
    }

    return items.sorted { $0.size > $1.size }
}

private func findProjects(in roots: [URL]) async -> [DevProject] {
    // Use Spotlight for speed: kMDItemFSName == "package.json"
    // Fallback to recursive file enumeration
}
```

#### 5. Global Caches
```swift
struct GlobalDevCaches {
    static let targets: [String: URL] = [
        "npm": "~/.npm/_cacache",
        "yarn": "~/Library/Caches/Yarn",
        "pnpm": "~/Library/pnpm/store",
        "pip": "~/Library/Caches/pip",
        "cargo": "~/.cargo/registry/cache",
        "go": "~/go/pkg/mod/cache",
        "gradle": "~/.gradle/caches",
        "cocoapods": "~/Library/Caches/CocoaPods",
        "carthage": "~/Library/Caches/org.carthage.CarthageKit"
    ]
}
```

### Acceptance Criteria
- [x] Finds projects recursively
- [x] Shows project context (which project owns this node_modules)
- [x] Calculates accurate sizes
- [x] Global caches identified separately
- [x] Warns if project was recently modified

### Dependencies
- TASK-002 (Core Scanning Engine)
- TASK-003 (Safety Module)

### UI Considerations
- [x] Group by project type (byTypeView)
- [x] Show regeneration command (npm install, xcodebuild, etc.) - via popover
- [x] Last modified date for staleness detection - with "Active" and "Recent" badges
