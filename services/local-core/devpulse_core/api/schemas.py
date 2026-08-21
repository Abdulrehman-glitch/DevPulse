"""Version 1 HTTP contracts. Field names remain stable within the API version."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from devpulse_core.models import (
    ActivityEvent,
    DiskVolume,
    RepositoryInfo,
    Settings,
    SystemHistoryPoint,
    SystemSnapshot,
)
from devpulse_core.providers.local import project_id


class HealthResponse(BaseModel):
    status: Literal["ok"] = "ok"
    version: str
    instance_id: str
    qa_mode: bool = False


class ErrorDetail(BaseModel):
    code: str
    message: str
    request_id: str


class ErrorResponse(BaseModel):
    error: ErrorDetail


class SystemSummaryResponse(BaseModel):
    cpu_percent: float | None
    logical_processors: int | None
    memory_percent: float | None
    memory_available_bytes: int | None
    disk_percent: float | None
    volumes: list[DiskVolume]
    process_uptime_seconds: int
    scan_worker_status: str
    cache_status: str
    application_data_location: str
    log_directory_location: str
    repositories_total: int
    clean_repositories: int
    modified_repositories: int
    repositories_with_warnings: int
    average_health_score: float | None
    last_successful_refresh: datetime | None
    refreshing: bool

    @classmethod
    def from_domain(
        cls,
        snapshot: SystemSnapshot,
        repositories: list[RepositoryInfo],
        last_refresh: datetime | None,
        refreshing: bool,
    ) -> SystemSummaryResponse:
        health = [item.health_score for item in repositories if item.is_git_repository]
        return cls(
            **snapshot.model_dump(),
            repositories_total=len(repositories),
            clean_repositories=sum(item.status == "clean" for item in repositories),
            modified_repositories=sum(
                item.status in {"modified", "untracked"} for item in repositories
            ),
            repositories_with_warnings=sum(bool(item.warnings) for item in repositories),
            average_health_score=round(sum(health) / len(health), 1) if health else None,
            last_successful_refresh=last_refresh,
            refreshing=refreshing,
        )


class ProjectSummary(BaseModel):
    id: str
    name: str
    path: str
    favorite: bool
    tags: list[str]
    notes: str
    archived: bool
    exists: bool
    is_git_repository: bool
    branch: str
    tracking_branch: str | None
    status: str
    changed_files: int
    modified_count: int
    staged_count: int
    untracked_count: int
    ahead_count: int
    behind_count: int
    last_commit_message: str
    last_commit_author: str
    last_commit_date: datetime | None
    repository_age_days: int | None
    recent_activity: bool | None
    primary_technology: str
    technologies: list[str]
    health_score: int
    warning_count: int
    last_scan_duration_ms: int
    last_scan_timestamp: datetime
    error: str | None

    @classmethod
    def from_domain(cls, item: RepositoryInfo) -> ProjectSummary:
        return cls(
            id=project_id(item.project.path),
            name=item.project.name,
            path=str(item.project.path),
            favorite=item.project.favorite,
            tags=sorted(item.project.tags),
            notes=item.project.notes,
            archived=item.project.archived,
            warning_count=len(item.warnings),
            **item.model_dump(
                include={
                    "exists",
                    "is_git_repository",
                    "branch",
                    "tracking_branch",
                    "status",
                    "changed_files",
                    "modified_count",
                    "staged_count",
                    "untracked_count",
                    "ahead_count",
                    "behind_count",
                    "last_commit_message",
                    "last_commit_author",
                    "last_commit_date",
                    "repository_age_days",
                    "recent_activity",
                    "primary_technology",
                    "technologies",
                    "health_score",
                    "last_scan_duration_ms",
                    "last_scan_timestamp",
                    "error",
                }
            ),
        )


class ProjectListResponse(BaseModel):
    items: list[ProjectSummary]
    total: int
    last_successful_refresh: datetime | None


class RegisteredProjectPathResponse(BaseModel):
    id: str
    path: str


class ProjectDetailResponse(BaseModel):
    summary: ProjectSummary
    modified_files: list[str]
    staged_files: list[str]
    untracked_files: list[str]
    important_files: list[str]
    root_files: list[str]
    dependency_manager: str | None
    testing_framework: str | None
    ci_provider: str | None
    container_support: bool
    deployment_indicators: list[str]
    monorepo: bool
    application_directories: list[str]
    documentation_directory: bool
    remote_present: bool
    commits: list[dict[str, object]]
    health_breakdown: list[dict[str, object]]
    warnings: list[str]
    warning_details: list[dict[str, object]]

    @classmethod
    def from_domain(cls, item: RepositoryInfo) -> ProjectDetailResponse:
        return cls(
            summary=ProjectSummary.from_domain(item),
            modified_files=item.modified_files,
            staged_files=item.staged_files,
            untracked_files=item.untracked_files,
            important_files=item.important_files,
            root_files=item.root_files,
            dependency_manager=item.dependency_manager,
            testing_framework=item.testing_framework,
            ci_provider=item.ci_provider,
            container_support=item.container_support,
            deployment_indicators=item.deployment_indicators,
            monorepo=item.monorepo,
            application_directories=item.application_directories,
            documentation_directory=item.documentation_directory,
            remote_present=item.remote_present,
            commits=[commit.model_dump(mode="json") for commit in item.commits],
            health_breakdown=[check.model_dump(mode="json") for check in item.health_breakdown],
            warnings=item.warnings,
            warning_details=[warning.model_dump(mode="json") for warning in item.warning_details],
        )


class ActivityResponse(BaseModel):
    items: list[ActivityEvent]


class SystemHistoryResponse(BaseModel):
    items: list[SystemHistoryPoint]


class SettingsResponse(BaseModel):
    schema_version: int
    onboarding_completed: bool
    projects: list[dict[str, object]]
    scan_roots: list[dict[str, object]]
    ignored_directories: list[str]
    maximum_scan_depth: int
    maximum_repositories_per_root: int
    maximum_directories_per_scan: int
    maximum_entries_per_scan: int
    scan_timeout_seconds: int
    repository_scan_timeout_seconds: int
    maximum_changed_paths: int
    cache_duration_seconds: int
    refresh_interval_seconds: int
    maximum_commits_displayed: int
    appearance: Literal["system", "light", "dark"]
    start_minimized: bool
    reduced_motion: bool
    confirm_before_removing_project: bool
    log_level: str
    default_landing_page: str
    date_time_display: str
    table_density: str
    stale_project_days: int
    default_sort: str
    notification_preferences: dict[str, bool]
    notification_severity_threshold: str
    notification_history_length: int
    saved_views: list[dict[str, object]]
    active_saved_view: str | None

    @classmethod
    def from_domain(cls, settings: Settings) -> SettingsResponse:
        return cls(
            schema_version=settings.schema_version,
            onboarding_completed=settings.onboarding_completed,
            projects=[
                {
                    "name": item.name,
                    "path": str(item.path),
                    "favorite": item.favorite,
                    "tags": sorted(item.tags),
                    "notes": item.notes,
                    "archived": item.archived,
                }
                for item in settings.projects
            ],
            scan_roots=[
                {"path": str(item.path), "recursive": item.recursive}
                for item in settings.scan_roots
            ],
            ignored_directories=sorted(settings.ignored_directories),
            maximum_scan_depth=settings.maximum_scan_depth,
            maximum_repositories_per_root=settings.maximum_repositories_per_root,
            maximum_directories_per_scan=settings.maximum_directories_per_scan,
            maximum_entries_per_scan=settings.maximum_entries_per_scan,
            scan_timeout_seconds=settings.scan_timeout_seconds,
            repository_scan_timeout_seconds=settings.repository_scan_timeout_seconds,
            maximum_changed_paths=settings.maximum_changed_paths,
            cache_duration_seconds=settings.cache_duration_seconds,
            refresh_interval_seconds=settings.refresh_interval_seconds,
            maximum_commits_displayed=settings.maximum_commits_displayed,
            appearance=settings.appearance,
            start_minimized=settings.start_minimized,
            reduced_motion=settings.reduced_motion,
            confirm_before_removing_project=settings.confirm_before_removing_project,
            log_level=settings.log_level,
            default_landing_page=settings.default_landing_page,
            date_time_display=settings.date_time_display,
            table_density=settings.table_density,
            stale_project_days=settings.stale_project_days,
            default_sort=settings.default_sort,
            notification_preferences=settings.notification_preferences,
            notification_severity_threshold=settings.notification_severity_threshold,
            notification_history_length=settings.notification_history_length,
            saved_views=[item.model_dump(mode="json") for item in settings.saved_views],
            active_saved_view=settings.active_saved_view,
        )


class SettingsPatch(BaseModel):
    model_config = ConfigDict(extra="forbid")

    project_directories: list[Path] | None = None
    onboarding_completed: bool | None = None
    scan_roots: list[dict[str, object]] | None = None
    ignored_directories: set[str] | None = None
    maximum_scan_depth: int | None = Field(default=None, ge=0, le=12)
    maximum_repositories_per_root: int | None = Field(default=None, ge=1, le=500)
    maximum_directories_per_scan: int | None = Field(default=None, ge=50, le=50_000)
    maximum_entries_per_scan: int | None = Field(default=None, ge=100, le=250_000)
    scan_timeout_seconds: int | None = Field(default=None, ge=2, le=120)
    repository_scan_timeout_seconds: int | None = Field(default=None, ge=2, le=60)
    maximum_changed_paths: int | None = Field(default=None, ge=50, le=10_000)
    cache_duration_seconds: int | None = Field(default=None, ge=0, le=86_400)
    refresh_interval_seconds: int | None = Field(default=None, ge=0, le=86_400)
    maximum_commits_displayed: int | None = Field(default=None, ge=1, le=50)
    appearance: Literal["system", "light", "dark"] | None = None
    start_minimized: bool | None = None
    reduced_motion: bool | None = None
    confirm_before_removing_project: bool | None = None
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"] | None = None
    default_landing_page: (
        Literal["overview", "projects", "activity", "system", "diagnostics", "settings"] | None
    ) = None
    date_time_display: Literal["local", "utc"] | None = None
    table_density: Literal["comfortable", "compact"] | None = None
    stale_project_days: int | None = Field(default=None, ge=1, le=3650)
    default_sort: Literal["name", "recent", "changes", "health", "warnings", "refresh"] | None = (
        None
    )
    notification_preferences: dict[str, bool] | None = None
    notification_severity_threshold: Literal["info", "success", "warning", "error"] | None = None
    notification_history_length: int | None = Field(default=None, ge=20, le=2_000)
    saved_views: list[dict[str, object]] | None = Field(default=None, max_length=50)
    active_saved_view: str | None = Field(default=None, max_length=80)


class PathRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    path: Path


class ProjectPathsRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    paths: list[Path] = Field(min_length=1, max_length=500)


class ProjectPatch(BaseModel):
    model_config = ConfigDict(extra="forbid")

    path: Path | None = None
    name: str | None = Field(default=None, min_length=1, max_length=120)
    favorite: bool | None = None
    tags: set[str] | None = None
    notes: str | None = Field(default=None, max_length=4_000)
    archived: bool | None = None


class ConfigurationExportResponse(BaseModel):
    schema_version: int
    exported_at: datetime
    includes_notes: bool
    settings: dict[str, object]
    projects: list[dict[str, object]]


class ConfigurationImportRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    payload: dict[str, object]


class ConfigurationImportPreview(BaseModel):
    additions: list[dict[str, object]]
    updates: list[dict[str, object]]
    conflicts: list[dict[str, object]]
    valid: bool


class BackupSummary(BaseModel):
    id: str
    created_at: datetime
    size_bytes: int
    source: str


class QaStatusResponse(BaseModel):
    enabled: bool
    artificial_data: bool
    data_root: str | None
    test_lab: str | None


class DiagnosticsResponse(BaseModel):
    devpulse_version: str
    operating_system: str
    qa_mode: bool
    local_core_status: str
    sidecar_status: str
    startup_duration_ms: int
    last_scan_status: str
    registered_projects: int
    cache_status: str
    configuration_schema_version: int
    data_boundary: str
    recent_error_codes: list[str]
    log_excerpt: list[str]


class DiagnosticsExportResponse(BaseModel):
    text: str
