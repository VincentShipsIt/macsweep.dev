"""Tests for analyzer modules."""

from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import patch

import pytest

from macsweep.analyzers.large_files import LargeFileFinder


class TestLargeFileFinder:
    """Tests for LargeFileFinder class."""

    def test_initialization_default(self) -> None:
        """Test default initialization."""
        finder = LargeFileFinder()
        assert finder.min_size == 100 * 1024 * 1024  # 100MB

    def test_initialization_custom_size(self) -> None:
        """Test custom size initialization."""
        finder = LargeFileFinder(min_size_bytes=50 * 1024 * 1024)
        assert finder.min_size == 50 * 1024 * 1024

    @pytest.mark.asyncio
    async def test_find_empty_directory(self, temp_dir: Path) -> None:
        """Test finding in empty directory."""
        finder = LargeFileFinder(min_size_bytes=1024)
        results = await finder.find(temp_dir)
        assert len(results) == 0

    @pytest.mark.asyncio
    async def test_find_large_files(self, sample_large_files: Path) -> None:
        """Test finding large files."""
        finder = LargeFileFinder(min_size_bytes=100 * 1024 * 1024)
        results = await finder.find(sample_large_files, limit=10)

        # Should find files >= 100MB
        assert len(results) > 0
        for path, size, modified in results:
            assert size >= 100 * 1024 * 1024

    @pytest.mark.asyncio
    async def test_find_respects_limit(self, sample_large_files: Path) -> None:
        """Test that limit is respected."""
        finder = LargeFileFinder(min_size_bytes=50 * 1024 * 1024)
        results = await finder.find(sample_large_files, limit=2)
        assert len(results) <= 2

    @pytest.mark.asyncio
    async def test_find_returns_all_matching_files(self, temp_dir: Path) -> None:
        """Test that find returns all files matching the size criteria."""
        # Create files with known sizes
        (temp_dir / "small.bin").write_bytes(b"x" * 60 * 1024 * 1024)  # 60MB
        (temp_dir / "medium.bin").write_bytes(b"y" * 80 * 1024 * 1024)  # 80MB
        (temp_dir / "large.bin").write_bytes(b"z" * 100 * 1024 * 1024)  # 100MB

        finder = LargeFileFinder(min_size_bytes=50 * 1024 * 1024)
        results = await finder.find(temp_dir, limit=10)

        assert len(results) == 3
        # Verify all expected sizes are present
        sizes = {r[1] for r in results}
        assert 60 * 1024 * 1024 in sizes
        assert 80 * 1024 * 1024 in sizes
        assert 100 * 1024 * 1024 in sizes

    @pytest.mark.asyncio
    async def test_find_skips_git_directories(self, temp_dir: Path) -> None:
        """Test that .git directories are skipped."""
        finder = LargeFileFinder(min_size_bytes=1024)

        # Create a large file in .git
        git_dir = temp_dir / ".git" / "objects"
        git_dir.mkdir(parents=True)
        large_git_file = git_dir / "pack.pack"
        large_git_file.write_bytes(b"x" * 100 * 1024)

        results = await finder.find(temp_dir, include_hidden=True)
        git_results = [r for r in results if ".git" in str(r[0])]
        assert len(git_results) == 0

    @pytest.mark.asyncio
    async def test_find_skips_node_modules(self, temp_dir: Path) -> None:
        """Test that node_modules directories are skipped."""
        finder = LargeFileFinder(min_size_bytes=1024)

        # Create a large file in node_modules
        node_modules = temp_dir / "project" / "node_modules" / "package"
        node_modules.mkdir(parents=True)
        large_file = node_modules / "bundle.js"
        large_file.write_bytes(b"x" * 100 * 1024)

        results = await finder.find(temp_dir)
        nm_results = [r for r in results if "node_modules" in str(r[0])]
        assert len(nm_results) == 0

    @pytest.mark.asyncio
    async def test_find_skips_hidden_by_default(self, temp_dir: Path) -> None:
        """Test that hidden files are skipped by default."""
        finder = LargeFileFinder(min_size_bytes=1024)

        # Create a large hidden file
        hidden_file = temp_dir / ".hidden_large_file"
        hidden_file.write_bytes(b"x" * 100 * 1024)

        results = await finder.find(temp_dir, include_hidden=False)
        hidden_results = [r for r in results if r[0].name.startswith(".")]
        assert len(hidden_results) == 0

    @pytest.mark.asyncio
    async def test_find_includes_hidden_when_requested(
        self, temp_dir: Path
    ) -> None:
        """Test that hidden files are included when requested."""
        finder = LargeFileFinder(min_size_bytes=1024)

        # Create a large hidden file
        hidden_file = temp_dir / ".hidden_large_file"
        hidden_file.write_bytes(b"x" * 100 * 1024)

        results = await finder.find(temp_dir, include_hidden=True)
        hidden_results = [r for r in results if r[0].name.startswith(".")]
        assert len(hidden_results) == 1

    @pytest.mark.asyncio
    async def test_find_returns_modification_dates(
        self, sample_large_files: Path
    ) -> None:
        """Test that modification dates are returned."""
        finder = LargeFileFinder(min_size_bytes=100 * 1024 * 1024)
        results = await finder.find(sample_large_files)

        for path, size, modified in results:
            assert isinstance(modified, datetime)
            # Should be within the last hour (recently created)
            assert modified > datetime.now() - timedelta(hours=1)

    @pytest.mark.asyncio
    async def test_find_handles_permission_errors(self, temp_dir: Path) -> None:
        """Test that permission errors are handled gracefully."""
        finder = LargeFileFinder(min_size_bytes=1024)

        # Mock permission error
        with patch.object(Path, "iterdir", side_effect=PermissionError):
            results = await finder.find(temp_dir)
            # Should return empty list, not raise
            assert results == []


