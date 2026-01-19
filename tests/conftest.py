"""Pytest configuration and fixtures for MacSweep tests."""

import tempfile
from pathlib import Path
from typing import Generator
from unittest.mock import MagicMock

import pytest


@pytest.fixture
def temp_dir() -> Generator[Path, None, None]:
    """Create a temporary directory for testing."""
    with tempfile.TemporaryDirectory() as tmpdir:
        yield Path(tmpdir)


@pytest.fixture
def mock_home(temp_dir: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Mock the home directory for testing."""
    # Create expected directory structure
    library = temp_dir / "Library"
    library.mkdir()
    (library / "Caches").mkdir()
    (library / "Logs").mkdir()
    (library / "Application Support").mkdir()
    (library / "Preferences").mkdir()

    # Standard user directories
    for dirname in ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music"]:
        (temp_dir / dirname).mkdir()

    # Credential directories
    for dirname in [".ssh", ".gnupg", ".aws"]:
        (temp_dir / dirname).mkdir()

    monkeypatch.setattr(Path, "home", lambda: temp_dir)
    return temp_dir


@pytest.fixture
def sample_cache_structure(mock_home: Path) -> Path:
    """Create a sample cache structure for testing."""
    caches = mock_home / "Library" / "Caches"

    # Create some sample cache directories
    app_cache = caches / "com.example.app"
    app_cache.mkdir()
    (app_cache / "data.cache").write_bytes(b"x" * 2 * 1024 * 1024)  # 2MB

    browser_cache = caches / "com.browser.cache"
    browser_cache.mkdir()
    (browser_cache / "file1.dat").write_bytes(b"y" * 5 * 1024 * 1024)  # 5MB
    (browser_cache / "file2.dat").write_bytes(b"z" * 3 * 1024 * 1024)  # 3MB

    # Small cache that should be skipped
    small_cache = caches / "com.small.cache"
    small_cache.mkdir()
    (small_cache / "tiny.dat").write_bytes(b"t" * 100)  # 100 bytes

    return mock_home


@pytest.fixture
def sample_service_worker_structure(mock_home: Path) -> Path:
    """Create sample service worker directories for testing."""
    app_support = mock_home / "Library" / "Application Support"

    # Chrome-like service worker
    chrome_sw = app_support / "Google" / "Chrome" / "Default" / "Service Worker"
    chrome_sw.mkdir(parents=True)
    (chrome_sw / "CacheStorage").mkdir()
    (chrome_sw / "CacheStorage" / "data.bin").write_bytes(b"c" * 1024 * 1024)

    # VS Code-like service worker
    vscode_sw = app_support / "Code" / "Service Worker"
    vscode_sw.mkdir(parents=True)
    (vscode_sw / "CacheStorage").mkdir()
    (vscode_sw / "CacheStorage" / "cache.db").write_bytes(b"v" * 2 * 1024 * 1024)

    return mock_home


@pytest.fixture
def mock_subprocess() -> Generator[MagicMock, None, None]:
    """Mock subprocess for system command tests."""
    mock = MagicMock()
    yield mock


@pytest.fixture
def sample_large_files(temp_dir: Path) -> Path:
    """Create sample large files for testing."""
    # Create a directory structure with large files
    docs = temp_dir / "docs"
    docs.mkdir()
    (docs / "large_video.mp4").write_bytes(b"v" * 150 * 1024 * 1024)  # 150MB
    (docs / "huge_archive.zip").write_bytes(b"a" * 200 * 1024 * 1024)  # 200MB

    images = temp_dir / "images"
    images.mkdir()
    (images / "photo.jpg").write_bytes(b"p" * 50 * 1024 * 1024)  # 50MB (below threshold)

    # Create nested structure
    nested = temp_dir / "nested" / "deep" / "folder"
    nested.mkdir(parents=True)
    (nested / "backup.tar").write_bytes(b"b" * 120 * 1024 * 1024)  # 120MB

    return temp_dir


@pytest.fixture
def sensitive_files(temp_dir: Path) -> Path:
    """Create sensitive files that should be protected."""
    ssh = temp_dir / ".ssh"
    ssh.mkdir(exist_ok=True)
    (ssh / "id_rsa").write_text("PRIVATE KEY")
    (ssh / "id_rsa.pub").write_text("PUBLIC KEY")

    # Browser credentials
    browser = temp_dir / "Library" / "Application Support" / "Chrome" / "Default"
    browser.mkdir(parents=True)
    (browser / "Login Data").write_bytes(b"encrypted")
    (browser / "Cookies").write_bytes(b"cookies")
    (browser / "History").write_bytes(b"history")

    # Create a .pem file
    (temp_dir / "cert.pem").write_text("CERTIFICATE")

    return temp_dir
