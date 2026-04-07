# MacSweep Architecture

## Tech Stack
- **Swift 5.9+** - Core language
- **SwiftUI** - Declarative UI framework
- **Combine** - Reactive state management
- **Swift Concurrency** - Async/await for scanning

## Module System

All cleanup modules conform to the `ScanModule` protocol:

```swift
protocol ScanModule {
    var id: String { get }
    var name: String { get }
    var description: String { get }
    var icon: String { get }

    func scan() async throws -> [CleanupItem]
    func clean(_ items: [CleanupItem], dryRun: Bool) async throws -> Int
}
```

## Directory Structure
```
MacSweep/
├── Sources/
│   ├── App/                    # App entry point, AppState
│   ├── Core/
│   │   ├── Scanning/
│   │   │   ├── ScanEngine.swift
│   │   │   └── Modules/       # SystemCache, Browser, DevTools, etc.
│   │   ├── Safety/            # SafetyChecker, protected paths
│   │   ├── Storage/           # DiskAnalyzer
│   │   ├── Services/          # AI, Keychain, Homebrew services
│   │   ├── Monitoring/        # SystemMonitor (CPU, RAM, disk)
│   │   ├── Permissions/       # Full Disk Access management
│   │   ├── Shredder/          # Secure file deletion
│   │   └── Headless/          # Headless service mode
│   └── Features/
│       ├── Dashboard/         # ContentView, main navigation
│       ├── BrowserCleanup/    # Browser cleanup UI
│       ├── DevTools/          # Developer tools cleanup UI
│       ├── NetworkCleanup/    # WiFi, SSH, DNS cleanup UI
│       └── ...                # Other feature views
├── Tests/                     # Unit tests
├── Package.swift              # SPM configuration
└── MacSweep.xcodeproj         # Xcode project
```

## Safety
- Dry-run by default
- Protected paths list (Documents, Desktop, .ssh, .aws, etc.)
- Size limit warnings
- Confirmation prompts
- Per-module safety filtering (isProtected)
