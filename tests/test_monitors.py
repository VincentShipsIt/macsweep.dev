"""Tests for monitor modules."""

from unittest.mock import MagicMock, patch

import pytest

from macsweep.monitors.memory import MemoryMonitor, MemoryStats


class TestMemoryStats:
    """Tests for MemoryStats dataclass."""

    def test_used_percent(self) -> None:
        """Test used percentage calculation."""
        stats = MemoryStats(
            total_bytes=16 * 1024 * 1024 * 1024,  # 16GB
            used_bytes=8 * 1024 * 1024 * 1024,  # 8GB
            free_bytes=8 * 1024 * 1024 * 1024,
            wired_bytes=2 * 1024 * 1024 * 1024,
            compressed_bytes=1 * 1024 * 1024 * 1024,
            cached_bytes=1 * 1024 * 1024 * 1024,
            app_memory_bytes=4 * 1024 * 1024 * 1024,
        )
        assert stats.used_percent == 50.0

    def test_free_percent(self) -> None:
        """Test free percentage calculation."""
        stats = MemoryStats(
            total_bytes=16 * 1024 * 1024 * 1024,
            used_bytes=8 * 1024 * 1024 * 1024,
            free_bytes=8 * 1024 * 1024 * 1024,
            wired_bytes=0,
            compressed_bytes=0,
            cached_bytes=0,
            app_memory_bytes=0,
        )
        assert stats.free_percent == 50.0

    def test_pressure_low(self) -> None:
        """Test low pressure level."""
        stats = MemoryStats(
            total_bytes=100,
            used_bytes=50,  # 50%
            free_bytes=50,
            wired_bytes=0,
            compressed_bytes=0,
            cached_bytes=0,
            app_memory_bytes=0,
        )
        assert stats.pressure == "low"

    def test_pressure_medium(self) -> None:
        """Test medium pressure level."""
        stats = MemoryStats(
            total_bytes=100,
            used_bytes=70,  # 70%
            free_bytes=30,
            wired_bytes=0,
            compressed_bytes=0,
            cached_bytes=0,
            app_memory_bytes=0,
        )
        assert stats.pressure == "medium"

    def test_pressure_high(self) -> None:
        """Test high pressure level."""
        stats = MemoryStats(
            total_bytes=100,
            used_bytes=85,  # 85%
            free_bytes=15,
            wired_bytes=0,
            compressed_bytes=0,
            cached_bytes=0,
            app_memory_bytes=0,
        )
        assert stats.pressure == "high"

    def test_pressure_critical(self) -> None:
        """Test critical pressure level."""
        stats = MemoryStats(
            total_bytes=100,
            used_bytes=95,  # 95%
            free_bytes=5,
            wired_bytes=0,
            compressed_bytes=0,
            cached_bytes=0,
            app_memory_bytes=0,
        )
        assert stats.pressure == "critical"

    def test_pressure_color(self) -> None:
        """Test pressure color mapping."""
        # Low
        stats_low = MemoryStats(
            total_bytes=100, used_bytes=50, free_bytes=50,
            wired_bytes=0, compressed_bytes=0, cached_bytes=0, app_memory_bytes=0,
        )
        assert stats_low.pressure_color == "green"

        # Medium
        stats_med = MemoryStats(
            total_bytes=100, used_bytes=70, free_bytes=30,
            wired_bytes=0, compressed_bytes=0, cached_bytes=0, app_memory_bytes=0,
        )
        assert stats_med.pressure_color == "yellow"

        # High
        stats_high = MemoryStats(
            total_bytes=100, used_bytes=85, free_bytes=15,
            wired_bytes=0, compressed_bytes=0, cached_bytes=0, app_memory_bytes=0,
        )
        assert stats_high.pressure_color == "orange"

        # Critical
        stats_crit = MemoryStats(
            total_bytes=100, used_bytes=95, free_bytes=5,
            wired_bytes=0, compressed_bytes=0, cached_bytes=0, app_memory_bytes=0,
        )
        assert stats_crit.pressure_color == "red"

    def test_zero_total_bytes(self) -> None:
        """Test handling of zero total bytes."""
        stats = MemoryStats(
            total_bytes=0,
            used_bytes=0,
            free_bytes=0,
            wired_bytes=0,
            compressed_bytes=0,
            cached_bytes=0,
            app_memory_bytes=0,
        )
        assert stats.used_percent == 0
        assert stats.free_percent == 100


