"""Tests for logging module."""

import json
import logging
from pathlib import Path
from unittest.mock import patch

import pytest

from macsweep.core.logging import (
    AuditEvent,
    LogConfig,
    MacSweepLogger,
    configure_logging,
    get_logger,
)


class TestLogConfig:
    """Tests for LogConfig dataclass."""

    def test_default_values(self) -> None:
        """Test default configuration values."""
        config = LogConfig()
        assert config.level == logging.INFO
        assert config.enable_file_logging is True
        assert config.enable_console_logging is False
        assert config.max_file_size_mb == 10
        assert config.backup_count == 5
        assert config.enable_audit_log is True

    def test_custom_values(self) -> None:
        """Test custom configuration values."""
        config = LogConfig(
            level=logging.DEBUG,
            enable_file_logging=False,
            enable_console_logging=True,
            max_file_size_mb=5,
            backup_count=3,
        )
        assert config.level == logging.DEBUG
        assert config.enable_file_logging is False
        assert config.enable_console_logging is True
        assert config.max_file_size_mb == 5
        assert config.backup_count == 3

    def test_log_dir_string_conversion(self, temp_dir: Path) -> None:
        """Test that string log_dir is converted to Path."""
        config = LogConfig(log_dir=str(temp_dir))
        assert isinstance(config.log_dir, Path)
        assert config.log_dir == temp_dir


class TestAuditEvent:
    """Tests for AuditEvent dataclass."""

    def test_creation(self) -> None:
        """Test creating an AuditEvent."""
        event = AuditEvent(
            timestamp="2024-01-15T10:30:00",
            event_type="deletion",
            path="/home/user/cache",
            size_bytes=1024,
            category="System",
            subcategory="Caches",
            success=True,
            dry_run=False,
        )
        assert event.timestamp == "2024-01-15T10:30:00"
        assert event.event_type == "deletion"
        assert event.success is True

    def test_to_json(self) -> None:
        """Test JSON serialization."""
        event = AuditEvent(
            timestamp="2024-01-15T10:30:00",
            event_type="deletion",
            path="/home/user/cache",
            size_bytes=1024,
            category="System",
            subcategory="Caches",
            success=True,
            dry_run=False,
        )
        json_str = event.to_json()
        data = json.loads(json_str)

        assert data["timestamp"] == "2024-01-15T10:30:00"
        assert data["event_type"] == "deletion"
        assert data["path"] == "/home/user/cache"
        assert data["size_bytes"] == 1024
        assert data["success"] is True
        assert data["dry_run"] is False

    def test_to_json_with_error(self) -> None:
        """Test JSON serialization with error."""
        event = AuditEvent(
            timestamp="2024-01-15T10:30:00",
            event_type="deletion",
            path="/home/user/cache",
            size_bytes=1024,
            category="System",
            subcategory="Caches",
            success=False,
            dry_run=False,
            error="Permission denied",
        )
        json_str = event.to_json()
        data = json.loads(json_str)

        assert data["success"] is False
        assert data["error"] == "Permission denied"

    def test_to_json_with_details(self) -> None:
        """Test JSON serialization with details."""
        event = AuditEvent(
            timestamp="2024-01-15T10:30:00",
            event_type="scan",
            path="",
            size_bytes=5000,
            category="Module",
            subcategory="",
            success=True,
            dry_run=True,
            details={"items_found": 10, "duration_seconds": 1.5},
        )
        json_str = event.to_json()
        data = json.loads(json_str)

        assert data["details"]["items_found"] == 10
        assert data["details"]["duration_seconds"] == 1.5


class TestMacSweepLogger:
    """Tests for MacSweepLogger class."""

    def test_singleton(self) -> None:
        """Test that MacSweepLogger is a singleton."""
        # Reset the singleton for testing
        MacSweepLogger._instance = None
        MacSweepLogger._initialized = False

        logger1 = MacSweepLogger()
        logger2 = MacSweepLogger()
        assert logger1 is logger2

    def test_configure(self, temp_dir: Path) -> None:
        """Test configuring the logger."""
        # Reset singleton
        MacSweepLogger._instance = None
        MacSweepLogger._initialized = False

        logger = MacSweepLogger()
        config = LogConfig(log_dir=temp_dir, enable_file_logging=True)
        logger.configure(config)

        assert logger._setup_complete is True
        assert (temp_dir / "macsweep.log").parent.exists()

    def test_logging_methods(self, temp_dir: Path) -> None:
        """Test logging methods."""
        MacSweepLogger._instance = None
        MacSweepLogger._initialized = False

        logger = MacSweepLogger()
        config = LogConfig(
            log_dir=temp_dir,
            enable_file_logging=True,
            enable_console_logging=False,
            level=logging.DEBUG,
        )
        logger.configure(config)

        # These should not raise
        logger.debug("Debug message")
        logger.info("Info message")
        logger.warning("Warning message")
        logger.error("Error message")

        # Check that log file was created
        log_file = temp_dir / "macsweep.log"
        assert log_file.exists()

        content = log_file.read_text()
        assert "Debug message" in content
        assert "Info message" in content
        assert "Warning message" in content
        assert "Error message" in content


