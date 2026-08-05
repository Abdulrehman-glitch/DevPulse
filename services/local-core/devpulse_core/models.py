"""Validated local-core domain models, independent of the HTTP transport."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

DEFAULT_IGNORED_DIRECTORIES = {
    "node_modules",
    ".venv",
    "venv",
    "__pycache__",
    "dist",
    "build",
    "coverage",
    "htmlcov",
    ".idea",
    ".cache",
    "target",
    "vendor",
    "generated",
}


class ProjectConfig(BaseModel):
    """An explicitly configured or automatically discovered project."""

    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1, max_length=120)
    path: Path
    favorite: bool = False
    tags: set[str] = Field(default_factory=set)
    notes: str = Field(default="", max_length=4_000)
    archived: bool = False
    # Accepted only to migrate the terminal-era configuration. Never executed or returned.
    commands: dict[str, str] = Field(default_factory=dict, exclude=True)

    @field_validator("name")
    @classmethod
    def normalise_name(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("project name cannot be empty")
        return value

    @field_validator("tags")
    @classmethod
    def normalise_tags(cls, value: set[str]) -> set[str]:
        cleaned = {item.strip()[:40] for item in value if item.strip()}
        if len(cleaned) > 20:
            raise ValueError("a project can have at most 20 tags")
        return cleaned


class ScanRootConfig(BaseModel):
    """A folder that may contain Git repository roots."""

    model_config = ConfigDict(extra="forbid")

    path: Path
    recursive: bool = True


class SavedView(BaseModel):
    """A bounded, user-named project inventory view."""

    model_config = ConfigDict(extra="forbid")

    id: str = Field(min_length=1, max_length=80)
    name: str = Field(min_length=1, max_length=80)
    query: str = Field(default="", max_length=200)
    status: str = Field(default="all", max_length=32)
    technology: str = Field(default="all", max_length=80)
    tag: str = Field(default="all", max_length=80)
    warning: str = Field(default="all", max_length=32)
    minimum_health: int = Field(default=0, ge=0, le=100)
    sort: str = Field(default="name", max_length=32)
    favorites_only: bool = False
    show_archived: bool = False


class Settings(BaseModel):
    """Writable, non-secret application settings stored in per-user app data."""

    model_config = ConfigDict(extra="forbid")

    schema_version: Literal[4] = 4
    onboarding_completed: bool = False
    projects: list[ProjectConfig] = Field(default_factory=list)
    scan_roots: list[ScanRootConfig] = Field(default_factory=list)
    maximum_scan_depth: int = Field(default=3, ge=0, le=12)
    maximum_repositories_per_root: int = Field(default=100, ge=1, le=500)
    maximum_directories_per_scan: int = Field(default=5_000, ge=50, le=50_000)
    scan_timeout_seconds: int = Field(default=20, ge=2, le=120)
    ignored_directories: set[str] = Field(default_factory=lambda: set(DEFAULT_IGNORED_DIRECTORIES))
    cache_duration_seconds: int = Field(default=30, ge=0, le=86_400)
    refresh_interval_seconds: int = Field(default=300, ge=0, le=86_400)
    maximum_commits_displayed: int = Field(default=5, ge=1, le=50)
    appearance: Literal["system", "light", "dark"] = "system"
    start_minimized: bool = False
    reduced_motion: bool = False
    confirm_before_removing_project: bool = True
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"] = "INFO"
    default_landing_page: Literal[
        "overview", "projects", "activity", "system", "diagnostics", "settings"
    ] = "overview"
    date_time_display: Literal["local", "utc"] = "local"
    table_density: Literal["comfortable", "compact"] = "comfortable"
    stale_project_days: int = Field(default=30, ge=1, le=3650)
    default_sort: Literal["name", "recent", "changes", "health", "warnings", "refresh"] = "name"
    notification_preferences: dict[str, bool] = Field(default_factory=dict)
    notification_severity_threshold: Literal["info", "success", "warning", "error"] = "warning"
    notification_history_length: int = Field(default=200, ge=20, le=2_000)
    saved_views: list[SavedView] = Field(default_factory=list, max_length=50)
    active_saved_view: str | None = Field(default=None, max_length=80)

    @field_validator("ignored_directories")
    @classmethod
    def normalise_ignored_directories(cls, value: set[str]) -> set[str]:
        normalised = {item.strip().casefold() for item in value if item.strip()}
        if any("/" in item or "\\" in item or item in {".", ".."} for item in normalised):
            raise ValueError("ignored directories must be plain directory names")
        return normalised


class CommitInfo(BaseModel):
    short_sha: str
    message: str
    author: str
    date: datetime


class HealthCheck(BaseModel):
    label: str
    points: int
    earned: bool
    detail: str


class RepositoryInfo(BaseModel):
    """A complete read-only snapshot of a project's filesystem and Git state."""

    project: ProjectConfig
    exists: bool
    is_git_repository: bool
    branch: str = "-"
    tracking_branch: str | None = None
    detached_head: bool = False
    is_clean: bool | None = None
    status: str = "unknown"
    changed_files: int = 0
    modified_count: int = 0
    staged_count: int = 0
    untracked_count: int = 0
    ahead_count: int = 0
    behind_count: int = 0
    modified_files: list[str] = Field(default_factory=list)
    staged_files: list[str] = Field(default_factory=list)
    untracked_files: list[str] = Field(default_factory=list)
    last_commit_message: str = "-"
    last_commit_author: str = "-"
    last_commit_date: datetime | None = None
    repository_age_days: int | None = None
    recent_activity: bool | None = None
    commits: list[CommitInfo] = Field(default_factory=list)
    technologies: list[str] = Field(default_factory=list)
    primary_technology: str = "Unknown"
    important_files: list[str] = Field(default_factory=list)
    root_files: list[str] = Field(default_factory=list)
    dependency_manager: str | None = None
    testing_framework: str | None = None
    ci_provider: str | None = None
    container_support: bool = False
    deployment_indicators: list[str] = Field(default_factory=list)
    monorepo: bool = False
    application_directories: list[str] = Field(default_factory=list)
    documentation_directory: bool = False
    remote_present: bool = False
    health_score: int = 0
    health_breakdown: list[HealthCheck] = Field(default_factory=list)
    warnings: list[str] = Field(default_factory=list)
    warning_details: list[WarningFinding] = Field(default_factory=list)
    last_scan_duration_ms: int = Field(default=0, ge=0)
    last_scan_timestamp: datetime
    error: str | None = None


