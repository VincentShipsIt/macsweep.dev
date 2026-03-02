## Task: Project Setup

**ID:** task-001
**Label:** Project Setup
**Description:** Create the foundational Swift/SwiftUI project structure for MacSweep native macOS app.
**Type:** Chore
**Status:** Done
**Priority:** Critical
**Created:** 2026-01-15
**Updated:** 2026-01-19
**PRD:** [PRD-001](../PRDS/PRD-001-macsweep-native.md)

---

## Additional Notes

### Estimated Effort
2-3 hours

### Deliverables

#### 1. Directory Structure
```
MacSweep/
├── MacSweep/
│   ├── App/
│   ├── Features/
│   ├── Core/
│   └── Resources/
├── MacSweepTests/
└── Package.swift (or .xcodeproj)
```

#### 2. Core Files
- [ ] MacSweepApp.swift - @main entry with MenuBarExtra
- [ ] AppState.swift - ObservableObject for global state
- [ ] ContentView.swift - Main window view

#### 3. Configuration
- [ ] Info.plist with required permissions
- [ ] Entitlements (hardened runtime, no sandbox)
- [ ] App icon (placeholder)

#### 4. Build Configuration
- [ ] Package.swift OR Xcode project
- [ ] Debug and Release schemes
- [ ] Code signing configuration

### Technical Notes

#### MenuBarExtra Setup (macOS 13+)
```swift
@main
struct MacSweepApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("MacSweep", systemImage: "broom") {
            MenuBarView()
                .environmentObject(appState)
        }

        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }
}
```

#### Required Entitlements
```xml
<key>com.apple.security.app-sandbox</key>
<false/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

### Acceptance Criteria
- [ ] App launches with menu bar icon
- [ ] Main window opens
- [ ] Can access ~/Library without sandbox restrictions
- [ ] Builds without warnings

### Dependencies
None (first task)

### References
- [Pearcleaner project structure](https://github.com/alienator88/Pearcleaner)
- [MenuBarExtra documentation](https://developer.apple.com/documentation/swiftui/menubarextra)
