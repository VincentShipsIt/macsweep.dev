# MacSweep - Agent Documentation

## Quick Links
- [Architecture](./SYSTEM/ARCHITECTURE.md)
- [Cleanup Targets](./SYSTEM/CLEANUP_TARGETS.md)

## Project Overview
MacSweep is a native macOS system cleaner built with Swift and SwiftUI. It provides disk cleanup, app management, and system optimization through a modern declarative UI.

## Build & Test
```bash
cd MacSweep
swift build              # Build the project
swift test               # Run tests
swift build -c release   # Release build
```

Or open `MacSweep.xcodeproj` in Xcode and build.

## Key Files
- `MacSweep/Sources/App/` - App entry point and state
- `MacSweep/Sources/Core/Scanning/` - Cleanup scan modules
- `MacSweep/Sources/Core/Safety/` - Safety mechanisms
- `MacSweep/Sources/Core/Storage/` - Disk analysis
- `MacSweep/Sources/Features/` - SwiftUI feature views
- `MacSweep/Tests/` - Unit tests
