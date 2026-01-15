"""System caches cleanup module."""

from collections.abc import AsyncIterator
from pathlib import Path

from macsweep.modules.base import CleanupItem, CleanupModule


class SystemCachesModule(CleanupModule):
    """Clean system and user cache directories."""

    name = "System Caches"
    description = "User and application cache files"
    category = "System"

    # Safe cache directories to clean
    CACHE_TARGETS: list[tuple[str, str, bool]] = [
        # (description, path, safe_to_delete_entirely)
        ("User Caches", "~/Library/Caches", False),  # Clean contents, not dir
        ("User Logs", "~/Library/Logs", False),
        ("Crash Reports", "~/Library/Application Support/CrashReporter", True),
        ("Saved App State", "~/Library/Saved Application State", True),
        ("Diagnostic Reports", "~/Library/Logs/DiagnosticReports", True),
    ]

    # Skip these subdirectories in ~/Library/Caches
    CACHE_SKIP_PATTERNS: set[str] = {
        "CloudKit",  # iCloud sync
        "com.apple.Safari",  # Handle Safari separately
        "com.apple.nsurlsessiond",  # System networking
        "com.apple.containermanagerd",  # System
    }

    async def scan(self) -> AsyncIterator[CleanupItem]:
        """Scan for cache directories and files."""
        for description, path_str, safe_entirely in self.CACHE_TARGETS:
            path = Path(path_str).expanduser()

            if not path.exists():
                continue

            if safe_entirely:
                # Delete entire directory
                size = self._get_dir_size(path)
                if size > 0:
                    yield CleanupItem(
                        path=path,
                        size=size,
                        category=self.category,
                        subcategory=description,
                        description=description,
                        safe_to_delete=True,
                    )
            else:
                # Scan contents
                async for item in self._scan_directory(path, description):
                    yield item

    async def _scan_directory(self, path: Path, parent_desc: str) -> AsyncIterator[CleanupItem]:
        """Scan a directory for cleanable items."""
        try:
            for entry in path.iterdir():
                # Skip protected patterns
                if entry.name in self.CACHE_SKIP_PATTERNS:
                    continue

                if entry.is_dir():
                    size = self._get_dir_size(entry)
                    if size > 1024 * 1024:  # Only show items > 1MB
                        yield CleanupItem(
                            path=entry,
                            size=size,
                            category=self.category,
                            subcategory=parent_desc,
                            description=f"{parent_desc}: {entry.name}",
                            safe_to_delete=True,
                        )
                elif entry.is_file():
                    try:
                        size = entry.stat().st_size
                        if size > 1024 * 1024:  # Only show files > 1MB
                            yield CleanupItem(
                                path=entry,
                                size=size,
                                category=self.category,
                                subcategory=parent_desc,
                                description=f"{parent_desc}: {entry.name}",
                                safe_to_delete=True,
                            )
                    except (PermissionError, OSError):
                        pass
        except (PermissionError, OSError):
            pass
