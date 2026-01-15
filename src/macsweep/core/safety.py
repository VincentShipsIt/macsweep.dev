"""Safety mechanisms for MacSweep."""

from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class SafetyConfig:
    """Safety configuration."""

    dry_run: bool = True
    require_confirmation: bool = True
    backup_before_delete: bool = False
    max_delete_size_gb: float = 10.0
    protected_paths: list[str] = field(default_factory=list)

    def __post_init__(self) -> None:
        if not self.protected_paths:
            self.protected_paths = [
                "~/Documents",
                "~/Desktop",
                "~/Pictures",
                "~/Movies",
                "~/Music",
                "~/.ssh",
                "~/.gnupg",
                "~/Library/Keychains",
            ]


class SafetyChecker:
    """Validates operations before execution."""

    # Paths that should never be deleted
    NEVER_DELETE: set[Path] = {
        Path.home() / ".ssh",
        Path.home() / ".gnupg",
        Path.home() / "Library/Keychains",
        Path("/System"),
        Path("/Applications"),
        Path("/usr"),
        Path("/bin"),
        Path("/sbin"),
        Path("/Library"),
        Path("/private/var"),
    }

    # Paths that are safe to clean (allow-list approach for certain system paths)
    SAFE_CACHE_ROOTS: set[Path] = {
        Path.home() / "Library/Caches",
        Path.home() / "Library/Logs",
        Path.home() / "Library/Application Support",
        Path.home() / ".Trash",
        Path.home() / ".cache",
    }

    def __init__(self, config: SafetyConfig | None = None) -> None:
        self.config = config or SafetyConfig()

    def is_safe_to_delete(self, path: Path) -> tuple[bool, str]:
        """Check if a path is safe to delete."""
        try:
            resolved = path.resolve()
        except (OSError, RuntimeError):
            return False, "Cannot resolve path"

        # Never delete protected paths
        for protected in self.NEVER_DELETE:
            try:
                if resolved == protected.resolve():
                    return False, f"Path is protected: {protected}"
                if protected.resolve() in resolved.parents:
                    # Exception: allow cleaning caches within /Library
                    if not self._is_in_safe_cache_root(resolved):
                        return False, f"Path is under protected directory: {protected}"
            except (OSError, RuntimeError):
                continue

        # Must be under home directory or a safe cache root
        home = Path.home()
        if not str(resolved).startswith(str(home)):
            return False, "Path is outside home directory"

        # Check custom protected paths from config
        for protected_str in self.config.protected_paths:
            protected = Path(protected_str).expanduser()
            try:
                if resolved == protected.resolve() or protected.resolve() in resolved.parents:
                    return False, f"Path is in protected list: {protected_str}"
            except (OSError, RuntimeError):
                continue

        # Check for symlinks pointing outside home
        if path.is_symlink():
            try:
                target = path.resolve()
                if not str(target).startswith(str(home)):
                    return False, "Symlink points outside home directory"
            except (OSError, RuntimeError):
                return False, "Cannot resolve symlink"

        return True, "OK"

    def _is_in_safe_cache_root(self, path: Path) -> bool:
        """Check if path is under a known safe cache root."""
        for safe_root in self.SAFE_CACHE_ROOTS:
            try:
                if str(path).startswith(str(safe_root.resolve())):
                    return True
            except (OSError, RuntimeError):
                continue
        return False

    def validate_batch(self, paths: list[Path]) -> dict[str, list]:
        """Validate a batch of paths."""
        results: dict[str, list] = {"safe": [], "blocked": []}
        for path in paths:
            is_safe, reason = self.is_safe_to_delete(path)
            if is_safe:
                results["safe"].append(path)
            else:
                results["blocked"].append((path, reason))
        return results

    def check_size_limit(self, total_bytes: int) -> tuple[bool, str]:
        """Check if deletion size is within limits."""
        max_bytes = self.config.max_delete_size_gb * 1024 * 1024 * 1024
        if total_bytes > max_bytes:
            return (
                False,
                f"Total size ({total_bytes / (1024**3):.2f} GB) exceeds limit ({self.config.max_delete_size_gb} GB)",
            )
        return True, "OK"
