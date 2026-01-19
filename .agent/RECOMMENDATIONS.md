# MacSweep Feature Recommendations

## Priority Order for Next Features

Based on CleanMyMac feature analysis and user value, here's the recommended implementation order:

---

## Phase 1: Core Cleanup Features (High Impact)

### 1. Browser Cleanup Module
**Priority:** P0 - Most requested cleanup feature
**Estimated Effort:** 4-5 hours
**Task:** TASK-005

**Why First:**
- Browsers are the #1 source of cache bloat
- Immediately visible storage recovery (often 2-10GB)
- Service workers from Electron apps (Slack, Discord, VS Code) waste significant space

**Scope:**
- Chrome, Safari, Firefox, Brave, Arc, Edge
- Cache files, service workers, LocalStorage (opt-in)
- Multi-profile support (Chrome profiles)
- Electron app service workers (22+ apps)

**Files to Create:**
```
Core/Scanning/Modules/
├── BrowserModule.swift          # Base browser protocol
├── ChromeModule.swift           # Chrome-specific
├── SafariModule.swift           # Safari (requires FDA)
├── FirefoxModule.swift          # Firefox profiles
└── ServiceWorkerModule.swift    # Electron apps
```

---

### 2. App Uninstaller
**Priority:** P0 - Key differentiator
**Estimated Effort:** 5-6 hours
**Task:** TASK-007

**Why Second:**
- Users hate leftover files after app deletion
- Shows immediate value ("look at all these orphans!")
- CleanMyMac's most popular feature

**Scope:**
- List all installed apps with size + last used date
- Detect leftovers in ~/Library after manual uninstall
- Complete removal (app bundle + preferences + caches + support files)
- Orphan detection (leftovers with no matching app)

**Files to Create:**
```
Core/Scanning/Modules/
├── AppDiscovery.swift           # Find installed apps
├── LeftoverScanner.swift        # Detect orphaned files
└── AppUninstallerModule.swift   # Uninstall logic

Features/AppUninstaller/
├── AppUninstallerView.swift     # Main view
├── AppRow.swift                 # App list item
└── LeftoversView.swift          # Orphan files view
```

---

### 3. Large & Old Files Finder
**Priority:** P1 - Quick wins for users
**Estimated Effort:** 3-4 hours
**Task:** TASK-009

**Why Third:**
- Simple to implement, high value
- Users often have forgotten large downloads
- Easy "aha moment" when finding 10GB video files

**Scope:**
- Configurable size threshold (default 100MB)
- Age filter (files older than X days)
- Quick Look preview integration
- Type filtering (videos, disk images, archives)
- Batch selection and delete

**Files to Create:**
```
Core/Scanning/Modules/
└── LargeFilesModule.swift       # Scanning logic

Features/LargeFiles/
├── LargeFilesView.swift         # Results view
└── FilePreviewRow.swift         # File row with preview
```

---

## Phase 2: Visual & Speed Features

### 4. Space Lens (Storage Visualizer)
**Priority:** P1 - Visual differentiator
**Estimated Effort:** 6-8 hours
**Task:** TASK-008

**Why:**
- DaisyDisk-style visualization is compelling
- Helps users understand where space goes
- Premium feel to the app

**Scope:**
- Sunburst or treemap visualization
- Click to drill down into folders
- Color-coded by file type
- Quick delete from visualization
- Breadcrumb navigation

**Files to Create:**
```
Core/Storage/
└── DiskAnalyzer.swift           # Hierarchical scanning

Features/StorageVisualizer/
├── SpaceLensView.swift          # Main container
├── SunburstChart.swift          # Custom SwiftUI chart
├── TreemapView.swift            # Alternative view
└── StorageDetailView.swift      # Folder details
```

---

### 5. Developer Tools Cleanup
**Priority:** P1 - Developer-focused value
**Estimated Effort:** 4-5 hours
**Task:** TASK-006

**Why:**
- Developers are power users who recommend tools
- node_modules and DerivedData are notorious space hogs
- Can recover 10-50GB on developer machines

**Scope:**
- node_modules (npm/yarn/pnpm)
- DerivedData (Xcode)
- .build (Swift PM)
- Pods (CocoaPods)
- target (Rust/Cargo)
- __pycache__ (Python)
- .gradle (Android/Java)
- Global package manager caches

