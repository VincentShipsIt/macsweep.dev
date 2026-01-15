"""Google Chrome cleanup module."""

from collections.abc import AsyncIterator
from pathlib import Path

from macsweep.modules.base import CleanupItem, CleanupModule


class ChromeModule(CleanupModule):
    """Clean Google Chrome caches and data."""

    name = "Google Chrome"
    description = "Chrome browser caches, temporary files, and logs"
    category = "Browsers"

    CHROME_SUPPORT = Path.home() / "Library/Application Support/Google/Chrome"
    CHROME_CACHES = Path.home() / "Library/Caches/Google/Chrome"

    # Targets within each profile
    PROFILE_TARGETS: dict[str, bool] = {
        "Cache": True,
        "Code Cache": True,
        "GPUCache": True,
        "Service Worker": True,
        "ShaderCache": True,
        "GrShaderCache": True,
        "optimization_guide_model_store": True,
        "optimization_guide_prediction_model_downloads": True,
    }

    def is_available(self) -> bool:
        """Check if Chrome is installed."""
        return self.CHROME_SUPPORT.exists()

    async def scan(self) -> AsyncIterator[CleanupItem]:
        """Scan for Chrome cleanup items."""
        if not self.is_available():
            return

        # Scan profile directories
        for profile in self._get_profiles():
            for target, safe in self.PROFILE_TARGETS.items():
                target_path = profile / target
                if target_path.exists() and target_path.is_dir():
                    size = self._get_dir_size(target_path)
                    if size > 0:
                        yield CleanupItem(
                            path=target_path,
                            size=size,
                            category=self.category,
                            subcategory=f"Chrome {target}",
                            description=f"Chrome {profile.name}: {target}",
                            safe_to_delete=safe,
                        )

        # Scan Chrome caches directory
        if self.CHROME_CACHES.exists():
            size = self._get_dir_size(self.CHROME_CACHES)
            if size > 0:
                yield CleanupItem(
                    path=self.CHROME_CACHES,
                    size=size,
                    category=self.category,
                    subcategory="Chrome Caches",
                    description="Chrome application caches",
                    safe_to_delete=True,
                )

    def _get_profiles(self) -> list[Path]:
        """Get all Chrome profile directories."""
        profiles = []
        if self.CHROME_SUPPORT.exists():
            try:
                for entry in self.CHROME_SUPPORT.iterdir():
                    if entry.is_dir() and (
                        entry.name == "Default" or entry.name.startswith("Profile")
                    ):
                        profiles.append(entry)
            except (PermissionError, OSError):
                pass
        return profiles
