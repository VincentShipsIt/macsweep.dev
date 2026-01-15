"""Brave browser cleanup module."""

from collections.abc import AsyncIterator
from pathlib import Path

from macsweep.modules.base import CleanupItem, CleanupModule


class BraveModule(CleanupModule):
    """Clean Brave browser caches and data."""

    name = "Brave Browser"
    description = "Brave browser caches, temporary files, and logs"
    category = "Browsers"

    BRAVE_SUPPORT = Path.home() / "Library/Application Support/BraveSoftware/Brave-Browser"
    BRAVE_CACHES = Path.home() / "Library/Caches/BraveSoftware"

    # Targets within each profile (Default, Profile 1, etc.)
    PROFILE_TARGETS: dict[str, bool] = {
        "Cache": True,
        "Code Cache": True,
        "GPUCache": True,
        "Service Worker": True,  # Also handled by ServiceWorkerModule
        "ShaderCache": True,
        "GrShaderCache": True,
        "optimization_guide_model_store": True,
        "optimization_guide_prediction_model_downloads": True,
    }

    def is_available(self) -> bool:
        """Check if Brave is installed."""
        return self.BRAVE_SUPPORT.exists()

    async def scan(self) -> AsyncIterator[CleanupItem]:
        """Scan for Brave browser cleanup items."""
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
                            subcategory=f"Brave {target}",
                            description=f"Brave {profile.name}: {target}",
                            safe_to_delete=safe,
                        )

        # Scan Brave caches directory
        if self.BRAVE_CACHES.exists():
            size = self._get_dir_size(self.BRAVE_CACHES)
            if size > 0:
                yield CleanupItem(
                    path=self.BRAVE_CACHES,
                    size=size,
                    category=self.category,
                    subcategory="Brave Caches",
                    description="Brave application caches",
                    safe_to_delete=True,
                )

    def _get_profiles(self) -> list[Path]:
        """Get all Brave profile directories."""
        profiles = []
        if self.BRAVE_SUPPORT.exists():
            try:
                for entry in self.BRAVE_SUPPORT.iterdir():
                    if entry.is_dir() and (
                        entry.name == "Default" or entry.name.startswith("Profile")
                    ):
                        profiles.append(entry)
            except (PermissionError, OSError):
                pass
        return profiles
