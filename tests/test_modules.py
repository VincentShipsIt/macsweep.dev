"""Tests for cleanup modules."""

from pathlib import Path

import pytest

from macsweep.modules.base import CleanupItem, CleanupModule, ScanResult


class TestCleanupItem:
    """Tests for CleanupItem dataclass."""

    def test_creation(self, temp_dir: Path) -> None:
        """Test creating a CleanupItem."""
        item = CleanupItem(
            path=temp_dir / "cache",
            size=1024 * 1024,
            category="System",
            subcategory="Caches",
            description="Test cache",
        )
        assert item.path == temp_dir / "cache"
        assert item.size == 1024 * 1024
        assert item.category == "System"
        assert item.safe_to_delete is True
        assert item.requires_confirmation is False

    def test_format_size_bytes(self) -> None:
        """Test size formatting for bytes."""
        item = CleanupItem(
            path=Path("/test"),
            size=512,
            category="Test",
            subcategory="Test",
            description="Test",
        )
        assert item.format_size() == "512 B"

    def test_format_size_kilobytes(self) -> None:
        """Test size formatting for kilobytes."""
        item = CleanupItem(
            path=Path("/test"),
            size=5120,  # 5KB
            category="Test",
            subcategory="Test",
            description="Test",
        )
        assert item.format_size() == "5.0 KB"

    def test_format_size_megabytes(self) -> None:
        """Test size formatting for megabytes."""
        item = CleanupItem(
            path=Path("/test"),
            size=5 * 1024 * 1024,  # 5MB
            category="Test",
            subcategory="Test",
            description="Test",
        )
        assert item.format_size() == "5.0 MB"

    def test_format_size_gigabytes(self) -> None:
        """Test size formatting for gigabytes."""
        item = CleanupItem(
            path=Path("/test"),
            size=2 * 1024 * 1024 * 1024,  # 2GB
            category="Test",
            subcategory="Test",
            description="Test",
        )
        assert item.format_size() == "2.00 GB"

    def test_str_representation(self) -> None:
        """Test string representation."""
        item = CleanupItem(
            path=Path("/test"),
            size=1024 * 1024,
            category="Test",
            subcategory="Test",
            description="Test cache",
        )
        assert "Test cache" in str(item)
        assert "1.0 MB" in str(item)


class TestScanResult:
    """Tests for ScanResult dataclass."""

    def test_empty_result(self) -> None:
        """Test empty scan result."""
        result = ScanResult(module_name="Test Module")
        assert result.module_name == "Test Module"
        assert result.items == []
        assert result.total_size == 0
        assert result.error is None

    def test_result_with_items(self) -> None:
        """Test scan result with items."""
        items = [
            CleanupItem(
                path=Path("/test1"),
                size=1000,
                category="Test",
                subcategory="Test",
                description="Item 1",
            ),
            CleanupItem(
                path=Path("/test2"),
                size=2000,
                category="Test",
                subcategory="Test",
                description="Item 2",
            ),
        ]
        result = ScanResult(module_name="Test Module", items=items)
        assert len(result.items) == 2
        assert result.total_size == 3000

    def test_result_with_error(self) -> None:
        """Test scan result with error."""
        result = ScanResult(module_name="Test Module", error="Permission denied")
        assert result.error == "Permission denied"

    def test_explicit_total_size_not_overwritten(self) -> None:
        """Test that explicit total_size is preserved."""
        items = [
            CleanupItem(
                path=Path("/test"),
                size=1000,
                category="Test",
                subcategory="Test",
                description="Item",
            ),
        ]
        result = ScanResult(module_name="Test", items=items, total_size=5000)
        # Explicit total_size should be preserved
        assert result.total_size == 5000


class ConcreteCleanupModule(CleanupModule):
    """Concrete implementation for testing."""

    name = "Test Module"
    description = "Test module for testing"
    category = "Test"

    def __init__(self, items: list[CleanupItem] | None = None) -> None:
        self._items = items or []

    async def scan(self):
        """Yield test items."""
        for item in self._items:
            yield item


