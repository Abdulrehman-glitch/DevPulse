"""Non-secret settings persistence and in-memory migration."""

from __future__ import annotations

import json
import os
from contextlib import suppress
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from pydantic import ValidationError

from devpulse_core.models import ProjectConfig, Settings
from devpulse_core.paths import AppPaths
from devpulse_core.persistence import atomic_write_json, preserve_text_copy


class ConfigurationError(RuntimeError):
    """Raised when DevPulse settings cannot be read or validated."""

    def __init__(self, message: str, *, preserve_original: bool = False) -> None:
        super().__init__(message)
        self.preserve_original = preserve_original


class SettingsStore:
    def __init__(self, paths: AppPaths | None = None) -> None:
        self.paths = paths or AppPaths.resolve()
        self.last_error: str | None = None
        self.migrated_from: int | None = None
        self.downgrade_blocked = False
        self.migration_blocked = False

    def load(self) -> Settings:
        self.last_error = None
        self.migrated_from = None
        self.downgrade_blocked = False
        self.migration_blocked = False
        self.paths.ensure()
        if not self.paths.settings.exists():
            settings = self._first_run_settings()
            self.save(settings)
            return settings
        try:
            raw = json.loads(self.paths.settings.read_text(encoding="utf-8"))
            source_version = _configuration_version(raw)
            if source_version > 5:
                raise ConfigurationError(
                    f"This DevPulse build cannot read configuration schema {source_version}.",
                    preserve_original=True,
                )
            settings = Settings.model_validate(_migrate_configuration(raw))
            if source_version < 5:
                self._backup_before_migration(raw, source_version)
                self.migrated_from = source_version
                try:
                    self.save(settings)
                except OSError:
                    # The validated source remains authoritative on disk and migration
                    # will be retried on the next launch. The in-memory value is safe.
                    self.last_error = "Configuration migration could not be committed."
                    self.migration_blocked = True
                    self.migrated_from = None
                    return self._resolve_paths(settings)
        except (OSError, json.JSONDecodeError, ValidationError, ConfigurationError) as exc:
            self.last_error = _safe_configuration_error(exc)
            if isinstance(exc, ConfigurationError) and exc.preserve_original:
                self.downgrade_blocked = "cannot read configuration schema" in str(exc)
                self.migration_blocked = True
                self._preserve_unsupported_settings()
                # Never overwrite newer, invalid-version, or unknown-field state.
                return self._resolve_paths(Settings())
            settings = self._recover(exc)
        return self._resolve_paths(settings)

    def save(self, settings: Settings, *, _replace_invalid: bool = False) -> Settings:
        if self.migration_blocked:
            raise ConfigurationError(
                "Configuration writes are blocked until the unsupported source is resolved."
            )
        self.paths.ensure()
        payload = settings.model_dump(mode="json", exclude={"projects": {"__all__": {"commands"}}})
        if self.paths.settings.exists():
            try:
                self._read(self.paths.settings)
                raw = json.loads(self.paths.settings.read_text(encoding="utf-8"))
                atomic_write_json(self.paths.settings_backup, raw)
            except ConfigurationError:
                raise
            except (json.JSONDecodeError, ValidationError) as exc:
                if not _replace_invalid:
                    raise ConfigurationError(
                        "Configuration writes require a validated current source.",
                        preserve_original=True,
                    ) from exc
            except OSError:
                raise
        atomic_write_json(self.paths.settings, payload)
        return settings

    def _backup_before_migration(self, raw: Any, source_version: int) -> None:
        """Keep a forensic copy before the first alpha.2 -> alpha.3 write."""
        destination = self.paths.data / f"settings.pre-migration-v{source_version}.json"
        if destination.exists():
            return
        atomic_write_json(destination, raw)

    def _read(self, path: Path) -> Settings:
        raw: Any = json.loads(path.read_text(encoding="utf-8"))
        return Settings.model_validate(_migrate_configuration(raw))

    def _recover(self, original: Exception) -> Settings:
        if self.paths.settings_backup.exists():
            try:
                recovered = self._read(self.paths.settings_backup)
                self._preserve_corrupt_settings()
                self.save(recovered, _replace_invalid=True)
                return recovered
            except (OSError, json.JSONDecodeError, ValidationError, ConfigurationError):
                pass
        self._preserve_corrupt_settings()
        defaults = Settings()
        self.save(defaults, _replace_invalid=True)
        return defaults

    def _preserve_corrupt_settings(self) -> None:
        if not self.paths.settings.exists():
            return
        stamp = datetime.now(UTC).strftime("%Y%m%d-%H%M%S")
        destination = self.paths.data / f"settings.corrupt-{stamp}.json"
        with suppress(OSError):
            preserve_text_copy(self.paths.settings, destination)

    def _preserve_unsupported_settings(self) -> None:
        if not self.paths.settings.exists():
            return
        stamp = datetime.now(UTC).strftime("%Y%m%d-%H%M%S")
        destination = self.paths.data / f"settings.unsupported-{stamp}.json"
        with suppress(OSError):
            preserve_text_copy(self.paths.settings, destination)

    def _first_run_settings(self) -> Settings:
        # Development can opt into scanning only this repository. Production defaults empty.
        development_project = os.getenv("DEVPULSE_DEV_PROJECT_DIR")
        if development_project:
            path = Path(development_project).resolve()
            return Settings(projects=[ProjectConfig(name=path.name or "DevPulse", path=path)])
        return Settings()

    def _resolve_paths(self, settings: Settings) -> Settings:
        base = self.paths.data
        projects = [
            item.model_copy(update={"path": _resolve_path(item.path, base)})
            for item in settings.projects
        ]
        roots = [
            item.model_copy(update={"path": _resolve_path(item.path, base)})
            for item in settings.scan_roots
        ]
        return settings.model_copy(update={"projects": projects, "scan_roots": roots})


