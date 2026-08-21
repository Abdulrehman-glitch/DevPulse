"""Isolated, bounded persistence for DevPulse's own local activity history."""

from __future__ import annotations

import json
import threading
from contextlib import suppress
from datetime import UTC, datetime
from pathlib import Path

from devpulse_core.models import ActivityEvent
from devpulse_core.persistence import atomic_write_json, preserve_text_copy


class ActivityStore:
    def __init__(self, path: Path, maximum_events: int = 1_000) -> None:
        self.path = path
        self.maximum_events = maximum_events
        self._lock = threading.Lock()
        self.write_blocked = False

    def load(self) -> list[ActivityEvent]:
        with self._lock:
            self.write_blocked = False
            try:
                payload = json.loads(self.path.read_text(encoding="utf-8"))
                version = payload.get("version")
                if isinstance(version, int) and version > 1:
                    self.write_blocked = True
                    self._preserve("unsupported")
                    return []
                if version != 1:
                    raise ValueError("unsupported activity schema")
                return [ActivityEvent.model_validate(item) for item in payload["events"]][
                    -self.maximum_events :
                ]
            except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
                self._preserve("corrupt")
                return []

    def save(self, events: list[ActivityEvent]) -> bool:
        with self._lock:
            if self.write_blocked:
                return False
            self.path.parent.mkdir(parents=True, exist_ok=True)
            payload = {
                "version": 1,
                "events": [item.model_dump(mode="json") for item in events[-self.maximum_events :]],
            }
            atomic_write_json(self.path, payload)
            return True

    def clear(self) -> None:
        self.write_blocked = False
        self.save([])

    def _preserve(self, disposition: str) -> None:
        if not self.path.exists():
            return
        stamp = datetime.now(UTC).strftime("%Y%m%d-%H%M%S-%f")
        destination = self.path.with_name(f"{self.path.stem}.{disposition}-{stamp}.json")
        with suppress(OSError):
            preserve_text_copy(self.path, destination)
