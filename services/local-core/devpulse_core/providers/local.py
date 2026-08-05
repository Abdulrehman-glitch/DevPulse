"""Local provider coordinating discovery, scans, cache, settings and activity."""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import threading
from collections import deque
from datetime import UTC, datetime
from pathlib import Path
from uuid import uuid4

from devpulse_core.activity import ActivityStore
from devpulse_core.config import SettingsStore
from devpulse_core.diagnostics import build_safe_diagnostics, export_safe_diagnostics
from devpulse_core.models import (
    ActivityEvent,
    ProjectConfig,
    RepositoryInfo,
    ScanRootConfig,
    Settings,
    SystemHistoryPoint,
    SystemSnapshot,
)
from devpulse_core.services import ProjectDiscovery, RepositoryScanner, SystemMonitor
from devpulse_core.services.path_safety import validate_selected_path
from devpulse_core.test_lab import generate_test_lab, qa_settings, reset_test_lab

logger = logging.getLogger(__name__)


def project_id(path: Path) -> str:
    normalised = os.path.normcase(os.path.abspath(path)).encode("utf-8")
    return hashlib.sha256(normalised).hexdigest()[:16]


class LocalDataProvider:
    def __init__(self, store: SettingsStore | None = None, *, qa_mode: bool = False) -> None:
        self.store = store or SettingsStore()
        self.qa_mode = qa_mode
        self._operation_lock = threading.RLock()
        self._shutdown_requested = threading.Event()
        self._settings = self.store.load()
        if self.qa_mode:
            self._settings = self._generate_qa_settings()
        self._monitor = SystemMonitor(app_data=self.store.paths.data)
        self._scanner = self._make_scanner()
        self._repositories: list[RepositoryInfo] = []
        self._activity_store = ActivityStore(self.store.paths.activity)
        self._activity: list[ActivityEvent] = self._activity_store.load()
        self._last_refresh: datetime | None = None
        self._refreshing = False
        self._lock = threading.RLock()
        self._history: deque[SystemHistoryPoint] = deque(maxlen=240)
        self._load_cache()
        self._record("success", "core_started", "Local core started")
        if self.store.last_error:
            self._record(
                "warning",
                "recovery_performed",
                "DevPulse recovered its configuration; review Settings and Activity.",
            )
        if self.store.migrated_from is not None:
            self._record(
                "success",
                "configuration_migrated",
                f"Configuration migrated from schema {self.store.migrated_from} to schema 4.",
            )
        if self.qa_mode:
            self._record("info", "qa_mode_started", "QA mode started with artificial data")

    @property
    def last_refresh(self) -> datetime | None:
        with self._lock:
            return self._last_refresh

    @property
    def refreshing(self) -> bool:
        with self._lock:
            return self._refreshing

    def system_snapshot(self) -> SystemSnapshot:
        snapshot = self._monitor.snapshot()
        result = snapshot.model_copy(
            update={
                "scan_worker_status": "scanning" if self.refreshing else "idle",
                "cache_status": "ready" if self._cache_path.exists() else "empty",
            }
        )
        with self._lock:
            self._history.append(
                SystemHistoryPoint(
                    timestamp=datetime.now(UTC),
                    cpu_percent=result.cpu_percent,
                    memory_percent=result.memory_percent,
                    warning_count=sum(len(item.warnings) for item in self._repositories),
                )
            )
        return result

    def system_history(self) -> list[SystemHistoryPoint]:
        with self._lock:
            return list(self._history)

    def projects(self) -> list[RepositoryInfo]:
        with self._lock:
            return list(self._repositories)

    def project(self, identifier: str) -> RepositoryInfo | None:
        return next(
            (item for item in self.projects() if project_id(item.project.path) == identifier), None
        )

    def registered_project_path(self, identifier: str) -> Path:
        """Resolve a currently registered repository again at the moment it is opened."""
        with self._operation_lock:
            selected = next(
                (item for item in self._settings.projects if project_id(item.path) == identifier),
                None,
            )
            if selected is None:
                raise KeyError("Project not found")
            canonical = validate_selected_path(
                selected.path,
                app_data=self.store.paths.data,
                require_git=True,
                allowed_app_data_subtree=self.store.paths.test_lab if self.qa_mode else None,
            )
            if project_id(canonical) != identifier:
                raise ValueError("The registered project path no longer resolves safely.")
            return canonical

    def refresh(self, *, force: bool = True) -> list[RepositoryInfo]:
        with self._operation_lock:
            return self._refresh_serialized(force=force)

    def _refresh_serialized(self, *, force: bool) -> list[RepositoryInfo]:
        with self._lock:
            if self._refreshing:
                return list(self._repositories)
            self._refreshing = True
        self._record("info", "scan_started", "Repository scan started")
        try:
            projects = ProjectDiscovery(self._settings).discover()
            repositories = self._scanner.scan_all(
                projects,
                force=force,
                cancel_event=self._shutdown_requested,
            )
            now = datetime.now(UTC)
            with self._lock:
                self._repositories = repositories
                self._last_refresh = now
                duration = sum(item.last_scan_duration_ms for item in repositories)
                self._history.append(
                    SystemHistoryPoint(
                        timestamp=now,
                        scan_duration_ms=duration,
                        refresh_succeeded=True,
                        warning_count=sum(len(item.warnings) for item in repositories),
                    )
                )
            self._write_cache()
            self._record(
                "success",
                "scan_completed",
                f"Repository scan completed ({len(repositories)} registered)",
            )
            for repository in repositories:
                if repository.error:
                    self._record(
                        "warning",
                        "scan_failed",
                        f"{repository.project.name}: {repository.warnings[0]}",
                        project_id(repository.project.path),
                    )
            return list(repositories)
        except Exception:
            logger.exception("Repository refresh failed")
            self._record(
                "error",
                "scan_failed",
                "Repository scan failed; review local diagnostics",
            )
            raise
        finally:
            with self._lock:
                self._refreshing = False

    def request_shutdown(self) -> None:
        """Cancel an in-flight refresh before the transport exits."""
        self._shutdown_requested.set()

    def activity(self, limit: int = 30) -> list[ActivityEvent]:
        with self._lock:
            return list(reversed(self._activity[-max(1, min(limit, 200)) :]))

    def clear_activity(self) -> None:
        with self._lock:
            self._activity = []
        self._activity_store.clear()

    def record_lifecycle_event(self, event_type: str) -> None:
        messages = {
            "application_started": ("info", "DevPulse application started"),
            "core_connected": ("success", "Desktop connected to local core"),
            "core_restarted": ("warning", "Local core restarted"),
            "shutdown_requested": ("info", "Application shutdown requested"),
        }
        if event_type not in messages:
            raise ValueError("Unsupported lifecycle event")
        kind, message = messages[event_type]
        self._record(kind, event_type, message)

    def settings(self) -> Settings:
        return self._settings.model_copy(deep=True)

    def update_settings(self, settings: Settings) -> Settings:
        self._settings = self.store.save(settings)
        self._scanner = self._make_scanner()
        self._record("success", "configuration_updated", "Configuration updated")
        return self.settings()

    def preview_project(self, path: Path) -> RepositoryInfo:
        self._reject_real_path_action()
        canonical = validate_selected_path(path, app_data=self.store.paths.data)
        return self._scanner.scan(
            ProjectConfig(name=canonical.name or str(canonical), path=canonical), force=True
        )

    def preview_root(self, path: Path) -> list[RepositoryInfo]:
        self._reject_real_path_action()
        canonical = validate_selected_path(path, app_data=self.store.paths.data)
        preview_settings = self._settings.model_copy(
            update={
                "projects": [],
                "scan_roots": [ScanRootConfig(path=canonical, recursive=True)],
            }
        )
        projects = ProjectDiscovery(preview_settings).discover()
        return self._scanner.scan_all(
            projects,
            force=True,
            cancel_event=self._shutdown_requested,
        )

    def add_projects(self, paths: list[Path]) -> Settings:
        self._reject_real_path_action()
        existing = {
            os.path.normcase(os.path.abspath(item.path)): item for item in self._settings.projects
        }
        added = 0
        for path in paths:
            canonical = validate_selected_path(
                path, app_data=self.store.paths.data, require_git=True
            )
            key = os.path.normcase(os.path.abspath(canonical))
            if key in existing:
                continue
            project = ProjectConfig(name=canonical.name or str(canonical), path=canonical)
            existing[key] = project
            added += 1
            self._record(
                "success",
                "project_added",
                f"Project added: {project.name}",
                project_id(canonical),
            )
        if not added:
            raise ValueError("Every selected repository is already registered.")
        updated = self._settings.model_copy(
            update={"projects": list(existing.values()), "onboarding_completed": True}
        )
        self.update_settings(updated)
        self.refresh(force=True)
        return self.settings()

    def remove_project(self, identifier: str) -> Settings:
        selected = next(
            (item for item in self._settings.projects if project_id(item.path) == identifier), None
        )
        if selected is None:
            raise KeyError("Project not found")
        projects = [item for item in self._settings.projects if project_id(item.path) != identifier]
        self._repositories = [
            item for item in self._repositories if project_id(item.project.path) != identifier
        ]
        self.update_settings(self._settings.model_copy(update={"projects": projects}))
        self._write_cache()
        self._record(
            "info",
            "project_removed",
            f"Project removed from DevPulse: {selected.name}",
            identifier,
        )
        return self.settings()

    def update_project_path(self, identifier: str, path: Path) -> Settings:
        return self.update_project(identifier, path=path)

    def update_project(
        self,
        identifier: str,
        *,
        path: Path | None = None,
        name: str | None = None,
        favorite: bool | None = None,
        tags: set[str] | None = None,
        notes: str | None = None,
        archived: bool | None = None,
    ) -> Settings:
        if path is not None:
            self._reject_real_path_action()
            canonical = validate_selected_path(
                path, app_data=self.store.paths.data, require_git=True
            )
        else:
            canonical = None
        if (
            any(
                project_id(item.path) != identifier
                and os.path.normcase(os.path.abspath(item.path))
                == os.path.normcase(os.path.abspath(canonical))
                for item in self._settings.projects
            )
            if canonical is not None
            else False
        ):
            raise ValueError("That repository is already registered.")
        found = False
        projects: list[ProjectConfig] = []
        for item in self._settings.projects:
            if project_id(item.path) == identifier:
                updates: dict[str, object] = {}
                if canonical is not None:
                    updates.update({"name": canonical.name or item.name, "path": canonical})
                if name is not None:
                    updates["name"] = name
                if favorite is not None:
                    updates["favorite"] = favorite
                if tags is not None:
                    updates["tags"] = tags
                if notes is not None:
                    updates["notes"] = notes
                if archived is not None:
                    updates["archived"] = archived
                projects.append(item.model_copy(update=updates))
                found = True
            else:
                projects.append(item)
        if not found:
            raise KeyError("Project not found")
        self.update_settings(self._settings.model_copy(update={"projects": projects}))
        if archived is True:
            self._record(
                "info", "project_archived", "Project archived from the dashboard", identifier
            )
        elif archived is False:
            self._record(
                "info", "project_restored", "Project restored to the dashboard", identifier
            )
        if canonical is not None:
            self.refresh(force=True)
        else:
            selected = next(item for item in projects if project_id(item.path) == identifier)
            with self._lock:
                self._repositories = [
                    repository.model_copy(update={"project": selected})
                    if project_id(repository.project.path) == identifier
                    else repository
                    for repository in self._repositories
                ]
            self._write_cache()
        return self.settings()

    def export_configuration(self, *, include_notes: bool = False) -> dict[str, object]:
        settings = self.settings()
        settings_payload = settings.model_dump(mode="json", exclude={"projects"})
        projects = []
        for item in settings.projects:
            project = {
                "name": item.name,
                "path": str(item.path),
                "favorite": item.favorite,
                "tags": sorted(item.tags),
                "archived": item.archived,
            }
            if include_notes:
                project["notes"] = item.notes
            projects.append(project)
        return {
            "schema_version": 4,
            "exported_at": datetime.now(UTC).isoformat(),
            "includes_notes": include_notes,
            "settings": settings_payload,
            "projects": projects,
        }

    def preview_configuration_import(self, payload: dict[str, object]) -> dict[str, object]:
        incoming = self._parse_import(payload)
        current = {
            os.path.normcase(os.path.abspath(item.path)): item for item in self._settings.projects
        }
        additions: list[dict[str, object]] = []
        updates: list[dict[str, object]] = []
        conflicts: list[dict[str, object]] = []
        for item in incoming:
            key = os.path.normcase(os.path.abspath(item.path))
            if key not in current:
                additions.append({"name": item.name, "path": str(item.path)})
            elif current[key].model_dump(exclude={"path"}) != item.model_dump(exclude={"path"}):
                updates.append({"name": item.name, "path": str(item.path)})
            else:
                conflicts.append(
                    {"name": item.name, "path": str(item.path), "reason": "Already registered"}
                )
        return {"additions": additions, "updates": updates, "conflicts": conflicts, "valid": True}

    def import_configuration(self, payload: dict[str, object]) -> Settings:
        incoming = self._parse_import(payload)
        self.create_backup(source="pre-import")
        settings_payload = payload.get("settings", {})
        if not isinstance(settings_payload, dict):
            raise ValueError("Configuration settings must be an object.")
        current = self._settings.model_dump(mode="python")
        allowed = {
            "onboarding_completed",
            "scan_roots",
            "maximum_scan_depth",
            "maximum_repositories_per_root",
            "maximum_directories_per_scan",
            "scan_timeout_seconds",
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
        current.update({key: value for key, value in settings_payload.items() if key in allowed})
        current["projects"] = incoming
        current["schema_version"] = 4
        settings = Settings.model_validate(current)
        result = self.update_settings(settings)
        self._record("success", "configuration_imported", "Configuration imported")
        return result

    def create_backup(self, *, source: str = "manual") -> dict[str, object]:
        self.store.paths.ensure()
        stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
        backup_id = f"{stamp}-{uuid4().hex[:8]}"
        destination = self.store.paths.backups / f"{backup_id}.json"
        payload = self.export_configuration(include_notes=True)
        payload["backup_source"] = source
        temporary = destination.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        temporary.replace(destination)
        return {
            "id": backup_id,
            "created_at": datetime.now(UTC),
            "size_bytes": destination.stat().st_size,
            "source": source,
        }

    def backups(self) -> list[dict[str, object]]:
        self.store.paths.ensure()
        result: list[dict[str, object]] = []
        for path in sorted(self.store.paths.backups.glob("*.json"), reverse=True)[:50]:
            try:
                result.append(
                    {
                        "id": path.stem,
                        "created_at": datetime.fromtimestamp(path.stat().st_mtime, UTC),
                        "size_bytes": path.stat().st_size,
                        "source": "backup",
                    }
                )
            except OSError:
                continue
        return result

    def restore_backup(self, backup_id: str) -> Settings:
        if not re.fullmatch(r"\d{8}T\d{6}Z-[0-9a-f]{8}", backup_id):
            raise ValueError("Invalid backup identifier.")
        path = (self.store.paths.backups / f"{backup_id}.json").resolve()
        if path.parent != self.store.paths.backups.resolve() or not path.is_file():
            raise ValueError("Backup not found.")
        payload = json.loads(path.read_text(encoding="utf-8"))
        result = self.import_configuration(payload)
        self._record("success", "recovery_performed", "Configuration backup restored")
        return result

    def delete_backup(self, backup_id: str) -> None:
        path = (self.store.paths.backups / f"{backup_id}.json").resolve()
        if path.parent != self.store.paths.backups.resolve():
            raise ValueError("Invalid backup identifier.")
        path.unlink(missing_ok=True)

    def _parse_import(self, payload: dict[str, object]) -> list[ProjectConfig]:
        if payload.get("schema_version") not in {3, 4}:
            raise ValueError("This configuration export is not a supported DevPulse schema.")
        projects = payload.get("projects")
        if not isinstance(projects, list) or len(projects) > 500:
            raise ValueError("Configuration project list is invalid.")
        parsed: list[ProjectConfig] = []
        for item in projects:
            if not isinstance(item, dict):
                raise ValueError("Configuration contains an invalid project entry.")
            path_value = item.get("path")
            if not isinstance(path_value, str):
                raise ValueError("Configuration project path is invalid.")
            path = Path(path_value)
            if not path.is_absolute() or ".." in path.parts or path == Path(path.anchor):
                raise ValueError("Configuration contains an unsafe project path.")
            canonical = path.resolve(strict=False)
            if canonical.exists():
                validate_selected_path(canonical, app_data=self.store.paths.data)
            parsed.append(
                ProjectConfig(
                    name=str(item.get("name") or canonical.name or "Project"),
                    path=canonical,
                    favorite=bool(item.get("favorite", False)),
                    tags=set(item.get("tags", []))
                    if isinstance(item.get("tags", []), list)
                    else set(),
                    notes=str(item.get("notes", ""))[:4_000],
                    archived=bool(item.get("archived", False)),
                )
            )
        return parsed

    def complete_onboarding(self) -> Settings:
        return self.update_settings(
            self._settings.model_copy(update={"onboarding_completed": True})
        )

    def qa_status(self) -> dict[str, object]:
        return {
            "enabled": self.qa_mode,
            "artificial_data": self.qa_mode,
            "data_root": str(self.store.paths.data) if self.qa_mode else None,
            "test_lab": str(self.store.paths.test_lab) if self.qa_mode else None,
        }

    def reset_qa_data(self) -> Settings:
        with self._operation_lock:
            self._require_qa_mode()
            reset_test_lab(self.store.paths)
            self._settings = self.store.save(
                Settings(onboarding_completed=True, refresh_interval_seconds=0, appearance="light")
            )
            self._scanner = self._make_scanner()
            with self._lock:
                self._repositories = []
                self._last_refresh = None
            self._activity = []
            self._activity_store.clear()
            self._write_cache()
            self._record("warning", "qa_data_reset", "Artificial QA data reset")
            return self.settings()

    def regenerate_qa_data(self) -> Settings:
        with self._operation_lock:
            self._require_qa_mode()
            self._settings = self._generate_qa_settings()
            self._scanner = self._make_scanner()
            self.refresh(force=True)
            self._record("success", "qa_data_regenerated", "Artificial QA data regenerated")
            return self.settings()

    def safe_diagnostics(self) -> dict[str, object]:
        snapshot = self.system_snapshot()
        errors = [item.event_type for item in self.activity(200) if item.kind == "error"]
        status = "never_scanned" if self.last_refresh is None else "completed"
        return build_safe_diagnostics(
            qa_mode=self.qa_mode,
            data_root=self.store.paths.data,
            schema_version=self._settings.schema_version,
            project_count=len(self.projects()),
            cache_status=snapshot.cache_status,
            last_scan_status=status,
            recent_error_codes=errors,
            startup_duration_ms=snapshot.process_uptime_seconds * 1_000,
            log_path=self.store.paths.logs / "local-core.log",
        )

    def safe_diagnostics_export(self) -> str:
        return export_safe_diagnostics(self.safe_diagnostics())

    def _generate_qa_settings(self) -> Settings:
        fixtures = generate_test_lab(self.store.paths)
        return self.store.save(qa_settings(self.store.paths, fixtures))

    def _require_qa_mode(self) -> None:
        if not self.qa_mode:
            raise ValueError("QA data controls are unavailable outside QA mode.")

    def _reject_real_path_action(self) -> None:
        if self.qa_mode:
            raise ValueError("Real project folders cannot be selected while QA mode is active.")

    def _make_scanner(self) -> RepositoryScanner:
        return RepositoryScanner(
            self._settings.cache_duration_seconds,
            self._settings.maximum_commits_displayed,
            self.store.paths.data,
            self.store.paths.test_lab if self.qa_mode else None,
        )

    def _record(
        self,
        kind: str,
        event_type: str,
        message: str,
        identifier: str | None = None,
    ) -> None:
        event = ActivityEvent(
            id=uuid4().hex,
            timestamp=datetime.now(UTC),
            kind=kind,  # type: ignore[arg-type]
            event_type=event_type,  # type: ignore[arg-type]
            message=message,
            project_id=identifier,
        )
        with self._lock:
            self._activity.append(event)
            self._activity = self._activity[-1_000:]
            events = list(self._activity)
        self._activity_store.save(events)
        logger.info(message)

    @property
    def _cache_path(self) -> Path:
        return self.store.paths.cache / "repositories-v1.json"

    def _write_cache(self) -> None:
        self.store.paths.ensure()
        payload = {
            "version": 1,
            "last_refresh": self._last_refresh.isoformat() if self._last_refresh else None,
            "repositories": [item.model_dump(mode="json") for item in self._repositories],
        }
        temporary = self._cache_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        temporary.replace(self._cache_path)

    def _load_cache(self) -> None:
        try:
            raw = json.loads(self._cache_path.read_text(encoding="utf-8"))
            if raw.get("version") != 1:
                return
            repositories = [RepositoryInfo.model_validate(item) for item in raw["repositories"]]
            refreshed = raw.get("last_refresh")
            with self._lock:
                self._repositories = repositories
                self._last_refresh = datetime.fromisoformat(refreshed) if refreshed else None
        except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
            return