class TestAuditLogging:
    """Tests for audit logging functionality."""

    def test_audit_deletion(self, temp_dir: Path) -> None:
        """Test audit_deletion method."""
        MacSweepLogger._instance = None
        MacSweepLogger._initialized = False

        logger = MacSweepLogger()
        config = LogConfig(
            log_dir=temp_dir,
            enable_file_logging=True,
            enable_audit_log=True,
        )
        logger.configure(config)

        logger.audit_deletion(
            path=Path("/home/user/cache"),
            size_bytes=1024,
            category="System",
            subcategory="Caches",
            success=True,
            dry_run=False,
        )

        audit_file = temp_dir / "audit.log"
        assert audit_file.exists()

        content = audit_file.read_text().strip()
        data = json.loads(content)
        assert data["event_type"] == "deletion"
        assert data["path"] == "/home/user/cache"
        assert data["size_bytes"] == 1024
        assert data["success"] is True

    def test_audit_scan(self, temp_dir: Path) -> None:
        """Test audit_scan method."""
        MacSweepLogger._instance = None
        MacSweepLogger._initialized = False

        logger = MacSweepLogger()
        config = LogConfig(
            log_dir=temp_dir,
            enable_file_logging=True,
            enable_audit_log=True,
        )
        logger.configure(config)

        logger.audit_scan(
            module_name="System Caches",
            items_found=15,
            total_size=1024000,
            duration_seconds=2.5,
        )

        audit_file = temp_dir / "audit.log"
        content = audit_file.read_text().strip()
        data = json.loads(content)

        assert data["event_type"] == "scan"
        assert data["category"] == "System Caches"
        assert data["details"]["items_found"] == 15
        assert data["details"]["duration_seconds"] == 2.5

    def test_audit_clean_summary(self, temp_dir: Path) -> None:
        """Test audit_clean_summary method."""
        MacSweepLogger._instance = None
        MacSweepLogger._initialized = False

        logger = MacSweepLogger()
        config = LogConfig(
            log_dir=temp_dir,
            enable_file_logging=True,
            enable_audit_log=True,
        )
        logger.configure(config)

        logger.audit_clean_summary(
            items_cleaned=10,
            bytes_freed=5000000,
            duration_seconds=3.2,
            dry_run=False,
            errors=1,
        )

        audit_file = temp_dir / "audit.log"
        content = audit_file.read_text().strip()
        data = json.loads(content)

        assert data["event_type"] == "clean_summary"
        assert data["size_bytes"] == 5000000
        assert data["details"]["items_cleaned"] == 10
        assert data["details"]["errors"] == 1


class TestConfigureLogging:
    """Tests for configure_logging function."""

    def test_configure_logging_defaults(self, temp_dir: Path) -> None:
        """Test configure_logging with defaults."""
        MacSweepLogger._instance = None
        MacSweepLogger._initialized = False

        with patch(
            "macsweep.core.logging.DEFAULT_LOG_DIR", temp_dir
        ):
            logger = configure_logging()
            assert logger is not None
            assert logger._setup_complete is True

    def test_configure_logging_custom(self, temp_dir: Path) -> None:
        """Test configure_logging with custom options."""
        MacSweepLogger._instance = None
        MacSweepLogger._initialized = False

        logger = configure_logging(
            level=logging.DEBUG,
            log_dir=temp_dir,
            enable_file_logging=True,
            enable_console_logging=True,
            enable_audit_log=True,
        )

        assert logger._config.level == logging.DEBUG
        assert logger._config.log_dir == temp_dir
        assert logger._config.enable_console_logging is True


class TestGetLogger:
    """Tests for get_logger function."""

    def test_get_logger_returns_singleton(self) -> None:
        """Test that get_logger returns the singleton instance."""
        logger1 = get_logger()
        logger2 = get_logger()
        assert logger1 is logger2

    def test_get_logger_auto_configures(self, temp_dir: Path) -> None:
        """Test that get_logger auto-configures on first use."""
        MacSweepLogger._instance = None
        MacSweepLogger._initialized = False

        with patch(
            "macsweep.core.logging.DEFAULT_LOG_DIR", temp_dir
        ):
            logger = get_logger()
            # Access .logger property to trigger auto-configure
            _ = logger.logger
            assert logger._setup_complete is True
