"""Tests for utility modules."""

from pathlib import Path
from unittest.mock import patch

import pytest

from macsweep.utils.paths import expand_path, get_dir_size, safe_glob, safe_iterdir
from macsweep.utils.size import format_size, parse_size


class TestFormatSize:
    """Tests for format_size function."""

    def test_bytes(self) -> None:
        """Test formatting bytes."""
        assert format_size(0) == "0 B"
        assert format_size(512) == "512 B"
        assert format_size(1023) == "1023 B"

    def test_kilobytes(self) -> None:
        """Test formatting kilobytes."""
        assert format_size(1024) == "1.0 KB"
        assert format_size(1536) == "1.5 KB"
        assert format_size(10240) == "10.0 KB"
        assert format_size(1048575) == "1024.0 KB"

    def test_megabytes(self) -> None:
        """Test formatting megabytes."""
        assert format_size(1048576) == "1.0 MB"
        assert format_size(1572864) == "1.5 MB"
        assert format_size(104857600) == "100.0 MB"

    def test_gigabytes(self) -> None:
        """Test formatting gigabytes."""
        assert format_size(1073741824) == "1.00 GB"
        assert format_size(1610612736) == "1.50 GB"
        assert format_size(10737418240) == "10.00 GB"

    def test_large_sizes(self) -> None:
        """Test formatting very large sizes."""
        assert format_size(107374182400) == "100.00 GB"
        assert format_size(1099511627776) == "1024.00 GB"


class TestParseSize:
    """Tests for parse_size function."""

    def test_bytes(self) -> None:
        """Test parsing bytes."""
        assert parse_size("100") == 100
        assert parse_size("100B") == 100
        assert parse_size("100 B") == 100

    def test_kilobytes(self) -> None:
        """Test parsing kilobytes."""
        assert parse_size("1KB") == 1024
        assert parse_size("1.5KB") == 1536
        assert parse_size("100 KB") == 102400

    def test_megabytes(self) -> None:
        """Test parsing megabytes."""
        assert parse_size("1MB") == 1048576
        assert parse_size("1.5MB") == 1572864
        assert parse_size("100MB") == 104857600

    def test_gigabytes(self) -> None:
        """Test parsing gigabytes."""
        assert parse_size("1GB") == 1073741824
        assert parse_size("1.5GB") == 1610612736
        assert parse_size("10 GB") == 10737418240

    def test_terabytes(self) -> None:
        """Test parsing terabytes."""
        assert parse_size("1TB") == 1099511627776

    def test_case_insensitive(self) -> None:
        """Test that parsing is case insensitive."""
        assert parse_size("100mb") == 104857600
        assert parse_size("100Mb") == 104857600
        assert parse_size("100MB") == 104857600

    def test_whitespace_handling(self) -> None:
        """Test that whitespace is handled correctly."""
        assert parse_size("  100MB  ") == 104857600
        assert parse_size("100 MB") == 104857600

    def test_invalid_format(self) -> None:
        """Test that invalid formats raise ValueError."""
        with pytest.raises(ValueError, match="Invalid size format"):
            parse_size("invalid")
        with pytest.raises(ValueError, match="Invalid size format"):
            parse_size("100XB")
        with pytest.raises(ValueError, match="Invalid size format"):
            parse_size("")


class TestExpandPath:
    """Tests for expand_path function."""

    def test_tilde_expansion(self) -> None:
        """Test that ~ is expanded to home directory."""
        result = expand_path("~/Documents")
        assert "~" not in str(result)
        assert result == Path.home() / "Documents"

    def test_absolute_path(self) -> None:
        """Test that absolute paths are preserved."""
        result = expand_path("/usr/local/bin")
        assert result == Path("/usr/local/bin")

    def test_relative_path(self) -> None:
        """Test that relative paths work."""
        result = expand_path("relative/path")
        assert result == Path("relative/path")


class TestGetDirSize:
    """Tests for get_dir_size function."""

    def test_empty_directory(self, temp_dir: Path) -> None:
        """Test size of empty directory."""
        assert get_dir_size(temp_dir) == 0

    def test_directory_with_files(self, temp_dir: Path) -> None:
        """Test size calculation with files."""
        (temp_dir / "file1.txt").write_bytes(b"x" * 1000)
        (temp_dir / "file2.txt").write_bytes(b"y" * 2000)
        assert get_dir_size(temp_dir) == 3000

    def test_nested_directory(self, temp_dir: Path) -> None:
        """Test size calculation with nested directories."""
        subdir = temp_dir / "subdir"
        subdir.mkdir()
        (temp_dir / "file1.txt").write_bytes(b"x" * 1000)
        (subdir / "file2.txt").write_bytes(b"y" * 2000)
        assert get_dir_size(temp_dir) == 3000

    def test_nonexistent_directory(self, temp_dir: Path) -> None:
        """Test handling of non-existent directory."""
        nonexistent = temp_dir / "nonexistent"
        assert get_dir_size(nonexistent) == 0

    def test_permission_error_handling(self, temp_dir: Path) -> None:
        """Test that permission errors are handled gracefully."""
        # Create a directory with a file
        (temp_dir / "file.txt").write_bytes(b"x" * 100)

        # Mock permission error
        with patch.object(Path, "rglob", side_effect=PermissionError):
            # Should return 0 and not raise
            assert get_dir_size(temp_dir) == 0


class TestSafeIterdir:
    """Tests for safe_iterdir function."""

    def test_normal_directory(self, temp_dir: Path) -> None:
        """Test iterating normal directory."""
        (temp_dir / "file1.txt").touch()
        (temp_dir / "file2.txt").touch()

        items = list(safe_iterdir(temp_dir))
        assert len(items) == 2

    def test_empty_directory(self, temp_dir: Path) -> None:
        """Test iterating empty directory."""
        items = list(safe_iterdir(temp_dir))
        assert len(items) == 0

    def test_nonexistent_directory(self, temp_dir: Path) -> None:
        """Test iterating non-existent directory."""
        nonexistent = temp_dir / "nonexistent"
        items = list(safe_iterdir(nonexistent))
        assert len(items) == 0


class TestSafeGlob:
    """Tests for safe_glob function."""

    def test_normal_glob(self, temp_dir: Path) -> None:
        """Test normal glob pattern matching."""
        (temp_dir / "file1.txt").touch()
        (temp_dir / "file2.txt").touch()
        (temp_dir / "file3.py").touch()

        txt_files = list(safe_glob(temp_dir, "*.txt"))
        assert len(txt_files) == 2

    def test_recursive_glob(self, temp_dir: Path) -> None:
        """Test recursive glob pattern."""
        subdir = temp_dir / "subdir"
        subdir.mkdir()
        (temp_dir / "file1.txt").touch()
        (subdir / "file2.txt").touch()

        all_txt = list(safe_glob(temp_dir, "**/*.txt"))
        assert len(all_txt) == 2

    def test_no_matches(self, temp_dir: Path) -> None:
        """Test glob with no matches."""
        (temp_dir / "file.txt").touch()

        matches = list(safe_glob(temp_dir, "*.py"))
        assert len(matches) == 0

    def test_nonexistent_directory(self, temp_dir: Path) -> None:
        """Test glob on non-existent directory."""
        nonexistent = temp_dir / "nonexistent"
        matches = list(safe_glob(nonexistent, "*"))
        assert len(matches) == 0