class TestMemoryMonitor:
    """Tests for MemoryMonitor class."""

    def test_parse_vm_stat(self) -> None:
        """Test parsing vm_stat output."""
        monitor = MemoryMonitor()
        vm_stat_output = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                              123456.
Pages active:                            234567.
Pages inactive:                          345678.
Pages speculative:                       12345.
Pages wired down:                        456789.
Pages occupied by compressor:            56789.
Pages purgeable:                         6789."""

        stats = monitor._parse_vm_stat(vm_stat_output)

        assert stats["Pages free"] == 123456
        assert stats["Pages active"] == 234567
        assert stats["Pages inactive"] == 345678
        assert stats["Pages speculative"] == 12345
        assert stats["Pages wired down"] == 456789
        assert stats["Pages occupied by compressor"] == 56789
        assert stats["Pages purgeable"] == 6789

    def test_parse_vm_stat_empty(self) -> None:
        """Test parsing empty vm_stat output."""
        monitor = MemoryMonitor()
        stats = monitor._parse_vm_stat("")
        assert stats == {}

    def test_parse_vm_stat_invalid_values(self) -> None:
        """Test parsing vm_stat with invalid values."""
        monitor = MemoryMonitor()
        vm_stat_output = """Mach Virtual Memory Statistics:
Pages free:                              invalid.
Pages active:                            123."""

        stats = monitor._parse_vm_stat(vm_stat_output)
        assert "Pages free" not in stats
        assert stats.get("Pages active") == 123

    @patch("subprocess.check_output")
    def test_get_page_size_success(self, mock_check_output: MagicMock) -> None:
        """Test getting page size successfully."""
        mock_check_output.return_value = "16384\n"
        monitor = MemoryMonitor()
        page_size = monitor._get_page_size()
        assert page_size == 16384

    @patch("subprocess.check_output")
    def test_get_page_size_failure(self, mock_check_output: MagicMock) -> None:
        """Test getting page size on failure."""
        import subprocess

        mock_check_output.side_effect = subprocess.SubprocessError
        monitor = MemoryMonitor()
        page_size = monitor._get_page_size()
        # Should return default for Apple Silicon
        assert page_size == 16384

    @patch("subprocess.check_output")
    def test_get_stats_success(self, mock_check_output: MagicMock) -> None:
        """Test getting memory stats successfully."""

        def mock_output(cmd: list, **kwargs) -> str:
            if cmd[0] == "sysctl":
                return "17179869184"  # 16GB
            elif cmd[0] == "vm_stat":
                return """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                              100000.
Pages active:                            200000.
Pages inactive:                          50000.
Pages speculative:                       10000.
Pages wired down:                        150000.
Pages occupied by compressor:            30000.
Pages purgeable:                         5000."""
            elif cmd[0] == "pagesize":
                return "16384"
            return ""

        mock_check_output.side_effect = mock_output

        monitor = MemoryMonitor()
        stats = monitor.get_stats()

        assert stats.total_bytes == 17179869184
        assert stats.wired_bytes > 0
        assert 0 <= stats.used_percent <= 100

    @patch("subprocess.check_output")
    def test_get_stats_subprocess_failure(
        self, mock_check_output: MagicMock
    ) -> None:
        """Test getting stats when subprocess fails."""
        import subprocess

        mock_check_output.side_effect = subprocess.SubprocessError

        monitor = MemoryMonitor()
        stats = monitor.get_stats()

        # Should return stats with zero values, not raise
        assert stats.total_bytes == 0

    @patch("subprocess.run")
    def test_purge_inactive_success(self, mock_run: MagicMock) -> None:
        """Test purging inactive memory successfully."""
        mock_run.return_value = MagicMock(returncode=0)

        monitor = MemoryMonitor()
        result = monitor.purge_inactive()

        assert result is True
        mock_run.assert_called_once()

    @patch("subprocess.run")
    def test_purge_inactive_failure(self, mock_run: MagicMock) -> None:
        """Test purging inactive memory on failure."""
        import subprocess

        mock_run.side_effect = subprocess.SubprocessError

        monitor = MemoryMonitor()
        result = monitor.purge_inactive()

        assert result is False

    @patch("subprocess.run")
    def test_purge_inactive_permission_error(self, mock_run: MagicMock) -> None:
        """Test purging when permission denied."""
        mock_run.side_effect = PermissionError

        monitor = MemoryMonitor()
        result = monitor.purge_inactive()

        assert result is False
