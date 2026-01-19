"""Tests for safety module."""

from pathlib import Path

import pytest

from macsweep.core.safety import SafetyChecker, SafetyConfig


class TestSafetyConfig:
    """Tests for SafetyConfig dataclass."""

    def test_default_values(self) -> None:
        """Test default configuration values."""
        config = SafetyConfig()
        assert config.dry_run is True
        assert config.require_confirmation is True
        assert config.backup_before_delete is False
        assert config.max_delete_size_gb == 10.0
        assert len(config.protected_paths) > 0

    def test_custom_values(self) -> None:
        """Test custom configuration values."""
        config = SafetyConfig(
            dry_run=False,
            require_confirmation=False,
            max_delete_size_gb=5.0,
            protected_paths=["/custom/path"],
        )
        assert config.dry_run is False
        assert config.require_confirmation is False
        assert config.max_delete_size_gb == 5.0
        assert config.protected_paths == ["/custom/path"]

    def test_default_protected_paths_include_sensitive_dirs(self) -> None:
        """Test that default protected paths include sensitive directories."""
        config = SafetyConfig()
        paths = config.protected_paths

        assert "~/Documents" in paths
        assert "~/.ssh" in paths
        assert "~/.gnupg" in paths
        assert "~/.aws" in paths
        assert "~/Library/Keychains" in paths


class TestSafetyChecker:
    """Tests for SafetyChecker class."""

    def test_initialization_default_config(self) -> None:
        """Test initialization with default config."""
        checker = SafetyChecker()
        assert checker.config is not None
        assert checker.config.dry_run is True

    def test_initialization_custom_config(self) -> None:
        """Test initialization with custom config."""
        config = SafetyConfig(dry_run=False)
        checker = SafetyChecker(config)
        assert checker.config.dry_run is False


class TestIsSafeToDelete:
    """Tests for is_safe_to_delete method."""

    @pytest.fixture
    def checker(self) -> SafetyChecker:
        """Create a SafetyChecker instance."""
        return SafetyChecker()

    def test_system_paths_protected(self, checker: SafetyChecker) -> None:
        """Test that system paths are protected."""
        unsafe_paths = [
            Path("/System"),
            Path("/Applications"),
            Path("/usr"),
            Path("/bin"),
            Path("/Library"),
        ]
        for path in unsafe_paths:
            is_safe, reason = checker.is_safe_to_delete(path)
            assert is_safe is False
            assert "protected" in reason.lower()

    def test_real_user_data_protected(self) -> None:
        """Test that real user data directories are protected."""
        checker = SafetyChecker()

        # Test with real home paths (these should always be protected)
        protected_dirs = ["Documents", "Desktop", "Pictures", "Movies", "Music", "Downloads"]
        home = Path.home()
        for dirname in protected_dirs:
            path = home / dirname
            is_safe, reason = checker.is_safe_to_delete(path)
            assert is_safe is False, f"{dirname} should be protected"

    def test_real_credential_dirs_protected(self) -> None:
        """Test that real credential directories are protected."""
        checker = SafetyChecker()
        home = Path.home()

        cred_dirs = [".ssh", ".gnupg", ".aws"]
        for dirname in cred_dirs:
            path = home / dirname
            is_safe, reason = checker.is_safe_to_delete(path)
            assert is_safe is False, f"{dirname} should be protected"

    def test_cache_directories_safe(self) -> None:
        """Test that cache directories under real home are safe to delete."""
        checker = SafetyChecker()
        home = Path.home()

        # Test path that would be a cache dir
        cache_dir = home / "Library" / "Caches" / "com.example.test.app"
        is_safe, reason = checker.is_safe_to_delete(cache_dir)
        assert is_safe is True
        assert reason == "OK"

    def test_paths_outside_home_rejected(self, checker: SafetyChecker) -> None:
        """Test that paths outside home directory are rejected."""
        outside_paths = [
            Path("/tmp/somefile"),
            Path("/var/log/something"),
            Path("/etc/config"),
        ]
        for path in outside_paths:
            is_safe, reason = checker.is_safe_to_delete(path)
            assert is_safe is False
            assert "home" in reason.lower() or "protected" in reason.lower()


