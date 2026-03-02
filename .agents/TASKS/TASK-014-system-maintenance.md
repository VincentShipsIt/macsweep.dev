## Task: System Maintenance Module

**ID:** task-014
**Label:** System Maintenance
**Description:** General macOS system maintenance tasks (Spotlight, permissions, fonts, etc.).
**Type:** Feature
**Status:** Backlog
**Priority:** Low
**Created:** 2026-01-15
**Updated:** 2026-01-19
**PRD:** [PRD-001](../PRDS/PRD-001-macsweep-native.md)

---

## Additional Notes

### Estimated Effort
2-3 hours

### Deliverables

#### 1. SystemMaintenanceModule
```swift
struct SystemMaintenanceModule {
    /// Available maintenance tasks
    enum MaintenanceTask: CaseIterable {
        case flushDNS
        case rebuildSpotlight
        case rebuildLaunchServices
        case clearFontCaches
        case purgeDiskCache
        case verifyDisk
    }

    func execute(_ task: MaintenanceTask) async throws
}
```

#### 2. DNS Cache Flush
```swift
func flushDNS() async throws {
    // Requires sudo
    let commands = [
        "sudo dscacheutil -flushcache",
        "sudo killall -HUP mDNSResponder"
    ]
    // Execute with admin privileges
}
```

#### 3. Rebuild Spotlight Index
```swift
func rebuildSpotlight() async throws {
    // Warning: This can take hours!
    let commands = [
        "sudo mdutil -E /",  // Erase and rebuild
        "sudo mdutil -i on /"  // Enable indexing
    ]
}

func spotlightStatus() async throws -> SpotlightStatus {
    // mdutil -s /
    struct SpotlightStatus {
        let indexingEnabled: Bool
        let indexStatus: String
    }
}
```

#### 4. Rebuild Launch Services Database
```swift
func rebuildLaunchServices() async throws {
    // Fixes "Open With" menu issues
    let command = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user"
    // May need to restart Finder
}
```

#### 5. Clear Font Caches
```swift
func clearFontCaches() async throws {
    let commands = [
        "sudo atsutil databases -remove",
        "sudo atsutil server -shutdown",
        "sudo atsutil server -ping"  // Restart font server
    ]
}
```

#### 6. Purge Disk Cache
```swift
func purgeDiskCache() async throws {
    // Frees inactive memory
    let command = "sudo purge"
}
```

#### 7. Verify Disk
```swift
func verifyDisk() async throws -> DiskVerificationResult {
    // Non-destructive check
    let command = "diskutil verifyVolume /"

    struct DiskVerificationResult {
        let isHealthy: Bool
        let messages: [String]
    }
}
```

### Maintenance Tasks Summary

| Task | Requires Sudo | Time | Notes |
|------|--------------|------|-------|
| Flush DNS | Yes | Instant | Safe |
| Rebuild Spotlight | Yes | Hours | Intensive |
| Rebuild Launch Services | No | Minutes | May need Finder restart |
| Clear Font Caches | Yes | Seconds | May need logout |
| Purge Disk Cache | Yes | Instant | Safe |
| Verify Disk | No | Minutes | Read-only |

### Acceptance Criteria
- [ ] Each task executes correctly
- [ ] Sudo prompts handled properly
- [ ] Progress/status for long-running tasks
- [ ] Clear warnings about time requirements
- [ ] Error handling for each task

### Dependencies
- TASK-001 (Project Setup)

### Notes
- Most tasks require admin privileges
- Some tasks require logout/restart to take effect
- Spotlight rebuild is very intensive - warn user
- Consider scheduling maintenance during idle time
