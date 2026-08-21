"""Safe, redacted diagnostics assembled only from DevPulse-owned state."""

from __future__ import annotations

import json
import platform
import re
from collections.abc import Iterable
from pathlib import Path
from typing import Any

from devpulse_core import __version__

_SECRET = re.compile(
    r"(?i)(authorization|token|password|secret|credential)(\s*[:=]\s*)([^\s,;\"}]+)"
)
_URL = re.compile(r"(?i)\b(?:https?|ssh|git)://[^\s\"']+")
_WINDOWS_PATH = re.compile(r"(?i)\b[A-Z]:\\[^\r\n\"']+")
_LONG_HEX = re.compile(r"\b[0-9a-fA-F]{24,}\b")


def redact_text(value: str) -> str:
    value = _SECRET.sub(r"\1\2<redacted>", value)
    value = _URL.sub("<remote-url>", value)
    value = _WINDOWS_PATH.sub("<local-path>", value)
    return _LONG_HEX.sub("<redacted-id>", value)


def safe_log_excerpt(log_path: Path, limit: int = 12) -> list[str]:
    """Summarise local log records without exporting their free-form messages."""
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()[-limit:]
    except OSError:
        return []
    result: list[str] = []
    for line in lines:
        try:
            payload = json.loads(line)
            level = str(payload.get("level", "INFO")).upper()
        except (json.JSONDecodeError, TypeError):
            level = "UNKNOWN"
        if level not in {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}:
            level = "UNKNOWN"
        result.append(f"{level}: local diagnostic entry")
    return result


def build_safe_diagnostics(
    *,
    qa_mode: bool,
    data_root: Path,
    schema_version: int,
    project_count: int,
    cache_status: str,
    last_scan_status: str,
    recent_error_codes: Iterable[str],
    startup_duration_ms: int,
    log_path: Path,
) -> dict[str, Any]:
    root_label = "DevPulse QA data" if qa_mode else "DevPulse application data"
    return {
        "devpulse_version": __version__,
        "operating_system": f"{platform.system()} {platform.release()}",
        "qa_mode": qa_mode,
        "local_core_status": "connected",
        "sidecar_status": "running",
        "startup_duration_ms": max(0, startup_duration_ms),
        "last_scan_status": last_scan_status,
        "registered_projects": project_count,
        "cache_status": cache_status,
        "configuration_schema_version": schema_version,
        "data_boundary": root_label,
        "recent_error_codes": [redact_text(item) for item in recent_error_codes][-10:],
        "log_excerpt": safe_log_excerpt(log_path),
    }


def export_safe_diagnostics(payload: dict[str, Any]) -> str:
    return json.dumps(payload, indent=2, sort_keys=True) + "\n"