class TestSensitiveFileDetection:
    """Tests for sensitive file pattern detection."""

    @pytest.fixture
    def checker(self) -> SafetyChecker:
        """Create a SafetyChecker instance."""
        return SafetyChecker()

    def test_browser_credential_files(
        self, checker: SafetyChecker, mock_home: Path
    ) -> None:
        """Test that browser credential files are detected as sensitive."""
        sensitive_names = [
            "Login Data",
            "Cookies",
            "History",
            "Bookmarks",
            "logins.json",
            "key4.db",
        ]
        cache_dir = mock_home / "Library" / "Caches" / "browser"
        cache_dir.mkdir(parents=True)

        for name in sensitive_names:
            file_path = cache_dir / name
            file_path.touch()
            is_safe, reason = checker.is_safe_to_delete(file_path)
            assert is_safe is False, f"{name} should be detected as sensitive"
            assert "sensitive" in reason.lower()

    def test_encryption_key_files(
        self, checker: SafetyChecker, mock_home: Path
    ) -> None:
        """Test that encryption key files are detected as sensitive."""
        cache_dir = mock_home / "Library" / "Caches" / "keys"
        cache_dir.mkdir(parents=True)

        sensitive_extensions = [".pem", ".key", ".crt", ".p12", ".pfx"]
        for ext in sensitive_extensions:
            file_path = cache_dir / f"cert{ext}"
            file_path.touch()
            is_safe, reason = checker.is_safe_to_delete(file_path)
            assert is_safe is False, f"*{ext} should be detected as sensitive"

    def test_regular_cache_files_safe(
        self, checker: SafetyChecker, mock_home: Path
    ) -> None:
        """Test that regular cache files are safe to delete."""
        cache_dir = mock_home / "Library" / "Caches" / "app"
        cache_dir.mkdir(parents=True)

        safe_files = ["cache.dat", "image_cache.db", "temp_data.bin"]
        for name in safe_files:
            file_path = cache_dir / name
            file_path.touch()
            is_safe, reason = checker.is_safe_to_delete(file_path)
            assert is_safe is True, f"{name} should be safe to delete"


class TestSafeDirectoryNames:
    """Tests for safe directory name detection."""

    @pytest.fixture
    def checker(self) -> SafetyChecker:
        """Create a SafetyChecker instance."""
        return SafetyChecker()

    def test_known_safe_directories(self, checker: SafetyChecker) -> None:
        """Test that known safe directory names are recognized."""
        safe_names = [
            "Cache",
            "Code Cache",
            "GPUCache",
            "ShaderCache",
            "Service Worker",
            "__pycache__",
            "node_modules",
            "DerivedData",
        ]
        for name in safe_names:
            path = Path(f"/fake/{name}")
            assert checker.is_safe_directory(path) is True

    def test_unknown_directories_not_safe(self, checker: SafetyChecker) -> None:
        """Test that unknown directory names are not marked as safe."""
        unsafe_names = ["Documents", "Config", "Settings", "Data"]
        for name in unsafe_names:
            path = Path(f"/fake/{name}")
            assert checker.is_safe_directory(path) is False


class TestBatchValidation:
    """Tests for validate_batch method."""

    def test_mixed_paths(self) -> None:
        """Test validation of mixed safe and unsafe paths."""
        checker = SafetyChecker()
        home = Path.home()

        # Create test paths using real home
        paths = [
            home / "Library" / "Caches" / "com.test.app",  # Safe
            home / "Documents",  # Unsafe - protected
            home / ".ssh",  # Unsafe - credentials
        ]

        results = checker.validate_batch(paths)

        # Cache path should be safe, others should be blocked
        assert len(results["safe"]) == 1
        assert len(results["blocked"]) == 2

    def test_empty_batch(self) -> None:
        """Test validation of empty batch."""
        checker = SafetyChecker()
        results = checker.validate_batch([])
        assert results["safe"] == []
        assert results["blocked"] == []


class TestSizeLimitValidation:
    """Tests for check_size_limit method."""

    def test_within_limit(self) -> None:
        """Test size within limit."""
        config = SafetyConfig(max_delete_size_gb=10.0)
        checker = SafetyChecker(config)

        # 5GB - should be within limit
        size = 5 * 1024 * 1024 * 1024
        is_ok, reason = checker.check_size_limit(size)
        assert is_ok is True
        assert reason == "OK"

    def test_exceeds_limit(self) -> None:
        """Test size exceeds limit."""
        config = SafetyConfig(max_delete_size_gb=10.0)
        checker = SafetyChecker(config)

        # 15GB - should exceed limit
        size = 15 * 1024 * 1024 * 1024
        is_ok, reason = checker.check_size_limit(size)
        assert is_ok is False
        assert "exceeds limit" in reason.lower()

    def test_exactly_at_limit(self) -> None:
        """Test size exactly at limit."""
        config = SafetyConfig(max_delete_size_gb=10.0)
        checker = SafetyChecker(config)

        # Exactly 10GB
        size = 10 * 1024 * 1024 * 1024
        is_ok, reason = checker.check_size_limit(size)
        assert is_ok is True

    def test_custom_limit(self) -> None:
        """Test with custom size limit."""
        config = SafetyConfig(max_delete_size_gb=1.0)
        checker = SafetyChecker(config)

        # 500MB - within 1GB limit
        size_ok = 500 * 1024 * 1024
        is_ok, _ = checker.check_size_limit(size_ok)
        assert is_ok is True

        # 1.5GB - exceeds 1GB limit
        size_over = int(1.5 * 1024 * 1024 * 1024)
        is_ok, _ = checker.check_size_limit(size_over)
        assert is_ok is False
