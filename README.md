# MacSweep

> [!WARNING]
> This project is under active development and is a work in progress.
> Features may be incomplete, APIs may change, and there may be bugs.
> Contributions and feedback welcome!

[![Swift 6.2+](https://img.shields.io/badge/Swift-6.2+-orange.svg)](https://swift.org)
[![macOS 26+](https://img.shields.io/badge/macOS-26+-blue.svg)](https://www.apple.com/macos/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A native macOS system cleaner with a SwiftUI app and a Homebrew-installable CLI.
Scan, clean, and optimize your Mac with safety-first defaults.

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

- macOS 26.0 (Tahoe) or later
- Homebrew for the recommended CLI install
- Swift 6.2+ / Xcode 26+ command-line tools for building from source
- Full Disk Access permission (for scanning protected folders)

## Installation

### Agent-first install

Paste this into a terminal-capable coding agent to have it install MacSweep for
you:

```text
Install MacSweep on this Mac.

First run these read-only checks:
- Confirm this Mac is running macOS 26.0 Tahoe or later with `sw_vers`.
- Check whether Homebrew is installed with `command -v brew`.
- Check whether Apple's command-line tools can find Swift with `xcrun --find swift`.

If macOS is older than 26.0, stop and explain that MacSweep cannot be installed.
If Homebrew is missing, stop and ask me before installing Homebrew from https://brew.sh.
If Apple's command-line tools are missing, run `xcode-select --install`, then wait for me to finish Apple's installer prompt before continuing.

Then install the stable MacSweep CLI:

brew tap vincentshipsit/tap
brew trust --formula vincentshipsit/tap/macsweep
brew install macsweep
macsweep version

Do not run any cleanup, delete, apply, shred, uninstall, or maintenance commands.
When the install is done, tell me the installed version and suggest `macsweep dry-run` as the first safe command.
```

### Homebrew (recommended)

MacSweep currently ships through Homebrew as the `macsweep` command-line tool,
built from source. No Apple Developer account or code signing is required for the
CLI install. A signed `.app` or DMG is not published yet.

The formula is distributed from the shared `vincentshipsit/tap`. Recent Homebrew
gates third-party formulae behind a trust check, so the install is:

```bash
brew tap vincentshipsit/tap
brew trust --formula vincentshipsit/tap/macsweep   # required for 3rd-party formulae
brew install macsweep                               # pinned stable release
```

Prefer the bleeding edge from `master`:

```bash
brew install --HEAD macsweep
```

Verify the install, then keep it current:

```bash
macsweep version
macsweep self-update           # prints the upgrade command
macsweep self-update --yes     # runs `brew upgrade` now
```

The first install may take a few minutes because Homebrew compiles the Swift
package locally. If Apple's command-line tools are missing, Homebrew or macOS may
prompt you to install them.

> [!NOTE]
> MacSweep used to be installed from this repo acting as its own tap
> (`vincentshipsit/macsweep`). It now lives in the shared
> [vincentshipsit/tap](https://github.com/VincentShipsIt/homebrew-tap). If you
> tapped the old path, migrate with:
> ```bash
> brew untap vincentshipsit/macsweep
> brew tap vincentshipsit/tap
> ```

### Build from Source

```bash
git clone https://github.com/VincentShipsIt/macsweep.git
cd macsweep/MacSweep
swift build -c release --product macsweep
```

To build the SwiftUI app, open `MacSweep.xcodeproj` in Xcode 26 or later and build
the app target.

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
