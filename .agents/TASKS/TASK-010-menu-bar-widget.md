## Task: Menu Bar Widget

**ID:** task-010
**Label:** Menu Bar Widget
**Description:** Quick-access menu bar widget showing disk status and enabling quick scans.
**Type:** Feature
**Status:** Backlog
**Priority:** High
**Created:** 2026-01-15
**Updated:** 2026-01-19
**PRD:** [PRD-001](../PRDS/PRD-001-macsweep-native.md)

---

## Additional Notes

### Estimated Effort
3-4 hours

### Deliverables

#### 1. App Entry Point with MenuBarExtra
```swift
@main
struct MacSweepApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        // Menu bar widget
        MenuBarExtra("MacSweep", systemImage: "broom") {
            MenuBarView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)  // Allows larger content

        // Main window
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
    }
}
```

#### 2. MenuBarView Content
```swift
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(spacing: 12) {
            // Storage summary
            StorageSummaryView()

            Divider()

            // Quick actions
            Button("Quick Scan") {
                Task { await appState.quickScan() }
            }
            .disabled(appState.isScanning)

            // Last cleanup info
            if let lastCleanup = appState.lastCleanup {
                Text("Last cleanup: \(lastCleanup.date, style: .relative)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Freed \(lastCleanup.bytesFreed.formatted(.byteCount(style: .file)))")
                    .font(.caption)
            }

            Divider()

            Button("Open MacSweep") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding()
        .frame(width: 240)
    }
}
```

#### 3. Storage Summary View
```swift
struct StorageSummaryView: View {
    @State private var diskUsage: DiskUsage?

    var body: some View {
        VStack(spacing: 8) {
            if let usage = diskUsage {
                // Progress bar
                ProgressView(value: usage.usedPercentage)
                    .progressViewStyle(.linear)
                    .tint(usage.usedPercentage > 0.9 ? .red : .blue)

                // Stats
                HStack {
                    VStack(alignment: .leading) {
                        Text("Used")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(usage.used.formatted(.byteCount(style: .file)))
                            .font(.headline)
                    }

                    Spacer()

                    VStack(alignment: .trailing) {
                        Text("Free")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(usage.free.formatted(.byteCount(style: .file)))
                            .font(.headline)
                            .foregroundColor(usage.free < 10_000_000_000 ? .red : .primary)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task {
            diskUsage = await getDiskUsage()
        }
    }
}
```

#### 4. DiskUsage Model
```swift
struct DiskUsage {
    let total: Int64
    let used: Int64
    let free: Int64

    var usedPercentage: Double {
        Double(used) / Double(total)
    }

    static func current() async -> DiskUsage? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]) else { return nil }

        let total = values.volumeTotalCapacity ?? 0
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        return DiskUsage(
            total: Int64(total),
            used: Int64(total - free),
            free: Int64(free)
        )
    }
}
```

#### 5. Menu Bar Icon States
```swift
enum MenuBarIconState {
    case idle           // broom
    case scanning       // broom.fill with animation
    case warning        // exclamationmark.triangle (low space)
    case success        // checkmark.circle (just cleaned)

    var systemImage: String {
        switch self {
        case .idle: return "broom"
        case .scanning: return "broom.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        }
    }
}
```

### Acceptance Criteria
- [ ] Menu bar icon appears on launch
- [ ] Shows disk usage with progress bar
- [ ] Quick scan button works
- [ ] Shows last cleanup stats
- [ ] Opens main window correctly
- [ ] Quit works
- [ ] Icon changes during scan

### Dependencies
- TASK-001 (Project Setup)
- TASK-002 (Core Scanning Engine)

### Design Notes
- Keep it minimal - main features in full app
- Use `.menuBarExtraStyle(.window)` for better layout
- Refresh disk usage periodically (every 60s)
- Consider adding keyboard shortcut for quick scan