class WarningFinding(BaseModel):
    code: str
    title: str
    what: str
    why: str
    changed: str = "DevPulse did not change anything."
    suggested_action: str


class SystemHistoryPoint(BaseModel):
    timestamp: datetime
    cpu_percent: float | None = None
    memory_percent: float | None = None
    scan_duration_ms: int | None = None
    refresh_succeeded: bool | None = None
    warning_count: int = 0


RepositoryInfo.model_rebuild()


class DiskVolume(BaseModel):
    mount: str
    usage_percent: float = Field(ge=0, le=100)
    free_bytes: int = Field(ge=0)


class SystemSnapshot(BaseModel):
    cpu_percent: float | None = Field(default=None, ge=0, le=100)
    logical_processors: int | None = Field(default=None, ge=1)
    memory_percent: float | None = Field(default=None, ge=0, le=100)
    memory_available_bytes: int | None = Field(default=None, ge=0)
    disk_percent: float | None = Field(default=None, ge=0, le=100)
    volumes: list[DiskVolume] = Field(default_factory=list)
    process_uptime_seconds: int = Field(default=0, ge=0)
    scan_worker_status: Literal["idle", "scanning"] = "idle"
    cache_status: Literal["ready", "empty", "unavailable"] = "empty"
    application_data_location: str = ""
    log_directory_location: str = ""


class ActivityEvent(BaseModel):
    id: str
    timestamp: datetime
    kind: Literal["info", "success", "warning", "error"]
    event_type: Literal[
        "application_started",
        "core_started",
        "core_connected",
        "project_added",
        "project_removed",
        "scan_started",
        "scan_completed",
        "scan_failed",
        "configuration_updated",
        "configuration_migrated",
        "configuration_imported",
        "configuration_exported",
        "recovery_performed",
        "core_restarted",
        "shutdown_requested",
        "qa_mode_started",
        "qa_data_reset",
        "qa_data_regenerated",
        "project_archived",
        "project_restored",
        "warning_appeared",
        "warning_resolved",
    ]
    message: str
    project_id: str | None = None
