"""Memory monitoring for macOS."""

import subprocess
from dataclasses import dataclass


@dataclass
class MemoryStats:
    """Memory statistics."""

    total_bytes: int
    used_bytes: int
    free_bytes: int
    wired_bytes: int
    compressed_bytes: int
    cached_bytes: int
    app_memory_bytes: int

    @property
    def used_percent(self) -> float:
        """Percentage of memory used."""
        return (self.used_bytes / self.total_bytes) * 100 if self.total_bytes > 0 else 0

    @property
    def free_percent(self) -> float:
        """Percentage of memory free."""
        return 100 - self.used_percent

    @property
    def pressure(self) -> str:
        """Return memory pressure level as string."""
        pct = self.used_percent
        if pct < 60:
            return "low"
        elif pct < 80:
            return "medium"
        elif pct < 90:
            return "high"
        else:
            return "critical"

    @property
    def pressure_color(self) -> str:
        """Return color for pressure level."""
        pressure = self.pressure
        return {
            "low": "green",
            "medium": "yellow",
            "high": "orange",
            "critical": "red",
        }.get(pressure, "white")


class MemoryMonitor:
    """Monitor RAM usage using macOS system commands."""

    def get_stats(self) -> MemoryStats:
        """Get current memory statistics."""
        # Get total memory
        try:
            total_output = subprocess.check_output(
                ["sysctl", "-n", "hw.memsize"],
                text=True,
                timeout=5,
            )
            total = int(total_output.strip())
        except (subprocess.SubprocessError, ValueError):
            total = 0

        # Parse vm_stat output
        try:
            vm_stat_output = subprocess.check_output(
                ["vm_stat"],
                text=True,
                timeout=5,
            )
            stats = self._parse_vm_stat(vm_stat_output)
        except subprocess.SubprocessError:
            stats = {}

        # Page size (modern macOS uses 16KB pages on Apple Silicon, 4KB on Intel)
        page_size = self._get_page_size()

        # Calculate memory values
        free = stats.get("Pages free", 0) * page_size
        active = stats.get("Pages active", 0) * page_size
        inactive = stats.get("Pages inactive", 0) * page_size
        speculative = stats.get("Pages speculative", 0) * page_size
        wired = stats.get("Pages wired down", 0) * page_size
        compressed = stats.get("Pages occupied by compressor", 0) * page_size
        purgeable = stats.get("Pages purgeable", 0) * page_size

        # Used memory = total - free - inactive - speculative - purgeable
        # This gives a more accurate "pressure" reading
        used = total - free - inactive - speculative - purgeable

        return MemoryStats(
            total_bytes=total,
            used_bytes=used,
            free_bytes=free + inactive + speculative + purgeable,
            wired_bytes=wired,
            compressed_bytes=compressed,
            cached_bytes=inactive + purgeable,
            app_memory_bytes=active,
        )

    def _get_page_size(self) -> int:
        """Get system page size."""
        try:
            output = subprocess.check_output(
                ["pagesize"],
                text=True,
                timeout=5,
            )
            return int(output.strip())
        except (subprocess.SubprocessError, ValueError):
            # Default to 16KB for Apple Silicon
            return 16384

    def _parse_vm_stat(self, output: str) -> dict[str, int]:
        """Parse vm_stat output into dictionary."""
        stats: dict[str, int] = {}
        for line in output.strip().split("\n")[1:]:  # Skip header
            if ":" in line:
                key, value = line.split(":", 1)
                key = key.strip()
                value = value.strip().rstrip(".")
                try:
                    stats[key] = int(value)
                except ValueError:
                    pass
        return stats

    def purge_inactive(self) -> bool:
        """Attempt to purge inactive memory (requires sudo)."""
        try:
            subprocess.run(
                ["sudo", "purge"],
                check=True,
                timeout=30,
            )
            return True
        except (subprocess.SubprocessError, PermissionError):
            return False
