"""Structured rotating logs that redact secret-shaped values."""

from __future__ import annotations

import json
import logging
import re
from datetime import UTC, datetime
from logging.handlers import RotatingFileHandler
from pathlib import Path

_SECRET_PATTERN = re.compile(
    r"(?i)(authorization|password|passwd|secret|token|api[_-]?key)\s*[:=]\s*([^\s,;]+)"
)


class RedactingJsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        message = _SECRET_PATTERN.sub(r"\1=[REDACTED]", record.getMessage())
        payload: dict[str, object] = {
            "timestamp": datetime.now(UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": message,
        }
        if record.exc_info:
            payload["exception"] = _SECRET_PATTERN.sub(
                r"\1=[REDACTED]", self.formatException(record.exc_info)
            )
        return json.dumps(payload, ensure_ascii=False)


def configure_logging(directory: Path, level: str = "INFO") -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    log_path = directory / "local-core.log"
    root = logging.getLogger()
    root.setLevel(getattr(logging, level.upper(), logging.INFO))
    for handler in list(root.handlers):
        if getattr(handler, "_devpulse_handler", False):
            root.removeHandler(handler)
            handler.close()
    handler = RotatingFileHandler(log_path, maxBytes=2_000_000, backupCount=3, encoding="utf-8")
    handler.setFormatter(RedactingJsonFormatter())
    handler._devpulse_handler = True  # type: ignore[attr-defined]
    root.addHandler(handler)
    return log_path
