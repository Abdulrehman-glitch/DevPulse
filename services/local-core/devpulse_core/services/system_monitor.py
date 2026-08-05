"""Safe system utilisation monitoring."""

from __future__ import annotations

import logging
import os
import time
from collections.abc import Callable
from pathlib import Path

import psutil

from devpulse_core.models import DiskVolume, SystemSnapshot

logger = logging.getLogger(__name__)


class SystemMonitor:
    def __init__(self, disk_path: Path | None = None, *, app_data: Path | None = None) -> None:
        default_disk = (
            Path(os.environ.get("SYSTEMDRIVE", "C:") + "\\") if os.name == "nt" else Path("/")
        )
        self.disk_path = disk_path or default_disk
        self.app_data = app_data
        self.started = time.monotonic()

    def snapshot(self) -> SystemSnapshot:
        memory = self._read_memory()
        volumes = self._read_volumes()
        return SystemSnapshot(
            cpu_percent=self._read_percentage("CPU", lambda: psutil.cpu_percent(interval=None)),
            logical_processors=psutil.cpu_count(logical=True),
            memory_percent=float(memory.percent) if memory is not None else None,
            memory_available_bytes=(
                int(memory.available)
                if memory is not None and hasattr(memory, "available")
                else None
            ),
            disk_percent=self._read_percentage(
                "disk", lambda: psutil.disk_usage(str(self.disk_path)).percent
            ),
            volumes=volumes,
            process_uptime_seconds=int(time.monotonic() - self.started),
            application_data_location=str(self.app_data or ""),
            log_directory_location=str((self.app_data / "logs") if self.app_data else ""),
        )

    @staticmethod
    def _read_memory() -> object | None:
        try:
            return psutil.virtual_memory()
        except (OSError, RuntimeError, ValueError, psutil.Error) as exc:
            logger.warning("System memory information unavailable: %s", exc)
            return None

    @staticmethod
    def _read_volumes() -> list[DiskVolume]:
        volumes: list[DiskVolume] = []
        try:
            partitions = psutil.disk_partitions(all=False)
        except (OSError, RuntimeError, ValueError, psutil.Error):
            return volumes
        for partition in partitions:
            try:
                usage = psutil.disk_usage(partition.mountpoint)
                volumes.append(
                    DiskVolume(
                        mount=partition.mountpoint,
                        usage_percent=float(usage.percent),
                        free_bytes=int(usage.free),
                    )
                )
            except (AttributeError, OSError, RuntimeError, ValueError, psutil.Error):
                continue
        return volumes

    @staticmethod
    def _read_percentage(label: str, reader: Callable[[], float | int]) -> float | None:
        try:
            return max(0.0, min(100.0, float(reader())))
        except (OSError, RuntimeError, ValueError, psutil.Error) as exc:
            logger.warning("System %s information unavailable: %s", label, exc)
            return None
