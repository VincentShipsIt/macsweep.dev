# MacSweep - Agent Documentation

## Quick Links
- [Architecture](./SYSTEM/ARCHITECTURE.md)
- [Cleanup Targets](./SYSTEM/CLEANUP_TARGETS.md)

## Project Overview
MacSweep is a macOS system cleaner with CLI and TUI interfaces. Built with Python, Typer, Textual, and Rich.

## Commands
```bash
source .venv/bin/activate
macsweep scan                  # Scan for cleanup opportunities
macsweep clean --execute       # Clean (use --dry-run first)
macsweep service-workers       # Clean browser service workers
macsweep large-files           # Find large files
macsweep unused-apps           # Find unused applications
macsweep monitor               # Real-time system monitor
macsweep tui                   # Interactive TUI
```

## Development
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
ruff check src/                # Lint
ruff format src/               # Format
```

## Key Files
- `src/macsweep/cli.py` - CLI entry point
- `src/macsweep/tui/app.py` - TUI application
- `src/macsweep/modules/` - Cleanup modules
- `src/macsweep/core/safety.py` - Safety mechanisms
