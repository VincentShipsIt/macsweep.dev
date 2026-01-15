"""Base classes for cleanup modules."""

from abc import ABC, abstractmethod
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class CleanupItem:
    """Represents a single item that can be cleaned."""

    path: Path
    size: int
    category: str
    subcategory: str
    description: str
    safe_to_delete: bool = True
    requires_confirmation: bool = False

    def __str__(self) -> str:
        return f"{self.description} ({self.format_size()})"

    def format_size(self) -> str:
        """Format size in human-readable format."""
        if self.size < 1024:
            return f"{self.size} B"
        elif self.size < 1024 * 1024:
            return f"{self.size / 1024:.1f} KB"
        elif self.size < 1024 * 1024 * 1024:
            return f"{self.size / (1024 * 1024):.1f} MB"
        else:
            return f"{self.size / (1024 * 1024 * 1024):.2f} GB"


@dataclass
class ScanResult:
    """Result from scanning a module."""

    module_name: str
    items: list[CleanupItem] = field(default_factory=list)
    total_size: int = 0
    error: str | None = None

    def __post_init__(self) -> None:
        if self.items and self.total_size == 0:
            self.total_size = sum(item.size for item in self.items)


class CleanupModule(ABC):
    """Base class for all cleanup modules."""

    name: str = "Unknown"
    description: str = ""
    category: str = "General"
    safe_by_default: bool = True
    requires_full_disk_access: bool = False

    @abstractmethod
    async def scan(self) -> AsyncIterator[CleanupItem]:
        """Scan for cleanable items. Yields items as found."""
        yield  # type: ignore

    async def clean(self, items: list[CleanupItem], dry_run: bool = True) -> int:
        """Clean specified items. Returns bytes freed."""
        if dry_run:
            return sum(item.size for item in items)

        bytes_freed = 0
        for item in items:
            if not item.safe_to_delete:
                continue
            try:
                if item.path.is_dir():
                    bytes_freed += self._remove_directory(item.path)
                else:
                    bytes_freed += item.path.stat().st_size
                    item.path.unlink()
            except (PermissionError, OSError):
                pass
        return bytes_freed

    def _remove_directory(self, path: Path) -> int:
        """Remove a directory and return bytes freed."""
        import shutil

        size = self._get_dir_size(path)
        shutil.rmtree(path, ignore_errors=True)
        return size

    def _get_dir_size(self, path: Path) -> int:
        """Calculate total size of a directory."""
        total = 0
        try:
            for entry in path.rglob("*"):
                if entry.is_file():
                    try:
                        total += entry.stat().st_size
                    except (PermissionError, OSError):
                        pass
        except (PermissionError, OSError):
            pass
        return total

    def is_available(self) -> bool:
        """Check if this module can run (e.g., app installed)."""
        return True

    async def get_scan_result(self) -> ScanResult:
        """Convenience method to get full scan result."""
        items: list[CleanupItem] = []
        try:
            async for item in self.scan():
                items.append(item)
        except PermissionError as e:
            return ScanResult(
                module_name=self.name,
                items=items,
                error=f"Permission denied: {e}",
            )
        except Exception as e:
            return ScanResult(
                module_name=self.name,
                items=items,
                error=str(e),
            )
        return ScanResult(module_name=self.name, items=items)
