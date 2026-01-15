"""Path utilities for MacSweep."""

from pathlib import Path


def expand_path(path_str: str) -> Path:
    """Expand ~ and environment variables in path."""
    return Path(path_str).expanduser()


def get_dir_size(path: Path) -> int:
    """Calculate total size of a directory recursively."""
    total = 0
    try:
        for entry in path.rglob("*"):
            if entry.is_file():
                try:
                    total += entry.stat().st_size
                except (PermissionError, OSError, FileNotFoundError):
                    pass
    except (PermissionError, OSError):
        pass
    return total


def safe_iterdir(path: Path):
    """Safely iterate directory, handling permission errors."""
    try:
        yield from path.iterdir()
    except (PermissionError, OSError):
        return


def safe_glob(path: Path, pattern: str):
    """Safely glob a path, handling permission errors."""
    try:
        yield from path.glob(pattern)
    except (PermissionError, OSError):
        return
