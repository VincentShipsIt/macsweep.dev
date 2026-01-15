# MacSweep

[![Python 3.11+](https://img.shields.io/badge/python-3.11+-blue.svg)](https://www.python.org/downloads/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Status: Active Development](https://img.shields.io/badge/status-active%20development-brightgreen.svg)]()
[![macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)](https://www.apple.com/macos/)
[![Code style: ruff](https://img.shields.io/badge/code%20style-ruff-000000.svg)](https://github.com/astral-sh/ruff)

A powerful macOS system cleaner built with Python. Scan, clean, and optimize your Mac from the terminal.

## Features

- **System Scan** - Find cache files, logs, and junk across your system
- **Service Worker Cleaner** - Remove browser service workers (Brave, Chrome, Safari, Discord, Slack, and 15+ more)
- **Large File Finder** - Discover files taking up the most space
- **Unused App Analyzer** - Find applications you haven't used recently (via Spotlight metadata)
- **System Monitor** - Real-time RAM and CPU monitoring
- **Interactive TUI** - Beautiful terminal interface built with Textual
- **Safety First** - Dry-run by default, protected paths, confirmation prompts

## Installation

```bash
git clone https://github.com/decod3rs/macsweep.git
cd macsweep
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

## Quick Start

```bash
# Scan your system
macsweep scan

# Preview what would be cleaned
macsweep clean --dry-run

# Actually clean (with confirmation)
macsweep clean --execute
```

## Commands

| Command | Description |
|---------|-------------|
| `macsweep scan` | Scan system for cleanup opportunities |
| `macsweep clean` | Clean up items (--dry-run by default) |
| `macsweep service-workers` | Clean browser service workers |
| `macsweep large-files` | Find large files (--min-size 100MB) |
| `macsweep unused-apps` | Find apps not used in X days (--days 90) |
| `macsweep monitor` | Real-time system monitor |
| `macsweep tui` | Launch interactive TUI |

You can also use `ms` as a shortcut: `ms scan`, `ms clean`, etc.

## What Gets Cleaned

### Service Workers
- **Browsers**: Brave, Chrome, Chromium, Arc, Edge, Opera, Vivaldi
- **Electron Apps**: Discord, Slack, WhatsApp, VS Code, Cursor, Notion, Figma, Telegram, Spotify, and more

### System Caches
- `~/Library/Caches/` - Application caches
- `~/Library/Logs/` - User logs
- `~/Library/Saved Application State/`
- Crash reports and diagnostic logs

### Browser Data
- Cache, Code Cache, GPUCache
- ShaderCache, optimization data

## Safety

MacSweep is designed with safety in mind:

- **Dry-run by default** - Always preview before deleting
- **Protected paths** - Critical directories are never touched:
  - `~/Documents`, `~/Desktop`, `~/Pictures`
  - `~/.ssh`, `~/.gnupg`
  - `/System`, `/Applications`
- **Confirmation prompts** - Large deletions require explicit confirmation
- **Size limits** - Warns when deleting more than 10GB

## Development

```bash
# Install dev dependencies
pip install -e ".[dev]"

# Lint
ruff check src/

# Format
ruff format src/

# Type check
mypy src/
```

## Tech Stack

- [Typer](https://typer.tiangolo.com/) - CLI framework
- [Textual](https://textual.textualize.io/) - TUI framework
- [Rich](https://rich.readthedocs.io/) - Terminal formatting

## License

MIT
