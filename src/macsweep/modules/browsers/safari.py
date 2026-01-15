"""Safari browser cleanup module."""

from collections.abc import AsyncIterator
from pathlib import Path

from macsweep.modules.base import CleanupItem, CleanupModule


class SafariModule(CleanupModule):
    """Clean Safari browser caches and data."""

    name = "Safari"
    description = "Safari browser caches and temporary files"
    category = "Browsers"
    requires_full_disk_access = True

    SAFARI_CACHES = Path.home() / "Library/Caches/com.apple.Safari"
    SAFARI_WEBKIT_CACHES = Path.home() / "Library/Caches/com.apple.WebKit"

    # Additional Safari-related paths (may require FDA)
    SAFARI_TARGETS: list[tuple[str, Path, bool]] = [
        ("Safari Caches", Path.home() / "Library/Caches/com.apple.Safari", True),
        ("WebKit Caches", Path.home() / "Library/Caches/com.apple.WebKit.WebContent", True),
        ("Safari Favicon Cache", Path.home() / "Library/Safari/Favicon Cache", True),
        ("Safari Touch Icons", Path.home() / "Library/Safari/Touch Icons Cache", True),
        ("Safari Template Icons", Path.home() / "Library/Safari/Template Icons", True),
    ]

    def is_available(self) -> bool:
        """Safari is always available on macOS."""
        return True

    async def scan(self) -> AsyncIterator[CleanupItem]:
        """Scan for Safari cleanup items."""
        for description, path, safe in self.SAFARI_TARGETS:
            if path.exists():
                try:
                    if path.is_dir():
                        size = self._get_dir_size(path)
                    else:
                        size = path.stat().st_size

                    if size > 0:
                        yield CleanupItem(
                            path=path,
                            size=size,
                            category=self.category,
                            subcategory=description,
                            description=description,
                            safe_to_delete=safe,
                        )
                except PermissionError:
                    # Likely needs Full Disk Access
                    yield CleanupItem(
                        path=path,
                        size=0,
                        category=self.category,
                        subcategory=description,
                        description=f"{description} (requires Full Disk Access)",
                        safe_to_delete=False,
                        requires_confirmation=True,
                    )
                except OSError:
                    pass