class TestLargeFileFinderDownloads:
    """Tests for find_in_downloads method."""

    @pytest.mark.asyncio
    async def test_find_in_downloads_empty(self, mock_home: Path) -> None:
        """Test finding in empty Downloads."""
        finder = LargeFileFinder(min_size_bytes=1024)
        results = await finder.find_in_downloads(days_old=30)
        assert len(results) == 0

    @pytest.mark.asyncio
    async def test_find_in_downloads_old_files(self, mock_home: Path) -> None:
        """Test finding old files in Downloads."""
        finder = LargeFileFinder(min_size_bytes=1024)
        downloads = mock_home / "Downloads"

        # Create a large file
        old_file = downloads / "old_download.zip"
        old_file.write_bytes(b"x" * 100 * 1024)

        # Set modification time to 60 days ago
        import os

        old_time = datetime.now().timestamp() - (60 * 24 * 60 * 60)
        os.utime(old_file, (old_time, old_time))

        results = await finder.find_in_downloads(days_old=30)
        assert len(results) == 1
        assert results[0][0] == old_file

    @pytest.mark.asyncio
    async def test_find_in_downloads_skips_recent(self, mock_home: Path) -> None:
        """Test that recent files are skipped."""
        finder = LargeFileFinder(min_size_bytes=1024)
        downloads = mock_home / "Downloads"

        # Create a large file (recently created)
        new_file = downloads / "new_download.zip"
        new_file.write_bytes(b"x" * 100 * 1024)

        results = await finder.find_in_downloads(days_old=30)
        # Should not find the recent file
        assert len(results) == 0

    @pytest.mark.asyncio
    async def test_find_in_downloads_sorted_by_size(
        self, mock_home: Path
    ) -> None:
        """Test that Downloads results are sorted by size."""
        finder = LargeFileFinder(min_size_bytes=1024)
        downloads = mock_home / "Downloads"

        import os

        old_time = datetime.now().timestamp() - (60 * 24 * 60 * 60)

        # Create files of different sizes
        file1 = downloads / "small.zip"
        file1.write_bytes(b"x" * 10 * 1024)
        os.utime(file1, (old_time, old_time))

        file2 = downloads / "large.zip"
        file2.write_bytes(b"x" * 100 * 1024)
        os.utime(file2, (old_time, old_time))

        file3 = downloads / "medium.zip"
        file3.write_bytes(b"x" * 50 * 1024)
        os.utime(file3, (old_time, old_time))

        results = await finder.find_in_downloads(days_old=30)
        assert len(results) == 3
        # Should be sorted by size descending
        assert results[0][1] > results[1][1] > results[2][1]

    @pytest.mark.asyncio
    async def test_find_in_downloads_nonexistent(self, temp_dir: Path) -> None:
        """Test behavior when Downloads doesn't exist."""
        finder = LargeFileFinder(min_size_bytes=1024)

        with patch.object(Path, "home", return_value=temp_dir):
            # Downloads doesn't exist in temp_dir
            results = await finder.find_in_downloads(days_old=30)
            assert results == []
