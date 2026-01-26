# MacSweep

[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14+-blue.svg)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A powerful native macOS system cleaner. Scan, clean, and optimize your Mac with a beautiful SwiftUI interface.

## Features

- **Smart Scan** - One-click deep scan for junk files
- **System Cleanup** - Remove caches, logs, and temporary files
- **Browser Cleanup** - Clean browser caches and service workers
- **Developer Tools** - Clean node_modules, DerivedData, Docker, and more
- **Large File Finder** - Discover files taking up the most space
- **Space Lens** - Visualize disk usage with an interactive chart
- **App Uninstaller** - Completely remove apps and their leftovers
- **File Shredder** - Securely delete sensitive files
- **Privacy** - Clear browsing history and sensitive data
- **Menu Bar Widget** - Quick access to system stats and actions
- **Real-time Monitoring** - CPU, RAM, disk, battery, and network stats

## Screenshots

*Coming soon*

## Requirements

- macOS 14.0 (Sonoma) or later
- Full Disk Access permission (for scanning protected folders)

## Installation

### Build from Source

```bash
git clone https://github.com/VincentShipsIt/macsweep.git
cd macsweep/MacSweep
swift build -c release
```

Or open `MacSweep.xcodeproj` in Xcode and build.

## Safety

MacSweep is designed with safety in mind:

- **Dry-run by default** - Always preview before deleting
- **Protected paths** - Critical directories are never touched:
  - `~/Documents`, `~/Desktop`, `~/Pictures`, `~/Downloads`
  - `~/.ssh`, `~/.gnupg`, `~/.aws`
  - `/System`, `/Applications`
- **Confirmation prompts** - Large deletions require explicit confirmation
- **Size limits** - Configurable max delete size (default 10GB)

## Tech Stack

- **SwiftUI** - Modern declarative UI
- **Combine** - Reactive state management
- **Swift Concurrency** - Async/await for scanning

## License

MIT
