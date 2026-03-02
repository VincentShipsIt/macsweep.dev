## Task: Storage Visualizer

**ID:** task-008
**Label:** Storage Visualizer
**Description:** Visual disk usage analysis with sunburst/treemap visualization (DaisyDisk-style).
**Type:** Feature
**Status:** Backlog
**Priority:** Medium
**Created:** 2026-01-15
**Updated:** 2026-01-19
**PRD:** [PRD-001](../PRDS/PRD-001-macsweep-native.md)

---

## Additional Notes

### Estimated Effort
6-8 hours

### Deliverables

#### 1. DiskNode Model
```swift
struct DiskNode: Identifiable {
    let id: UUID
    let name: String
    let path: URL
    let size: Int64
    let type: NodeType
    var children: [DiskNode]

    enum NodeType {
        case file(extension: String?)
        case directory
        case application
        case system
    }

    var percentage: Double  // Of parent
    var depth: Int          // From root
}
```

#### 2. DiskAnalyzer
```swift
actor DiskAnalyzer {
    /// Analyze a directory and return hierarchical node tree
    func analyze(
        root: URL,
        maxDepth: Int = 10,
        minSize: Int64 = 1_048_576  // 1MB
    ) async throws -> DiskNode

    /// Progress reporting
    var progressHandler: ((AnalysisProgress) -> Void)?

    struct AnalysisProgress {
        let currentPath: URL
        let filesScanned: Int
        let bytesScanned: Int64
    }
}
```

#### 3. Visualization Options

**Sunburst Chart (Recommended)**
```swift
struct SunburstView: View {
    let rootNode: DiskNode
    @State private var selectedPath: [UUID] = []

    var body: some View {
        Canvas { context, size in
            drawSunburst(context: context, size: size)
        }
        .gesture(tapGesture)
    }

    private func drawSunburst(context: GraphicsContext, size: CGSize) {
        // Draw concentric rings, each ring = depth level
        // Arc segments proportional to size
    }
}
```

**Treemap Alternative**
```swift
struct TreemapView: View {
    let rootNode: DiskNode

    var body: some View {
        GeometryReader { geometry in
            recursiveTreemap(node: rootNode, rect: CGRect(origin: .zero, size: geometry.size))
        }
    }
}
```

#### 4. Color Coding

| File Type | Color | Extensions |
|-----------|-------|------------|
| Documents | Blue | .pdf, .doc, .txt |
| Images | Green | .jpg, .png, .gif |
| Videos | Purple | .mp4, .mov, .avi |
| Audio | Orange | .mp3, .wav, .aac |
| Archives | Yellow | .zip, .tar, .gz |
| Code | Cyan | .swift, .js, .py |
| Applications | Red | .app |
| System | Gray | OS files |

#### 5. Interactions

```swift
struct VisualizerInteractions {
    // Drill down
    func onTap(node: DiskNode) {
        navigationPath.append(node)
    }

    // Context menu
    func onRightClick(node: DiskNode) -> some View {
        Menu {
            Button("Reveal in Finder") { ... }
            Button("Quick Look") { ... }
            Divider()
            Button("Delete", role: .destructive) { ... }
        }
    }

    // Breadcrumb navigation
    func onBreadcrumbTap(index: Int) {
        navigationPath = Array(navigationPath.prefix(index + 1))
    }
}
```

### Technical Considerations

#### Performance
- Scan in background with progress
- Lazy load children on drill-down
- Cache analyzed nodes
- Stop at configurable depth

#### Size Calculation
```swift
// Use URLResourceKey for speed
let resourceKeys: Set<URLResourceKey> = [
    .totalFileAllocatedSizeKey,  // Physical size
    .isDirectoryKey,
    .contentModificationDateKey
]
```

### Acceptance Criteria
- [ ] Full disk analysis completes in <60 seconds
- [ ] Visualization renders smoothly (60fps)
- [ ] Click to drill down works
- [ ] Breadcrumb navigation works
- [ ] Delete from visualization works
- [ ] Color coding by file type

### Dependencies
- TASK-002 (Core Scanning Engine)

### UI Mockup
```
┌─────────────────────────────────────────────┐
│ Macintosh HD > Users > me > Library         │  <- Breadcrumb
├─────────────────────────────────────────────┤
│                                             │
│        ╭─────────────────────╮              │
│       ╱    Caches (4.2GB)    ╲             │
│      ╱  ╭─────────────────╮  ╲            │
│     │   │  Chrome (1.2GB) │   │            │
│     │   ╰─────────────────╯   │            │
│      ╲                        ╱            │
│       ╲   Application Support╱             │
│        ╰─────────────────────╯              │
│                                             │
├─────────────────────────────────────────────┤
│ Selected: Caches | 4.2 GB | 847 items      │
│ [Reveal in Finder] [Delete]                 │
└─────────────────────────────────────────────┘
```
