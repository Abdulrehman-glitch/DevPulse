"""Per-user runtime paths with explicit overrides for development and tests."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from platformdirs import user_data_path


@dataclass(frozen=True)
class AppPaths:
    data: Path
    settings: Path
    settings_backup: Path
    cache: Path
    logs: Path
    activity: Path
    backups: Path
    test_lab: Path

    @classmethod
    def resolve(cls, override: Path | None = None) -> AppPaths:
        """Resolve normal production/development paths without changing existing behaviour."""
        configured = override or (
            Path(value).expanduser() if (value := os.getenv("DEVPULSE_DATA_DIR")) else None
        )
        data = (configured or user_data_path("DevPulse", "DevPulse", roaming=True)).resolve()
        return cls._from_data(data)

    @classmethod
    def resolve_qa(cls, override: Path | None, expected_root: Path | None = None) -> AppPaths:
        """Resolve an explicit QA root and refuse every fallback or boundary escape."""
        if override is None:
            raise ValueError("QA mode requires an explicit data directory")
        data = cls.validate_qa_root(override)
        if expected_root is None:
            raise ValueError("QA mode requires DEVPULSE_QA_ROOT")
        environment_root = cls.validate_qa_root(expected_root)
        if data != environment_root:
            raise ValueError("QA data directory does not match DEVPULSE_QA_ROOT")
        return cls._from_data(data)

    @staticmethod
    def validate_qa_root(candidate: Path) -> Path:
        raw = Path(candidate)
        if not raw.is_absolute():
            raise ValueError("QA data root must be a non-empty absolute path")
        if ".." in raw.parts:
            raise ValueError("QA data root cannot contain parent traversal")
        if raw.parent == raw:
            raise ValueError("QA data root cannot be a filesystem root")
        if raw.name != ".qa-runtime" and not raw.name.startswith("DevPulse-QA"):
            raise ValueError("QA data root must have a dedicated DevPulse QA name")

        # Check every existing component before resolve(), because resolve() would hide
        # the symbolic-link or Windows-junction boundary that must be refused.
        for component in [*reversed(raw.parents), raw]:
            is_junction = getattr(component, "is_junction", lambda: False)
            if component.is_symlink() or is_junction():
                raise ValueError("QA data root cannot cross a symbolic link or junction")
        resolved = raw.resolve()
        if resolved.parent == resolved:
            raise ValueError("QA data root cannot be a filesystem root")
        if (resolved / ".git").exists():
            raise ValueError("QA data root cannot be source controlled")
        return resolved

    @classmethod
    def _from_data(cls, data: Path) -> AppPaths:
        return cls(
            data=data,
            settings=data / "settings.json",
            settings_backup=data / "settings.last-known-good.json",
            cache=data / "cache",
            logs=data / "logs",
            activity=data / "activity" / "events-v1.json",
            backups=data / "backups",
            test_lab=data / "test-lab",
        )

    def ensure(self) -> None:
        self.data.mkdir(parents=True, exist_ok=True)
        self.cache.mkdir(parents=True, exist_ok=True)
        self.logs.mkdir(parents=True, exist_ok=True)
        self.activity.parent.mkdir(parents=True, exist_ok=True)
        self.backups.mkdir(parents=True, exist_ok=True)
