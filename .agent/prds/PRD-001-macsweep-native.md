# PRD-001: MacSweep Native macOS App

## Overview
Open-source CleanMyMac replacement built with Swift + SwiftUI. Native macOS system utility for disk cleanup, app management, and system optimization.

## Target Users
- Mac power users who want control over their system
- Developers needing to clean build artifacts
- Users transitioning from CleanMyMac/DaisyDisk

## Distribution
- GitHub releases (primary)
- Homebrew cask
- NOT Mac App Store (sandbox limitations)

## Technical Requirements
- **Language:** Swift 5.9+
- **UI Framework:** SwiftUI
- **Minimum macOS:** 13.0 (Ventura)
- **Permissions:** Full Disk Access required
- **Sandbox:** Disabled (direct file system access)

## Feature Structure (CleanMyMac-style)

### Smart Scan (Main)
One-click scan that combines all cleanup modules for quick results.

### Cleanup Section
- **System Junk**: Caches, logs, crash reports
- **Mail Attachments**: Large email attachments
- **Trash Bins**: System and app trash folders

### Protection Section
- **Malware Removal**: Basic malware scanning (signature-based)
- **Privacy**: Browser history, cookies, sensitive data

### Speed Section
- **Optimization**: Memory management, CPU monitoring
- **Maintenance**: System tasks (DNS flush, Spotlight rebuild, permissions)

### Applications Section
- **Uninstaller**: Complete app removal with leftover detection
- **Updater**: Check for app updates
- **Extensions**: Browser and system extension management

### Files Section
- **Space Lens**: Visual disk usage (DaisyDisk-style)
- **Large & Old Files**: Find files by size and age
- **Shredder**: Secure file deletion
- **Duplicate Finder**: Find and remove duplicate files

---

## Feature Modules

### F1: System Cleanup
Clean system junk files to recover disk space.

**Targets:**
| Path | Description |
|------|-------------|
| ~/Library/Caches | User app caches |
| ~/Library/Logs | Application logs |
| ~/Library/Application Support/CrashReporter | Crash reports |
| /private/var/folders | System temp files |
| ~/Library/Saved Application State | App state snapshots |

**Safety:** Never delete active/locked files.

### F2: Browser Cleanup
Remove browser caches, history, and service workers.

**Browsers Supported:**
- Chrome (~/Library/Application Support/Google/Chrome)
- Safari (~/Library/Safari, ~/Library/Caches/com.apple.Safari)
- Firefox (~/Library/Application Support/Firefox)
- Brave (~/Library/Application Support/BraveSoftware)
- Arc (~/Library/Application Support/Arc)
- Edge (~/Library/Application Support/Microsoft Edge)

**Cleanup Options:**
- Cache files
- Service workers
- LocalStorage (opt-in, warns about data loss)
- Cookies (opt-in)

### F3: App Uninstaller
Complete app removal with leftover detection.

**Capabilities:**
- List all installed apps (/Applications, ~/Applications)
- Show app size and last used date
- Detect leftover files after manual uninstall
- Remove app bundle + all associated files

**Leftover Locations:**
- ~/Library/Application Support/{AppName}
- ~/Library/Preferences/{BundleID}.plist
- ~/Library/Caches/{BundleID}
- ~/Library/Logs/{AppName}
- ~/Library/Containers/{BundleID}
- ~/Library/Saved Application State/{BundleID}.savedState

### F4: Storage Visualizer
Visual disk usage analysis (DaisyDisk-style).

**Features:**
- Sunburst or treemap visualization
- Click to drill down into folders
- Color-coded by file type
- Quick delete from visualization
- Export report

### F5: Developer Tools
Clean development build artifacts.

**Targets:**
| Directory | Description | Project Marker |
|-----------|-------------|----------------|
| node_modules | npm/yarn/pnpm packages | package.json |
| DerivedData | Xcode build data | *.xcodeproj, *.xcworkspace |
| .build | Swift PM build | Package.swift |
| Pods | CocoaPods | Podfile |
| target | Rust/Cargo build | Cargo.toml |
| __pycache__ | Python bytecode | *.py |
| .gradle | Gradle cache | build.gradle |
| vendor/bundle | Ruby gems | Gemfile |
| .next | Next.js build | next.config.js |
| dist | Build output | various |

### F6: Large Files Finder
Find and remove large files consuming disk space.

**Features:**
- Configurable threshold (default 100MB)
- Sort by size, date, type
- Quick Look preview
- Batch selection and delete
- Exclude system files

### F7: Menu Bar Widget
Quick access system tray widget.

**Displays:**
- Current disk usage (used/free/total)
- Last cleanup date and space recovered
- Quick scan button
- Open main app

### F8: Network Cleanup (from MacOS-Maid)
Clean network-related files.

**Targets:**
- Saved WiFi networks (optional, preserves specified SSIDs)
- ~/.ssh/known_hosts (with confirmation)
- DNS cache (flush)

### F9: Package Manager Cleanup
Clean package manager caches.

**Targets:**
- Homebrew: `brew cleanup`, remove old versions
- Ruby gems: clean unused gems
- pip: clear pip cache
- npm: clear npm cache

### F10: Docker Cleanup
Clean Docker resources.

**Targets:**
- Stopped containers
- Dangling images
- Unused volumes
- Build cache

### F11: Memory Management
System memory optimization.

**Features:**
- Display current memory usage
- Purge inactive memory (sudo purge)
- Show memory-heavy processes

### F12: System Maintenance
General system maintenance tasks.

**Features:**
- Rebuild Spotlight index
- Repair disk permissions (legacy)
- Flush DNS cache
- Clear font caches
- Rebuild Launch Services database

## UI Design Principles

1. **Scan First:** Always show what will be deleted before deletion
2. **Dry Run Default:** No destructive actions without explicit confirmation
3. **Size Transparency:** Show exactly how much space each item uses
4. **Undo Warning:** Clearly communicate that deletion is permanent
5. **Progress Feedback:** Real-time progress for long operations

## Success Metrics
- Scan completes in < 30 seconds for typical user
- Can recover 5GB+ on average Mac
- Zero accidental data loss (safety checks work)
- < 50MB app size

## Open Source Considerations
- MIT license
- Clear contribution guidelines
- Automated builds via GitHub Actions
- Signed and notarized releases
