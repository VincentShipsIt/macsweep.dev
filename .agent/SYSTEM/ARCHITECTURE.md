# MacSweep Architecture

## Tech Stack
- **Python 3.11+** - Core language
- **Typer** - CLI framework
- **Textual** - TUI framework
- **Rich** - Terminal formatting

## Module System

All cleanup modules inherit from `CleanupModule` base class:

```python
class CleanupModule(ABC):
    name: str
    description: str
    category: str

    async def scan(self) -> AsyncIterator[CleanupItem]: ...
    async def clean(self, items, dry_run=True) -> int: ...
```

## Directory Structure
```
src/macsweep/
├── cli.py              # Typer CLI commands
├── tui/                # Textual TUI
├── modules/            # Cleanup modules
│   ├── base.py         # Base class
│   ├── service_workers/
│   ├── browsers/
│   └── system/
├── analyzers/          # Large files, unused apps
├── monitors/           # RAM/CPU monitoring
├── core/               # Safety, config
└── utils/              # Helpers
```

## Safety
- Dry-run by default
- Protected paths list
- Size limit warnings
- Confirmation prompts
