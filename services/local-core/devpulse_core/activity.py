"""Isolated, bounded persistence for DevPulse's own local activity history."""

from __future__ import annotations

import json
import threading
from pathlib import Path

from devpulse_core.models import ActivityEvent


class ActivityStore:
    def __init__(self, path: Path, maximum_events: int = 1_000) -> None:
        self.path = path
        self.maximum_events = maximum_events
        self._lock = threading.Lock()

    def load(self) -> list[ActivityEvent]:
        with self._lock:
            try:
                payload = json.loads(self.path.read_text(encoding="utf-8"))
                if payload.get("version") != 1:
                    return []
                return [ActivityEvent.model_validate(item) for item in payload["events"]][
                    -self.maximum_events :
                ]
            except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
                return []

    def save(self, events: list[ActivityEvent]) -> None:
        with self._lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            payload = {
                "version": 1,
                "events": [item.model_dump(mode="json") for item in events[-self.maximum_events :]],
            }
            temporary = self.path.with_suffix(".tmp")
            temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
            temporary.replace(self.path)

    def clear(self) -> None:
        self.save([])
