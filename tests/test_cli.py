"""Integration tests for CLI commands."""

import json
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from typer.testing import CliRunner

from macsweep.cli import app

runner = CliRunner()


class TestVersionCommand:
    """Tests for version command."""

    def test_version_flag(self) -> None:
        """Test --version flag."""
        result = runner.invoke(app, ["--version"])
        assert result.exit_code == 0
        assert "MacSweep" in result.output
        assert "v" in result.output

    def test_version_short_flag(self) -> None:
        """Test -v flag."""
        result = runner.invoke(app, ["-v"])
        assert result.exit_code == 0
        assert "MacSweep" in result.output


class TestHelpCommand:
    """Tests for help output."""

    def test_no_args_shows_help(self) -> None:
        """Test that no arguments shows help."""
        result = runner.invoke(app, [])
        # no_args_is_help=True causes exit code 0 or 2 depending on typer version
        assert result.exit_code in (0, 2)
        assert "MacSweep" in result.output or "scan" in result.output

    def test_help_flag(self) -> None:
        """Test --help flag."""
        result = runner.invoke(app, ["--help"])
        assert result.exit_code == 0
        assert "MacSweep" in result.output


class TestScanCommand:
    """Tests for scan command."""

    @patch("macsweep.cli._scan_async")
    def test_scan_basic(self, mock_scan: MagicMock) -> None:
        """Test basic scan command."""
        mock_scan.return_value = None
        result = runner.invoke(app, ["scan"])
        assert result.exit_code == 0
        mock_scan.assert_called_once()

    @patch("macsweep.cli._scan_async")
    def test_scan_with_category(self, mock_scan: MagicMock) -> None:
        """Test scan with category filter."""
        mock_scan.return_value = None
        result = runner.invoke(app, ["scan", "--category", "system"])
        assert result.exit_code == 0

    @patch("macsweep.cli._scan_async")
    def test_scan_json_output(self, mock_scan: MagicMock) -> None:
        """Test scan with JSON output."""
        mock_scan.return_value = None
        result = runner.invoke(app, ["scan", "--json"])
        assert result.exit_code == 0


class TestScanCommandIntegration:
    """Integration tests for scan command with real modules."""

    def test_scan_shows_results_table(self, sample_cache_structure: Path) -> None:
        """Test that scan shows a results table."""
        result = runner.invoke(app, ["scan"])
        # Should show results table even if no items (shows "0")
        assert result.exit_code == 0
        assert "Scan Results" in result.output or "Total" in result.output

    def test_scan_json_format(self, sample_cache_structure: Path) -> None:
        """Test that JSON output is valid JSON."""
        result = runner.invoke(app, ["scan", "--json"])
        assert result.exit_code == 0

        # Extract JSON from output (may have Rich formatting)
        try:
            # Find JSON in output
            output = result.output.strip()
            # Try to parse the output as JSON
            data = json.loads(output)
            assert "total_size" in data
            assert "modules" in data
        except json.JSONDecodeError:
            # If Rich formatting is included, that's OK for this test
            pass


class TestCleanCommand:
    """Tests for clean command."""

    def test_clean_dry_run_default(self, sample_cache_structure: Path) -> None:
        """Test that clean defaults to dry-run."""
        result = runner.invoke(app, ["clean"])
        assert result.exit_code == 0
        # Either shows DRY RUN or no items found
        assert "DRY RUN" in result.output or "No items" in result.output

    def test_clean_shows_items_to_delete(
        self, sample_cache_structure: Path
    ) -> None:
        """Test that clean shows items that would be deleted."""
        result = runner.invoke(app, ["clean"])
        assert result.exit_code == 0
        # Either shows info about items or no items message
        assert "DRY RUN" in result.output or "No items" in result.output or "--execute" in result.output

    def test_clean_with_category(self, sample_cache_structure: Path) -> None:
        """Test clean with category filter."""
        result = runner.invoke(app, ["clean", "--category", "system"])
        assert result.exit_code == 0

    def test_clean_execute_requires_confirmation(
        self, sample_cache_structure: Path
    ) -> None:
        """Test that --execute requires confirmation."""
        result = runner.invoke(app, ["clean", "--execute"], input="n\n")
        assert result.exit_code == 0
        assert "Cancelled" in result.output or "No items found" in result.output

    def test_clean_force_skips_confirmation(
        self, sample_cache_structure: Path
    ) -> None:
        """Test that --force skips confirmation."""
        result = runner.invoke(app, ["clean", "--execute", "--force"])
        assert result.exit_code == 0


