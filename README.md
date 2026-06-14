# MacSweep

> [!WARNING]
> This project is under active development and is a work in progress.
> Features may be incomplete, APIs may change, and there may be bugs.
> Contributions and feedback welcome!

[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14+-blue.svg)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A powerful native macOS system cleaner. Scan, clean, and optimize your Mac with a beautiful SwiftUI interface.

## Features

- **Smart Scan** - One-click deep scan for junk files
- **System Cleanup** - Remove caches, logs, and temporary files
- **Browser Cleanup** - Clean browser caches and service workers
- **Developer Tools** - Clean node_modules, DerivedData, Docker, and more
- **AI Assistant** - Use Codex or Claude locally to plan scans and maintain persistent watchlists
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

### Homebrew (recommended)

MacSweep ships as a CLI built from source — no Apple Developer account or code
signing required. Recent Homebrew gates third-party taps behind a trust check, so
the install is three commands:

```bash
brew tap VincentShipsIt/macsweep https://github.com/VincentShipsIt/macsweep
brew trust --formula vincentshipsit/macsweep/macsweep   # required for 3rd-party taps
brew install VincentShipsIt/macsweep/macsweep           # pinned stable release
```

Prefer the bleeding edge from `master`:

```bash
brew install --HEAD VincentShipsIt/macsweep/macsweep
```

Verify the install, then keep it current:

```bash
macsweep version
macsweep self-update           # prints the upgrade command
macsweep self-update --yes     # runs `brew upgrade` now
```

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
- **Assistant guardrails** - AI-planned scans still pass through MacSweep safety checks before cleanup

## Assistant Config

MacSweep seeds persistent assistant config under:

- `~/Library/Application Support/MacSweep/assistant/providers.toml`
- `~/Library/Application Support/MacSweep/watchlists/watchlists.toml`
- `~/Library/Application Support/MacSweep/watchlists/README.md`

The TOML files are the source of truth for provider defaults and saved watchlists. The markdown file explains the watchlist format and safety boundaries.

## Privacy & Network

MacSweep includes an optional AI Analysis feature that can send directory metadata
(names and sizes, not file contents) to the Anthropic API for intelligent cache
identification. This feature:

- Is **opt-in** — requires you to provide your own API key
- Never sends file contents, only directory names and sizes
- Can be used without AI (deterministic scan works without an API key)
- API key is stored in your macOS Keychain, never in plaintext

## Tech Stack

- **SwiftUI** - Modern declarative UI
- **Combine** - Reactive state management
- **Swift Concurrency** - Async/await for scanning

## License

MIT
