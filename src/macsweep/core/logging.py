"""Logging configuration for MacSweep."""

import json
import logging
import sys
from dataclasses import asdict, dataclass, field
from datetime import datetime
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import Any

# Default log directory
DEFAULT_LOG_DIR = Path.home() / ".macsweep" / "logs"

# Log format for file output
FILE_FORMAT = "%(asctime)s | %(levelname)-8s | %(name)s | %(message)s"
DATE_FORMAT = "%Y-%m-%d %H:%M:%S"

# Structured format for audit logs (JSON)
AUDIT_LOG_NAME = "audit.log"
APP_LOG_NAME = "macsweep.log"


@dataclass
class LogConfig:
    """Logging configuration."""

    level: int = logging.INFO
    log_dir: Path = field(default_factory=lambda: DEFAULT_LOG_DIR)
    enable_file_logging: bool = True
    enable_console_logging: bool = False
    max_file_size_mb: int = 10
    backup_count: int = 5
    enable_audit_log: bool = True

    def __post_init__(self) -> None:
        if isinstance(self.log_dir, str):
            self.log_dir = Path(self.log_dir)


@dataclass
class AuditEvent:
    """Represents an auditable event."""

    timestamp: str
    event_type: str
    path: str
    size_bytes: int
    category: str
    subcategory: str
    success: bool
    dry_run: bool
    error: str | None = None
    details: dict[str, Any] = field(default_factory=dict)

    def to_json(self) -> str:
        """Convert to JSON string."""
        return json.dumps(asdict(self), ensure_ascii=False)


