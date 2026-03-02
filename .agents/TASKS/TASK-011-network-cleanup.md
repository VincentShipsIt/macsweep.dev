## Task: Network Cleanup Module

**ID:** task-011
**Label:** Network Cleanup
**Description:** Clean network-related files and caches (inspired by MacOS-Maid).
**Type:** Feature
**Status:** AI Review
**Priority:** Low
**Order:** 1
**Created:** 2026-01-15
**Updated:** 2026-01-19
**PRD:** [PRD-001](../PRDS/PRD-001-macsweep-native.md)

---

## Additional Notes

### Estimated Effort
2-3 hours

### Deliverables

#### 1. NetworkCleanupModule
```swift
struct NetworkCleanupModule: ScanModule {
    let id = "network-cleanup"
    let name = "Network Cleanup"
    let description = "WiFi networks, SSH known hosts, DNS cache"
    let icon = "wifi"

    func scan() async throws -> [CleanupItem]
}
```

#### 2. WiFi Network Management
```swift
struct WiFiNetworkManager {
    /// List all saved WiFi networks
    func savedNetworks() async throws -> [SavedNetwork]

    /// Remove specific networks
    func removeNetworks(_ ssids: [String]) async throws

    struct SavedNetwork: Identifiable {
        let id: String  // SSID
        let ssid: String
        let securityType: String
        let lastConnected: Date?
    }
}

// Uses networksetup command
// networksetup -listpreferredwirelessnetworks en0
// networksetup -removepreferredwirelessnetwork en0 "NetworkName"
```

#### 3. SSH Known Hosts
```swift
struct SSHKnownHostsManager {
    private let knownHostsPath = URL.homeDirectory.appending(path: ".ssh/known_hosts")

    /// Parse known_hosts file
    func entries() throws -> [KnownHostEntry]

    /// Remove specific entries
    func removeEntries(_ hosts: [String]) throws

    struct KnownHostEntry: Identifiable {
        let id: String
        let host: String
        let keyType: String
        let fingerprint: String
    }
}
```

#### 4. DNS Cache
```swift
struct DNSCacheManager {
    /// Flush DNS cache (requires admin)
    func flush() async throws {
        // sudo dscacheutil -flushcache
        // sudo killall -HUP mDNSResponder
    }

    /// Check if DNS cache can be flushed
    var canFlush: Bool {
        // Check for admin privileges or ask for password
    }
}
```

#### 5. Network Preferences
```swift
struct NetworkPreferencesCleanup {
    let targets: [URL] = [
        .libraryDirectory.appending(path: "Preferences/SystemConfiguration"),
        .libraryDirectory.appending(path: "Caches/com.apple.networkserviceproxy")
    ]

    /// Note: System files, handle with extreme care
}
```

### Safety Considerations

| Target | Risk Level | Confirmation Required |
|--------|------------|----------------------|
| Old WiFi networks | Low | Yes |
| SSH known_hosts | Medium | Yes (warns about MITM) |
| DNS cache flush | Low | No |
| Network preferences | High | Double confirmation |

### Acceptance Criteria
- [x] Lists saved WiFi networks
- [x] Can remove individual networks
- [x] Parses known_hosts correctly
- [x] DNS flush works (with sudo)
- [x] Clear warnings about security implications

### Dependencies
- TASK-001 (Project Setup)

### Notes
- Requires admin for DNS flush
- WiFi removal uses `networksetup` CLI
- Known hosts removal is file manipulation
- Consider allowing users to "protect" certain SSIDs

---

## Implementation Summary

### Files Created
- `MacSweep/Sources/Features/NetworkCleanup/NetworkCleanupView.swift` - SwiftUI view with tabbed interface for WiFi, SSH, and DNS management

### Files Modified
- `MacSweep/Sources/Core/Scanning/Modules/NetworkModule.swift` - Enhanced with:
  - `DNSCacheManager` - Flush DNS cache with admin privileges via AppleScript
  - `WiFiInterfaceManager` - Dynamic WiFi interface detection
  - `NetworkCleanupSummary` - Summary statistics for network cleanup
  - Network service proxy cache scanning
  - Improved `WiFiNetworkManager` with protected SSIDs support and multi-interface support
- `MacSweep/Sources/App/AppState.swift` - Added `networkCleanup` Feature case
- `MacSweep/Sources/Features/Dashboard/ContentView.swift` - Added NetworkCleanupView to navigation

### Features Implemented
1. **WiFi Networks Tab**
   - Lists all saved WiFi networks
   - Shows currently connected network
   - Allows protecting networks from removal
   - Remove individual or multiple networks
   - Confirmation dialogs with warnings

2. **SSH Hosts Tab**
   - Lists all entries from ~/.ssh/known_hosts
   - Shows host algorithm (ssh-rsa, ed25519, etc.)
   - Identifies hashed hosts
   - Remove individual hosts or clear all
   - Creates backup before clearing all
   - Security warning about MITM attacks

3. **DNS & Cache Tab**
   - Flush DNS cache (with admin password prompt via AppleScript)
   - Shows network cache files that can be cleaned
   - Info boxes explaining admin privileges requirement

### Safety Features
- Confirmation dialogs before destructive actions
- Protection toggle for WiFi networks
- Backup creation before clearing SSH known_hosts
- Security warnings about MITM risks
- Admin privilege handling for DNS flush
