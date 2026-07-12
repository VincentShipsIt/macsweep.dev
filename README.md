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

**Website:** [macsweep.dev](https://macsweep.dev)

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

### Review before you clean

<p align="center">
  <img src="scripts/screenshots/26-system-junk-results.png" alt="Reviewing selected system junk before cleanup" width="49%">
  <img src="scripts/screenshots/27-large-old-files-results.png" alt="Finding and selecting large old files" width="49%">
</p>

### AI-assisted analysis

<p align="center">
  <img src="scripts/screenshots/02-assistant.png" alt="macsweep.dev AI assistant with suggested cleanup tasks" width="100%">
</p>

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

Then install the stable MacSweep app and CLI:

brew tap vincentshipsit/tap
brew trust --formula vincentshipsit/tap/macsweep
brew install --cask vincentshipsit/tap/macsweep
macsweep version

Do not run any cleanup, delete, apply, shred, uninstall, or maintenance commands.
When the install is done, tell me the installed CLI version, confirm MacSweep.app
is installed, and suggest `macsweep dry-run` as the first safe command.
```

### Homebrew (GUI + CLI, recommended)

MacSweep is distributed from the shared `vincentshipsit/tap`.

For the full desktop install, install the cask. It installs `MacSweep.app` and
pulls in the `macsweep` CLI formula as a dependency:

```bash
brew tap vincentshipsit/tap
brew trust --formula vincentshipsit/tap/macsweep   # required for the CLI formula
brew install --cask vincentshipsit/tap/macsweep     # installs GUI + CLI
```

Verify both entry points:

```bash
open -a MacSweep
macsweep version
```

Want only the headless CLI?

```bash
brew install --formula vincentshipsit/tap/macsweep
```

Prefer the bleeding edge from `master`:

```bash
brew install --formula --HEAD vincentshipsit/tap/macsweep  # CLI only
```

Keep the full desktop install current:

```bash
brew update
brew upgrade --cask vincentshipsit/tap/macsweep
brew upgrade --formula vincentshipsit/tap/macsweep
```

The GUI also checks for signed updates with Sparkle and exposes **MacSweep ›
Check for Updates…**. Sparkle updates the app bundle; the separately packaged CLI
continues to update through Homebrew.

The CLI formula still supports self-update helpers:

```bash
macsweep self-update           # prints the CLI formula upgrade command
macsweep self-update --yes     # upgrades the CLI formula now
```

The first install may take a few minutes because Homebrew compiles the Swift CLI
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

### Testing & QA

```bash
zsh scripts/test.sh        # unit suite (swift-testing; works on CLT-only hosts)
zsh scripts/e2e.sh         # CLI e2e safety smoke suite (non-destructive, self-contained fixtures)
zsh scripts/coverage.sh    # unit suite with coverage + safety-critical coverage floors
zsh scripts/render-screenshots.sh   # render every GUI state to scripts/screenshots/ for visual QA
```

CI runs the unit suite with coverage floors and the e2e smoke suite on every
push/PR, renders GUI snapshots as a PR artifact, and repeats e2e + coverage on
a daily schedule (`.github/workflows/nightly.yml`).

### Release signing for app updates

The protected GitHub `release` environment must contain both Sparkle values:

- Variable `SPARKLE_PUBLIC_ED_KEY`: the base64 Ed25519 public key embedded in
  release builds.
- Secret `SPARKLE_PRIVATE_ED_KEY`: the matching base64 private seed exported by
  Sparkle's `generate_keys` tool.

The private key must be backed up outside GitHub and must never be committed.
On every version tag, the release workflow verifies the embedded public key,
signs the notarized app ZIP, generates `appcast.xml`, and publishes both files
to the GitHub release. `scripts/release.sh bump X.Y.Z` advances both the visible
version and Sparkle's bundle build version.

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

- `~/Library/Application Support/macsweep.dev/assistant/providers.toml`
- `~/Library/Application Support/macsweep.dev/watchlists/watchlists.toml`
- `~/Library/Application Support/macsweep.dev/watchlists/README.md`

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
- **Sparkle 2** - Signed in-app updates for the macOS app

## License

MIT
