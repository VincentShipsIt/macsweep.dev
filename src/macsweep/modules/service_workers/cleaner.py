"""Universal service worker cleaner for browsers and Electron apps."""

from collections.abc import AsyncIterator
from pathlib import Path

from macsweep.modules.base import CleanupItem, CleanupModule


class ServiceWorkerModule(CleanupModule):
    """Clean service workers from all browsers and Electron apps."""

    name = "Service Workers"
    description = "Browser and app service workers (PWA offline caches)"
    category = "Service Workers"

    # All known service worker locations
    # Format: (app_name, glob_pattern relative to ~/Library/Application Support/)
    SW_LOCATIONS: list[tuple[str, str]] = [
        # Browsers (Chromium-based) - Priority: Brave, Chrome, Safari
        ("Brave", "BraveSoftware/Brave-Browser/*/Service Worker"),
        ("Chrome", "Google/Chrome/*/Service Worker"),
        ("Chromium", "Chromium/*/Service Worker"),
        ("Arc", "Arc/User Data/*/Service Worker"),
        ("Edge", "Microsoft Edge/*/Service Worker"),
        ("Opera", "com.operasoftware.Opera/*/Service Worker"),
        ("Vivaldi", "Vivaldi/*/Service Worker"),
        # Electron apps
        ("Discord", "discord/Service Worker"),
        ("Slack", "Slack/Service Worker"),
        ("WhatsApp", "WhatsApp/Service Worker"),
        ("Cursor", "Cursor/Service Worker"),
        ("VS Code", "Code/Service Worker"),
        ("Postman", "Postman/*/Service Worker"),
        ("Notion", "Notion/Service Worker"),
        ("Figma", "Figma/Service Worker"),
        ("Spotify", "Spotify/Service Worker"),
        ("Telegram", "Telegram/Service Worker"),
        ("Teams", "Microsoft Teams/Service Worker"),
        ("Obsidian", "obsidian/Service Worker"),
        ("Linear", "Linear/Service Worker"),
        ("1Password", "1Password/Service Worker"),
    ]

    def __init__(self) -> None:
        self.app_support = Path.home() / "Library/Application Support"

    async def scan(self) -> AsyncIterator[CleanupItem]:
        """Scan for service worker directories."""
        for app_name, pattern in self.SW_LOCATIONS:
            full_pattern = self.app_support / pattern

            # Handle glob patterns
            base_path = full_pattern.parent
            glob_pattern = full_pattern.name

            if "*" in str(base_path):
                # Pattern has wildcard in parent path
                parts = str(full_pattern.relative_to(self.app_support)).split("/")
                current = self.app_support

                for part in parts[:-1]:
                    if "*" in part:
                        try:
                            matches = list(current.glob(part))
                            if matches:
                                current = matches[0]
                            else:
                                break
                        except (PermissionError, OSError):
                            break
                    else:
                        current = current / part
                        if not current.exists():
                            break

                if current.exists():
                    sw_path = current / parts[-1]
                    if sw_path.exists() and sw_path.is_dir():
                        size = self._get_dir_size(sw_path)
                        if size > 0:
                            yield CleanupItem(
                                path=sw_path,
                                size=size,
                                category=self.category,
                                subcategory=app_name,
                                description=f"{app_name} service workers",
                                safe_to_delete=True,
                            )
            else:
                # Simple path or glob at the end
                try:
                    for sw_path in base_path.glob(glob_pattern):
                        if sw_path.is_dir():
                            size = self._get_dir_size(sw_path)
                            if size > 0:
                                yield CleanupItem(
                                    path=sw_path,
                                    size=size,
                                    category=self.category,
                                    subcategory=app_name,
                                    description=f"{app_name} service workers",
                                    safe_to_delete=True,
                                )
                except (PermissionError, OSError):
                    continue

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
