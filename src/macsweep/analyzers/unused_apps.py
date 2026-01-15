"""Unused applications analyzer using Spotlight metadata."""

import subprocess
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path


@dataclass
class AppInfo:
    """Information about an application."""

    name: str
    path: Path
    size: int
    last_used: datetime | None
    days_since_use: int | None
    version: str = ""
    bundle_id: str = ""

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


class UnusedAppsAnalyzer:
    """Find applications not used recently using Spotlight metadata."""

    # Apps to never consider as "unused" (system apps, essential apps)
    ESSENTIAL_APPS: set[str] = {
        "Finder",
        "Safari",
        "System Preferences",
        "System Settings",
        "App Store",
        "Terminal",
        "Activity Monitor",
        "Disk Utility",
        "Console",
        "Keychain Access",
        "Migration Assistant",
        "Boot Camp Assistant",
        "Font Book",
        "Preview",
        "TextEdit",
        "Calculator",
        "Calendar",
        "Contacts",
        "Mail",
        "Messages",
        "FaceTime",
        "Notes",
        "Reminders",
        "Maps",
        "Photos",
        "Music",
        "TV",
        "Podcasts",
        "News",
        "Stocks",
        "Home",
        "Voice Memos",
        "Siri",
        "Time Machine",
        "Automator",
        "Script Editor",
        "Shortcuts",
    }

    def __init__(self, days_threshold: int = 90) -> None:
        """Initialize with usage threshold.

        Args:
            days_threshold: Consider apps unused if not opened in this many days
        """
        self.threshold = days_threshold
        self.cutoff = datetime.now() - timedelta(days=days_threshold)

    async def find_unused_apps(self) -> list[AppInfo]:
        """Find apps not used since threshold.

        Returns:
            List of AppInfo for unused applications, sorted by days since use
        """
        apps: list[AppInfo] = []

        # Scan /Applications
        for app_path in Path("/Applications").glob("*.app"):
            if app_path.name.replace(".app", "") in self.ESSENTIAL_APPS:
                continue
            info = await self._get_app_info(app_path)
            if info and self._is_unused(info):
                apps.append(info)

        # Scan ~/Applications
        user_apps = Path.home() / "Applications"
        if user_apps.exists():
            for app_path in user_apps.glob("*.app"):
                info = await self._get_app_info(app_path)
                if info and self._is_unused(info):
                    apps.append(info)

        # Sort by days since use (most unused first), then by size
        return sorted(
            apps,
            key=lambda x: (-(x.days_since_use or 9999), -x.size),
        )

    async def _get_app_info(self, path: Path) -> AppInfo | None:
        """Get app info using mdls (Spotlight metadata)."""
        try:
            # Get last used date from Spotlight
            result = subprocess.run(
                ["mdls", "-name", "kMDItemLastUsedDate", "-raw", str(path)],
                capture_output=True,
                text=True,
                timeout=5,
            )

            last_used = None
            days_since = None

            output = result.stdout.strip()
            if output and output != "(null)":
                try:
                    # Parse: 2026-01-14 15:40:07 +0000
                    date_str = output.split("+")[0].strip()
                    last_used = datetime.strptime(date_str, "%Y-%m-%d %H:%M:%S")
                    days_since = (datetime.now() - last_used).days
                except (ValueError, IndexError):
                    pass

            # Get version
            version = ""
            version_result = subprocess.run(
                ["mdls", "-name", "kMDItemVersion", "-raw", str(path)],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if version_result.stdout.strip() != "(null)":
                version = version_result.stdout.strip()

            # Get bundle identifier
            bundle_id = ""
            bundle_result = subprocess.run(
                ["mdls", "-name", "kMDItemCFBundleIdentifier", "-raw", str(path)],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if bundle_result.stdout.strip() != "(null)":
                bundle_id = bundle_result.stdout.strip()

            # Calculate size
            size = self._get_app_size(path)

            return AppInfo(
                name=path.stem,
                path=path,
                size=size,
                last_used=last_used,
                days_since_use=days_since,
                version=version,
                bundle_id=bundle_id,
            )
        except subprocess.TimeoutExpired:
            return None
        except Exception:
            return None

    def _get_app_size(self, path: Path) -> int:
        """Calculate total size of an app bundle."""
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

    def _is_unused(self, app: AppInfo) -> bool:
        """Check if app is unused based on threshold."""
        if app.last_used is None:
            # Never used (no metadata) - consider unused
            return True
        return app.last_used < self.cutoff

    async def get_app_details(self, app_path: Path) -> dict:
        """Get detailed information about an app.

        Returns dict with version, size, last_used, bundle_id, etc.
        """
        info = await self._get_app_info(app_path)
        if not info:
            return {}

        return {
            "name": info.name,
            "path": str(info.path),
            "size": info.size,
            "size_formatted": info.format_size(),
            "last_used": info.last_used.isoformat() if info.last_used else None,
            "days_since_use": info.days_since_use,
            "version": info.version,
            "bundle_id": info.bundle_id,
        }