**Files to Create:**
```
Core/Scanning/Modules/
└── DevFilesModule.swift         # Dev artifact detection

Features/DevTools/
├── DevToolsView.swift           # Main view
└── ProjectCard.swift            # Project with cleanables
```

---

## Phase 3: System & Maintenance

### 6. Optimization (Memory/CPU Management)
**Priority:** P2 - Speed category
**Estimated Effort:** 3-4 hours
**Task:** (part of Speed section)

**Scope:**
- Real-time CPU/RAM display (already built in SystemMonitor)
- "Free Up Memory" button (purge command)
- Show memory-heavy processes
- Kill hung processes

**Files to Create:**
```
Features/Optimization/
├── OptimizationView.swift       # Main view
├── ProcessList.swift            # Running processes
└── MemoryChart.swift            # Memory visualization
```

---

### 7. Maintenance Tasks
**Priority:** P2 - Utility features
**Estimated Effort:** 2-3 hours
**Task:** TASK-014

**Scope:**
- Flush DNS cache
- Rebuild Spotlight index
- Rebuild Launch Services
- Clear font caches
- Verify disk
- Free purgeable space

**Already Partially Built:** MaintenanceView exists with UI, needs backend implementation.

---

### 8. Privacy Cleanup
**Priority:** P2 - Protection category
**Estimated Effort:** 3-4 hours
**Task:** (part of Protection section)

**Scope:**
- Browser history clearing
- Recent documents list
- Spotlight suggestions
- Siri suggestions
- QuickLook cache

---

## Phase 4: Advanced Features

### 9. Package Manager Cleanup
**Priority:** P3
**Task:** TASK-012

**Scope:**
- Homebrew cleanup (old versions)
- npm/yarn/pnpm cache
- pip cache
- gem cleanup
- cargo cache

---

### 10. Docker Cleanup
**Priority:** P3
**Task:** TASK-013

**Scope:**
- Stopped containers
- Dangling images
- Unused volumes
- Build cache

---

### 11. iOS Companion App
**Priority:** P3 (after macOS MVP)
**Task:** TASK-015

**Scope:**
- Photo duplicate detection
- Similar photo finder
- Large video finder
- Storage insights
- Widgets

---

## Implementation Recommendations

### Tech Decisions

1. **Use actors for scanning** - Thread-safe, structured concurrency
2. **Stream results** - Don't wait for full scan, show items as found
3. **Background scanning** - Use `Task.detached` for heavy operations
4. **Caching** - Cache scan results, invalidate on file changes

### UX Recommendations

1. **Always preview first** - Never delete without showing what will be removed
2. **Trash, don't delete** - Move to trash for recovery option
3. **Show savings** - Prominently display "X GB recovered"
4. **Progress feedback** - Show scan progress with current path

### Safety Recommendations

1. **Dry-run default** - Always preview before action
2. **Size warnings** - Confirm deletes over 1GB
3. **Protected paths** - Hard-coded, non-overridable
4. **Audit log** - Record all deletions with timestamps

---

## Estimated Timeline

| Phase | Features | Effort |
|-------|----------|--------|
| Phase 1 | Browser, Uninstaller, Large Files | 12-15 hours |
| Phase 2 | Space Lens, Dev Tools | 10-13 hours |
| Phase 3 | Optimization, Maintenance, Privacy | 8-11 hours |
| Phase 4 | Package Managers, Docker, iOS | 15-20 hours |

**Total to MVP (Phase 1-2):** ~25 hours
**Total to Full Feature Parity:** ~50 hours

---

## Quick Wins (Can Ship Immediately)

These features are already mostly built:

1. **System Cache Cleanup** - ✅ Module complete
2. **Duplicate Finder** - ✅ Module complete
3. **Menu Bar Widget** - ✅ UI complete
4. **System Monitoring** - ✅ CPU/RAM/Battery/Network
5. **Maintenance UI** - ✅ View exists, needs backend

---

## Recommended First Sprint

**Goal:** Ship MVP with core cleanup features

1. ✅ System Cache Cleanup (done)
2. ✅ Duplicate Finder (done)
3. 🔲 Browser Cleanup (highest impact)
4. 🔲 Large Files Finder (quick win)
5. 🔲 Wire up Maintenance backends

This gives users immediate value and covers the most common cleanup needs.
