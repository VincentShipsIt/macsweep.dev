## Task: Safety & Protected Paths Module

**ID:** task-003
**Label:** Safety Module
**Description:** Implement comprehensive safety checks to prevent accidental deletion of critical files.
**Type:** Feature
**Status:** Done
**Priority:** Critical
**Created:** 2026-01-15
**Updated:** 2026-01-19
**PRD:** [PRD-001](../PRDS/PRD-001-macsweep-native.md)

---

## Additional Notes

### Estimated Effort
3-4 hours

### Deliverables

#### 1. ProtectedPaths
```swift
struct ProtectedPaths {
    /// Paths that should NEVER be deleted
    static let neverDelete: Set<String> = [
        // System
        "/System", "/Applications", "/usr", "/bin", "/sbin",
        "/Library", "/private/var", "/cores",

        // User critical
        "~/Documents", "~/Desktop", "~/Pictures", "~/Movies", "~/Music",
        "~/Downloads",  // Configurable

        // Credentials
        "~/.ssh", "~/.gnupg", "~/.aws", "~/.kube", "~/.config",

        // App data (not caches)
        "~/Library/Preferences",
        "~/Library/Keychains",
        "~/Library/Mail",
        "~/Library/Messages",
        "~/Library/Calendars",
        "~/Library/Contacts",
        "~/Library/Safari/Bookmarks.plist",

        // Cloud
        "~/Library/Mobile Documents",  // iCloud
        "~/Library/CloudStorage"
    ]

    /// File patterns that indicate sensitive data
    static let sensitivePatterns: [String] = [
        "*.key", "*.pem", "*.p12", "*.pfx",
        "credentials.json", "secrets.json",
        "*.keychain", "*.keychain-db",
        "logins.json", "cookies.sqlite",
        "id_rsa", "id_ed25519", "id_ecdsa"
    ]

    /// Directories that are safe to clean (whitelist approach)
    static let safeCacheRoots: Set<String> = [
        "~/Library/Caches",
        "~/Library/Logs",
        "~/Library/Application Support/CrashReporter"
    ]
}
```

#### 2. SafetyChecker Actor
```swift
actor SafetyChecker {
    func validate(_ url: URL) -> ValidationResult
    func validateBatch(_ urls: [URL]) -> [URL: ValidationResult]

    enum ValidationResult {
        case safe
        case protected(reason: String)
        case sensitive(pattern: String)
        case outsideHome
        case symlink(target: URL)
    }
}
```

#### 3. Deletion Safeguards
```swift
struct DeletionGuard {
    /// Maximum total size for single operation (default 10GB)
    var maxTotalSize: Int64 = 10_737_418_240

    /// Require confirmation for operations over this size
    var confirmationThreshold: Int64 = 1_073_741_824  // 1GB

    /// Dry-run by default
    var dryRunDefault: Bool = true

    func preflightCheck(items: [CleanupItem]) -> PreflightResult
}
```

### Technical Notes

#### Path Expansion
```swift
extension String {
    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }
}
```

#### Symlink Validation
```swift
func isSymlinkSafe(_ url: URL) throws -> Bool {
    let resourceValues = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard resourceValues.isSymbolicLink == true else { return true }

    let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    let targetURL = URL(fileURLWithPath: target)

    // Ensure symlink doesn't point outside home
    let home = FileManager.default.homeDirectoryForCurrentUser
    return targetURL.path.hasPrefix(home.path)
}
```

### Acceptance Criteria
- [ ] All protected paths are defined
- [ ] Sensitive file patterns are detected
- [ ] Symlinks are validated
- [ ] Size limits are enforced
- [ ] Validation is fast (< 1ms per item)

### Dependencies
- TASK-001 (Project Setup)

### Test Cases
1. Protected path returns `.protected`
2. Sensitive file (*.key) returns `.sensitive`
3. Symlink pointing to /etc returns `.outsideHome`
4. ~/Library/Caches/com.app returns `.safe`
