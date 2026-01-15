"""CPU monitoring for macOS."""

import subprocess
from dataclasses import dataclass


@dataclass
class CPUStats:
    """CPU statistics."""

    usage_percent: float
    user_percent: float
    system_percent: float
    idle_percent: float
    core_count: int

    @property
    def load_level(self) -> str:
        """Return load level as string."""
        if self.usage_percent < 30:
            return "low"
        elif self.usage_percent < 60:
            return "medium"
        elif self.usage_percent < 85:
            return "high"
        else:
            return "critical"

    @property
    def load_color(self) -> str:
        """Return color for load level."""
        level = self.load_level
        return {
            "low": "green",
            "medium": "yellow",
            "high": "orange",
            "critical": "red",
        }.get(level, "white")


class CPUMonitor:
    """Monitor CPU usage using macOS system commands."""

    def __init__(self) -> None:
        self._last_cpu_times: dict[str, float] | None = None
        self._last_time: float = 0

    def get_stats(self) -> CPUStats:
        """Get current CPU statistics."""
        # Get core count
        core_count = self._get_core_count()

        # Get CPU usage from top command (quick snapshot)
        try:
            output = subprocess.check_output(
                ["top", "-l", "1", "-n", "0", "-stats", "cpu"],
                text=True,
                timeout=5,
                stderr=subprocess.DEVNULL,
            )

            # Parse CPU usage line
            user = 0.0
            sys = 0.0
            idle = 100.0

            for line in output.split("\n"):
                if "CPU usage:" in line:
                    # Format: "CPU usage: 12.34% user, 5.67% sys, 81.99% idle"
                    parts = line.replace("CPU usage:", "").strip().split(",")
                    for part in parts:
                        part = part.strip()
                        if "user" in part:
                            user = float(part.replace("% user", "").strip())
                        elif "sys" in part:
                            sys = float(part.replace("% sys", "").strip())
                        elif "idle" in part:
                            idle = float(part.replace("% idle", "").strip())
                    break

            usage = user + sys

            return CPUStats(
                usage_percent=usage,
                user_percent=user,
                system_percent=sys,
                idle_percent=idle,
                core_count=core_count,
            )
        except (subprocess.SubprocessError, ValueError):
            return CPUStats(
                usage_percent=0,
                user_percent=0,
                system_percent=0,
                idle_percent=100,
                core_count=core_count,
            )

    def _get_core_count(self) -> int:
        """Get number of CPU cores."""
        try:
            output = subprocess.check_output(
                ["sysctl", "-n", "hw.ncpu"],
                text=True,
                timeout=5,
            )
            return int(output.strip())
        except (subprocess.SubprocessError, ValueError):
            return 1

    def get_load_average(self) -> tuple[float, float, float]:
        """Get system load averages (1, 5, 15 minutes)."""
        try:
            output = subprocess.check_output(
                ["sysctl", "-n", "vm.loadavg"],
                text=True,
                timeout=5,
            )
            # Format: "{ 1.23 2.34 3.45 }"
            parts = output.strip().strip("{}").split()
            return (
                float(parts[0]),
                float(parts[1]),
                float(parts[2]),
            )
        except (subprocess.SubprocessError, ValueError, IndexError):
            return (0.0, 0.0, 0.0)

    def get_process_count(self) -> int:
        """Get number of running processes."""
        try:
            output = subprocess.check_output(
                ["ps", "-e"],
                text=True,
                timeout=5,
            )
            # Count lines minus header
            return len(output.strip().split("\n")) - 1
        except subprocess.SubprocessError:
            return 0