class MacSweepLogger:
    """Central logging manager for MacSweep."""

    _instance: "MacSweepLogger | None" = None
    _initialized: bool = False

    def __new__(cls) -> "MacSweepLogger":
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def __init__(self) -> None:
        if MacSweepLogger._initialized:
            return
        MacSweepLogger._initialized = True

        self._config = LogConfig()
        self._logger = logging.getLogger("macsweep")
        self._audit_logger = logging.getLogger("macsweep.audit")
        self._setup_complete = False

    def configure(self, config: LogConfig | None = None) -> None:
        """Configure logging with the given settings."""
        if config:
            self._config = config

        self._setup_loggers()
        self._setup_complete = True

    def _setup_loggers(self) -> None:
        """Set up all loggers."""
        # Main application logger
        self._logger.setLevel(self._config.level)
        self._logger.handlers.clear()

        # Console handler (optional, disabled by default for CLI apps)
        if self._config.enable_console_logging:
            console_handler = logging.StreamHandler(sys.stderr)
            console_handler.setLevel(self._config.level)
            console_handler.setFormatter(logging.Formatter("%(levelname)s: %(message)s"))
            self._logger.addHandler(console_handler)

        # File handler
        if self._config.enable_file_logging:
            self._ensure_log_dir()
            file_handler = RotatingFileHandler(
                self._config.log_dir / APP_LOG_NAME,
                maxBytes=self._config.max_file_size_mb * 1024 * 1024,
                backupCount=self._config.backup_count,
                encoding="utf-8",
            )
            file_handler.setLevel(self._config.level)
            file_handler.setFormatter(logging.Formatter(FILE_FORMAT, datefmt=DATE_FORMAT))
            self._logger.addHandler(file_handler)

        # Audit logger (separate file, JSON format)
        if self._config.enable_audit_log:
            self._audit_logger.setLevel(logging.INFO)
            self._audit_logger.handlers.clear()
            self._audit_logger.propagate = False

            self._ensure_log_dir()
            audit_handler = RotatingFileHandler(
                self._config.log_dir / AUDIT_LOG_NAME,
                maxBytes=self._config.max_file_size_mb * 1024 * 1024,
                backupCount=self._config.backup_count,
                encoding="utf-8",
            )
            audit_handler.setLevel(logging.INFO)
            # No formatter - we'll write JSON directly
            audit_handler.setFormatter(logging.Formatter("%(message)s"))
            self._audit_logger.addHandler(audit_handler)

    def _ensure_log_dir(self) -> None:
        """Ensure log directory exists."""
        self._config.log_dir.mkdir(parents=True, exist_ok=True)

    @property
    def logger(self) -> logging.Logger:
        """Get the main application logger."""
        if not self._setup_complete:
            self.configure()
        return self._logger

    def debug(self, msg: str, *args: Any, **kwargs: Any) -> None:
        """Log debug message."""
        self.logger.debug(msg, *args, **kwargs)

    def info(self, msg: str, *args: Any, **kwargs: Any) -> None:
        """Log info message."""
        self.logger.info(msg, *args, **kwargs)

    def warning(self, msg: str, *args: Any, **kwargs: Any) -> None:
        """Log warning message."""
        self.logger.warning(msg, *args, **kwargs)

    def error(self, msg: str, *args: Any, **kwargs: Any) -> None:
        """Log error message."""
        self.logger.error(msg, *args, **kwargs)

    def exception(self, msg: str, *args: Any, **kwargs: Any) -> None:
        """Log exception with traceback."""
        self.logger.exception(msg, *args, **kwargs)

    def audit(self, event: AuditEvent) -> None:
        """Log an audit event."""
        if not self._setup_complete:
            self.configure()
        if self._config.enable_audit_log:
            self._audit_logger.info(event.to_json())

    def audit_deletion(
        self,
        path: Path,
        size_bytes: int,
        category: str,
        subcategory: str,
        success: bool,
        dry_run: bool,
        error: str | None = None,
    ) -> None:
        """Log a file/directory deletion event."""
        event = AuditEvent(
            timestamp=datetime.now().isoformat(),
            event_type="deletion",
            path=str(path),
            size_bytes=size_bytes,
            category=category,
            subcategory=subcategory,
            success=success,
            dry_run=dry_run,
            error=error,
        )
        self.audit(event)

    def audit_scan(
        self,
        module_name: str,
        items_found: int,
        total_size: int,
        duration_seconds: float,
    ) -> None:
        """Log a scan completion event."""
        event = AuditEvent(
            timestamp=datetime.now().isoformat(),
            event_type="scan",
            path="",
            size_bytes=total_size,
            category=module_name,
            subcategory="",
            success=True,
            dry_run=True,
            details={
                "items_found": items_found,
                "duration_seconds": round(duration_seconds, 2),
            },
        )
        self.audit(event)

    def audit_clean_summary(
        self,
        items_cleaned: int,
        bytes_freed: int,
        duration_seconds: float,
        dry_run: bool,
        errors: int = 0,
    ) -> None:
        """Log a cleanup summary event."""
        event = AuditEvent(
            timestamp=datetime.now().isoformat(),
            event_type="clean_summary",
            path="",
            size_bytes=bytes_freed,
            category="summary",
            subcategory="",
            success=errors == 0,
            dry_run=dry_run,
            details={
                "items_cleaned": items_cleaned,
                "duration_seconds": round(duration_seconds, 2),
                "errors": errors,
            },
        )
        self.audit(event)


# Global logger instance
_logger = MacSweepLogger()


def get_logger() -> MacSweepLogger:
    """Get the global MacSweep logger instance."""
    return _logger


def configure_logging(
    level: int = logging.INFO,
    log_dir: Path | str | None = None,
    enable_file_logging: bool = True,
    enable_console_logging: bool = False,
    enable_audit_log: bool = True,
) -> MacSweepLogger:
    """Configure the global logger.

    Args:
        level: Logging level (default: INFO)
        log_dir: Directory for log files (default: ~/.macsweep/logs)
        enable_file_logging: Enable logging to files (default: True)
        enable_console_logging: Enable console output (default: False)
        enable_audit_log: Enable audit logging (default: True)

    Returns:
        Configured MacSweepLogger instance
    """
    config = LogConfig(
        level=level,
        log_dir=Path(log_dir) if log_dir else DEFAULT_LOG_DIR,
        enable_file_logging=enable_file_logging,
        enable_console_logging=enable_console_logging,
        enable_audit_log=enable_audit_log,
    )
    _logger.configure(config)
    return _logger
