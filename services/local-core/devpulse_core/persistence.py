"""Durable, replace-safe writes for DevPulse-owned local state."""

from __future__ import annotations

import json
import os
from contextlib import suppress
from pathlib import Path
from typing import Any
from uuid import uuid4


def atomic_write_text(path: Path, content: str) -> None:
    """Write *content* without exposing a partially-written destination.

    The temporary file lives beside the destination so the final ``os.replace``
    stays on the same filesystem. A failed write leaves the previous destination
    untouched and removes only the temporary file owned by this operation.
    """

    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid4().hex}.tmp")
    try:
        with temporary.open("x", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except BaseException:
        with suppress(OSError):
            temporary.unlink(missing_ok=True)
        raise


def atomic_write_json(path: Path, payload: Any) -> None:
    atomic_write_text(path, json.dumps(payload, indent=2, ensure_ascii=False) + "\n")


def preserve_text_copy(source: Path, destination: Path) -> None:
    """Create a replace-safe forensic copy without mutating *source*."""

    atomic_write_text(destination, source.read_text(encoding="utf-8", errors="replace"))