def _migrate_configuration(raw: Any) -> Any:
    """Migrate supported terminal and prerelease data into schema 5."""
    if not isinstance(raw, dict):
        return raw
    migrated = dict(raw)
    source_version = _configuration_version(raw)
    if source_version > 5:
        raise ConfigurationError(
            f"Unsupported configuration schema {source_version}.", preserve_original=True
        )
    aliases = {
        "recursive_scan_roots": "scan_roots",
        "max_scan_depth": "maximum_scan_depth",
        "cache_duration": "cache_duration_seconds",
        "refresh_interval": "refresh_interval_seconds",
        "max_commits": "maximum_commits_displayed",
    }
    for old, new in aliases.items():
        if old in migrated and new not in migrated:
            migrated[new] = migrated.pop(old)
    if "start_on_login" in migrated and "start_minimized" not in migrated:
        migrated["start_minimized"] = False
        migrated.pop("start_on_login", None)
    roots = migrated.get("scan_roots", [])
    if isinstance(roots, list):
        migrated["scan_roots"] = [
            {"path": item, "recursive": True} if isinstance(item, str) else item for item in roots
        ]
    project_fields = {"name", "path", "favorite", "tags", "notes", "archived", "commands"}
    projects = migrated.get("projects", [])
    if isinstance(projects, list):
        migrated_projects: list[Any] = []
        for item in projects:
            if not isinstance(item, dict):
                migrated_projects.append(item)
                continue
            unknown_project_fields = set(item) - project_fields
            if unknown_project_fields:
                raise ConfigurationError(
                    "Configuration contains unsupported project fields.",
                    preserve_original=True,
                )
            migrated_projects.append(
                {key: value for key, value in item.items() if key in project_fields}
            )
        migrated["projects"] = migrated_projects
    known = {
        "schema_version",
        "onboarding_completed",
        "projects",
        "scan_roots",
        "maximum_scan_depth",
        "maximum_repositories_per_root",
        "maximum_directories_per_scan",
        "maximum_entries_per_scan",
        "scan_timeout_seconds",
        "repository_scan_timeout_seconds",
        "maximum_changed_paths",
        "ignored_directories",
        "cache_duration_seconds",
        "refresh_interval_seconds",
        "maximum_commits_displayed",
        "appearance",
        "start_minimized",
        "reduced_motion",
        "confirm_before_removing_project",
        "log_level",
        "default_landing_page",
        "date_time_display",
        "table_density",
        "stale_project_days",
        "default_sort",
        "notification_preferences",
        "notification_severity_threshold",
        "notification_history_length",
        "saved_views",
        "active_saved_view",
    }
    unknown = set(migrated) - known - set(aliases)
    if unknown:
        raise ConfigurationError(
            "Configuration contains unsupported fields.",
            preserve_original=True,
        )
    migrated["schema_version"] = 5
    return {key: value for key, value in migrated.items() if key in known}


def _configuration_version(raw: Any) -> int:
    if not isinstance(raw, dict):
        raise ConfigurationError(
            "Configuration must contain a JSON object.", preserve_original=True
        )
    value = raw.get("schema_version", 2)
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise ConfigurationError("Configuration schema version is invalid.", preserve_original=True)
    return value


def _resolve_path(path: Path, base: Path) -> Path:
    return path if path.is_absolute() else (base / path).resolve()


def _safe_configuration_error(error: Exception) -> str:
    if isinstance(error, json.JSONDecodeError):
        return "Configuration contains malformed JSON."
    if isinstance(error, ValidationError):
        return "Configuration contains invalid values."
    if isinstance(error, OSError):
        return "Configuration storage could not be accessed."
    return str(error)
