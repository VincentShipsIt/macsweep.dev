"""Size formatting utilities."""

import re


def format_size(size_bytes: int) -> str:
    """Format bytes into human-readable string."""
    if size_bytes < 1024:
        return f"{size_bytes} B"
    elif size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f} KB"
    elif size_bytes < 1024 * 1024 * 1024:
        return f"{size_bytes / (1024 * 1024):.1f} MB"
    else:
        return f"{size_bytes / (1024 * 1024 * 1024):.2f} GB"


def parse_size(size_str: str) -> int:
    """Parse human-readable size string to bytes.

    Examples:
        "100MB" -> 104857600
        "1.5GB" -> 1610612736
        "500KB" -> 512000
    """
    size_str = size_str.strip().upper()

    match = re.match(r"^([\d.]+)\s*(B|KB|MB|GB|TB)?$", size_str)
    if not match:
        raise ValueError(f"Invalid size format: {size_str}")

    value = float(match.group(1))
    unit = match.group(2) or "B"

    multipliers = {
        "B": 1,
        "KB": 1024,
        "MB": 1024 * 1024,
        "GB": 1024 * 1024 * 1024,
        "TB": 1024 * 1024 * 1024 * 1024,
    }

    return int(value * multipliers[unit])
