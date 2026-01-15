"""Large file finder analyzer."""

import heapq
from datetime import datetime
from pathlib import Path


class LargeFileFinder:
    """Find large files in a directory."""

    # Directories to skip during scanning
    SKIP_DIRS: set[str] = {
        ".git",
        ".svn",
        ".hg",
        "node_modules",
        "__pycache__",
        ".venv",
        "venv",
        ".Trash",
        "Library",  # Skip Library by default, scan explicitly if needed
    }

    # Skip hidden files by default (except when scanning Library)
    SKIP_HIDDEN: bool = True

    def __init__(self, min_size_bytes: int = 100 * 1024 * 1024) -> None:
        """Initialize with minimum file size threshold.

        Args:
            min_size_bytes: Minimum size in bytes (default 100MB)
        """
        self.min_size = min_size_bytes

    async def find(
        self,
        path: Path,
        limit: int = 50,
        include_hidden: bool = False,
        skip_library: bool = True,
    ) -> list[tuple[Path, int, datetime]]:
        """Find large files in the given path.

        Args:
            path: Directory to scan
            limit: Maximum number of files to return
            include_hidden: Include hidden files/directories
            skip_library: Skip ~/Library directory

        Returns:
            List of (path, size, modified_date) tuples, sorted by size desc
        """
        path = path.expanduser().resolve()

        # Use a min-heap to track largest files efficiently
        # We negate sizes to use heapq as a max-heap
        heap: list[tuple[int, Path, datetime]] = []

        skip_dirs = self.SKIP_DIRS.copy()
        if not skip_library:
            skip_dirs.discard("Library")

        await self._scan_directory(path, heap, limit, include_hidden, skip_dirs)

        # Convert heap to sorted list (largest first)
        results = []
        while heap:
            neg_size, file_path, modified = heapq.heappop(heap)
            results.append((file_path, -neg_size, modified))

        return list(reversed(results))

    async def _scan_directory(
        self,
        path: Path,
        heap: list[tuple[int, Path, datetime]],
        limit: int,
        include_hidden: bool,
        skip_dirs: set[str],
    ) -> None:
        """Recursively scan directory for large files."""
        try:
            for entry in path.iterdir():
                name = entry.name

                # Skip hidden files/dirs
                if not include_hidden and name.startswith("."):
                    continue

                # Skip certain directories
                if entry.is_dir():
                    if name in skip_dirs:
                        continue
                    await self._scan_directory(entry, heap, limit, include_hidden, skip_dirs)
                elif entry.is_file():
                    try:
                        stat = entry.stat()
                        size = stat.st_size

                        if size >= self.min_size:
                            modified = datetime.fromtimestamp(stat.st_mtime)

                            if len(heap) < limit:
                                heapq.heappush(heap, (-size, entry, modified))
                            elif -size < heap[0][0]:
                                # This file is larger than smallest in heap
                                heapq.heapreplace(heap, (-size, entry, modified))
                    except (PermissionError, OSError, FileNotFoundError):
                        pass
        except (PermissionError, OSError):
            pass

    async def find_in_downloads(
        self, days_old: int = 30, limit: int = 50
    ) -> list[tuple[Path, int, datetime]]:
        """Find large old files in Downloads folder.

        Args:
            days_old: Only include files older than this many days
            limit: Maximum number of files to return

        Returns:
            List of (path, size, modified_date) tuples
        """
        downloads = Path.home() / "Downloads"
        if not downloads.exists():
            return []

        cutoff = datetime.now().timestamp() - (days_old * 24 * 60 * 60)
        results: list[tuple[Path, int, datetime]] = []

        try:
            for entry in downloads.iterdir():
                if entry.is_file():
                    try:
                        stat = entry.stat()
                        if stat.st_mtime < cutoff and stat.st_size >= self.min_size:
                            modified = datetime.fromtimestamp(stat.st_mtime)
                            results.append((entry, stat.st_size, modified))
                    except (PermissionError, OSError):
                        pass
        except (PermissionError, OSError):
            pass

        # Sort by size descending
        results.sort(key=lambda x: x[1], reverse=True)
        return results[:limit]