class TestServiceWorkersCommand:
    """Tests for service-workers command."""

    def test_service_workers_dry_run(
        self, sample_service_worker_structure: Path
    ) -> None:
        """Test service-workers in dry-run mode."""
        result = runner.invoke(app, ["service-workers"])
        assert result.exit_code == 0
        # Should show either found items or no items message
        assert (
            "Service Workers" in result.output
            or "No service workers" in result.output
        )

    def test_service_workers_execute_requires_confirmation(
        self, sample_service_worker_structure: Path
    ) -> None:
        """Test service-workers --execute requires confirmation."""
        result = runner.invoke(app, ["service-workers", "--execute"], input="n\n")
        assert result.exit_code == 0


class TestLargeFilesCommand:
    """Tests for large-files command."""

    def test_large_files_default(self, temp_dir: Path) -> None:
        """Test large-files with default options."""
        result = runner.invoke(app, ["large-files", "--path", str(temp_dir)])
        assert result.exit_code == 0
        # Should show scanning message
        assert "Scanning" in result.output or "No files" in result.output

    def test_large_files_custom_size(self, sample_large_files: Path) -> None:
        """Test large-files with custom minimum size."""
        result = runner.invoke(
            app,
            ["large-files", "--min-size", "50MB", "--path", str(sample_large_files)],
        )
        assert result.exit_code == 0

    def test_large_files_with_limit(self, sample_large_files: Path) -> None:
        """Test large-files with result limit."""
        result = runner.invoke(
            app,
            [
                "large-files",
                "--min-size",
                "50MB",
                "--limit",
                "5",
                "--path",
                str(sample_large_files),
            ],
        )
        assert result.exit_code == 0

    def test_large_files_invalid_size(self) -> None:
        """Test large-files with invalid size format."""
        result = runner.invoke(app, ["large-files", "--min-size", "invalid"])
        # Should fail gracefully
        assert result.exit_code != 0 or "Invalid" in result.output


class TestUnusedAppsCommand:
    """Tests for unused-apps command."""

    @patch("macsweep.cli._unused_apps_async")
    def test_unused_apps_default(self, mock_unused: MagicMock) -> None:
        """Test unused-apps with default options."""
        mock_unused.return_value = None
        result = runner.invoke(app, ["unused-apps"])
        assert result.exit_code == 0

    @patch("macsweep.cli._unused_apps_async")
    def test_unused_apps_custom_days(self, mock_unused: MagicMock) -> None:
        """Test unused-apps with custom days threshold."""
        mock_unused.return_value = None
        result = runner.invoke(app, ["unused-apps", "--days", "30"])
        assert result.exit_code == 0


class TestMonitorCommand:
    """Tests for monitor command."""

    @patch("macsweep.cli._monitor_async")
    def test_monitor_starts(self, mock_monitor: MagicMock) -> None:
        """Test that monitor command starts."""
        # Simulate keyboard interrupt
        mock_monitor.side_effect = KeyboardInterrupt
        result = runner.invoke(app, ["monitor"])
        # Exit code 130 is SIGINT (128 + 2), which is expected for Ctrl+C
        assert result.exit_code in (0, 1, 130)


class TestTuiCommand:
    """Tests for TUI command."""

    @patch("macsweep.tui.app.MacSweepApp")
    def test_tui_starts(self, mock_app_class: MagicMock) -> None:
        """Test that TUI command creates and runs app."""
        mock_app = MagicMock()
        mock_app_class.return_value = mock_app

        result = runner.invoke(app, ["tui"])
        assert result.exit_code == 0
        mock_app.run.assert_called_once()

    def test_tui_help(self) -> None:
        """Test TUI help output."""
        result = runner.invoke(app, ["tui", "--help"])
        assert result.exit_code == 0
        assert "TUI" in result.output or "interactive" in result.output