class TestCleanupModule:
    """Tests for CleanupModule abstract base class."""

    @pytest.mark.asyncio
    async def test_scan_empty(self) -> None:
        """Test scanning with no items."""
        module = ConcreteCleanupModule([])
        items = [item async for item in module.scan()]
        assert len(items) == 0

    @pytest.mark.asyncio
    async def test_scan_with_items(self) -> None:
        """Test scanning with items."""
        test_items = [
            CleanupItem(
                path=Path("/test1"),
                size=1000,
                category="Test",
                subcategory="Test",
                description="Item 1",
            ),
            CleanupItem(
                path=Path("/test2"),
                size=2000,
                category="Test",
                subcategory="Test",
                description="Item 2",
            ),
        ]
        module = ConcreteCleanupModule(test_items)
        items = [item async for item in module.scan()]
        assert len(items) == 2

    @pytest.mark.asyncio
    async def test_get_scan_result(self) -> None:
        """Test get_scan_result method."""
        test_items = [
            CleanupItem(
                path=Path("/test"),
                size=1000,
                category="Test",
                subcategory="Test",
                description="Item",
            ),
        ]
        module = ConcreteCleanupModule(test_items)
        result = await module.get_scan_result()

        assert result.module_name == "Test Module"
        assert len(result.items) == 1
        assert result.total_size == 1000
        assert result.error is None

    @pytest.mark.asyncio
    async def test_clean_dry_run(self, temp_dir: Path) -> None:
        """Test clean in dry-run mode."""
        # Create a test file
        test_file = temp_dir / "cache.dat"
        test_file.write_bytes(b"x" * 1000)

        item = CleanupItem(
            path=test_file,
            size=1000,
            category="Test",
            subcategory="Test",
            description="Test file",
        )
        module = ConcreteCleanupModule([item])

        bytes_freed = await module.clean([item], dry_run=True)
        assert bytes_freed == 1000
        # File should still exist
        assert test_file.exists()

    @pytest.mark.asyncio
    async def test_clean_execute_file(self, temp_dir: Path) -> None:
        """Test clean in execute mode for a file."""
        test_file = temp_dir / "cache.dat"
        test_file.write_bytes(b"x" * 1000)

        item = CleanupItem(
            path=test_file,
            size=1000,
            category="Test",
            subcategory="Test",
            description="Test file",
        )
        module = ConcreteCleanupModule([item])

        bytes_freed = await module.clean([item], dry_run=False)
        assert bytes_freed == 1000
        # File should be deleted
        assert not test_file.exists()

    @pytest.mark.asyncio
    async def test_clean_execute_directory(self, temp_dir: Path) -> None:
        """Test clean in execute mode for a directory."""
        test_dir = temp_dir / "cache_dir"
        test_dir.mkdir()
        (test_dir / "file1.dat").write_bytes(b"x" * 500)
        (test_dir / "file2.dat").write_bytes(b"y" * 500)

        item = CleanupItem(
            path=test_dir,
            size=1000,
            category="Test",
            subcategory="Test",
            description="Test directory",
        )
        module = ConcreteCleanupModule([item])

        bytes_freed = await module.clean([item], dry_run=False)
        assert bytes_freed == 1000
        # Directory should be deleted
        assert not test_dir.exists()

    @pytest.mark.asyncio
    async def test_clean_skips_unsafe_items(self, temp_dir: Path) -> None:
        """Test that clean skips items marked as unsafe."""
        test_file = temp_dir / "important.dat"
        test_file.write_bytes(b"x" * 1000)

        item = CleanupItem(
            path=test_file,
            size=1000,
            category="Test",
            subcategory="Test",
            description="Important file",
            safe_to_delete=False,
        )
        module = ConcreteCleanupModule([item])

        bytes_freed = await module.clean([item], dry_run=False)
        assert bytes_freed == 0
        # File should still exist
        assert test_file.exists()

    def test_is_available_default(self) -> None:
        """Test default is_available implementation."""
        module = ConcreteCleanupModule([])
        assert module.is_available() is True

    def test_get_dir_size(self, temp_dir: Path) -> None:
        """Test _get_dir_size method."""
        test_dir = temp_dir / "test_dir"
        test_dir.mkdir()
        (test_dir / "file1.dat").write_bytes(b"x" * 1000)
        (test_dir / "file2.dat").write_bytes(b"y" * 2000)

        module = ConcreteCleanupModule([])
        size = module._get_dir_size(test_dir)
        assert size == 3000


class TestSystemCachesModule:
    """Tests for SystemCachesModule."""

    @pytest.mark.asyncio
    async def test_scan_caches_runs(self) -> None:
        """Test that scan runs without error."""
        from macsweep.modules.system.caches import SystemCachesModule

        module = SystemCachesModule()
        # Just verify scan runs without errors
        items = [item async for item in module.scan()]
        # Items found depends on system state, but all should be > 1MB
        for item in items:
            assert item.size >= 1024 * 1024

    @pytest.mark.asyncio
    async def test_get_scan_result(self) -> None:
        """Test get_scan_result method."""
        from macsweep.modules.system.caches import SystemCachesModule

        module = SystemCachesModule()
        result = await module.get_scan_result()

        assert result.module_name == "System Caches"
        assert result.error is None  # No errors
        # Total size should match items
        if result.items:
            assert result.total_size == sum(item.size for item in result.items)

    def test_module_attributes(self) -> None:
        """Test module attributes."""
        from macsweep.modules.system.caches import SystemCachesModule

        module = SystemCachesModule()
        assert module.name == "System Caches"
        assert module.category == "System"
        assert module.safe_by_default is True

    def test_cache_skip_patterns(self) -> None:
        """Test that skip patterns include sensitive caches."""
        from macsweep.modules.system.caches import SystemCachesModule

        module = SystemCachesModule()
        # CloudKit and Safari should be in skip patterns
        assert "CloudKit" in module.CACHE_SKIP_PATTERNS
        assert "com.apple.Safari" in module.CACHE_SKIP_PATTERNS
