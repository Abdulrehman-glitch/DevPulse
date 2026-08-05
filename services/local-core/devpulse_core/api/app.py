"""Loopback-only FastAPI transport for the DevPulse local data provider."""

from __future__ import annotations

import asyncio
import json
import logging
import secrets
from contextlib import asynccontextmanager, suppress
from datetime import UTC, datetime
from uuid import uuid4

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from devpulse_core import __version__
from devpulse_core.api.schemas import (
    ActivityResponse,
    BackupSummary,
    ConfigurationExportResponse,
    ConfigurationImportPreview,
    ConfigurationImportRequest,
    DiagnosticsExportResponse,
    DiagnosticsResponse,
    ErrorDetail,
    ErrorResponse,
    HealthResponse,
    PathRequest,
    ProjectDetailResponse,
    ProjectListResponse,
    ProjectPatch,
    ProjectPathsRequest,
    ProjectSummary,
    QaStatusResponse,
    RegisteredProjectPathResponse,
    SettingsPatch,
    SettingsResponse,
    SystemHistoryResponse,
    SystemSummaryResponse,
)
from devpulse_core.models import ScanRootConfig
from devpulse_core.providers.local import LocalDataProvider

logger = logging.getLogger(__name__)

MIN_ACCESS_TOKEN_LENGTH = 32


def create_app(
    provider: LocalDataProvider | None = None,
    *,
    access_token: str | None = None,
    instance_id: str | None = None,
    refresh_on_start: bool = True,
    allow_unauthenticated_for_tests: bool = False,
) -> FastAPI:
    if access_token is None:
        if not allow_unauthenticated_for_tests:
            raise ValueError("Production local API construction requires an access token.")
    elif len(access_token) < MIN_ACCESS_TOKEN_LENGTH:
        raise ValueError(
            "The local API access token must contain at least "
            f"{MIN_ACCESS_TOKEN_LENGTH} characters."
        )
    local = provider or LocalDataProvider()
    identity = instance_id or uuid4().hex

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        task: asyncio.Task[None] | None = None
        if refresh_on_start:
            task = asyncio.create_task(_refresh_on_schedule(local))
        yield
        if task:
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task

    app = FastAPI(
        title="DevPulse Local API",
        version=__version__,
        description="Versioned loopback API for the DevPulse desktop client.",
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
    )
    app.state.provider = local
    app.state.access_token = access_token
    app.state.instance_id = identity
    local.record_lifecycle_event("core_connected")
    app.add_middleware(
        CORSMiddleware,
        allow_origins=[
            "tauri://localhost",
            "http://tauri.localhost",
            "https://tauri.localhost",
            "http://localhost:1420",
            "http://127.0.0.1:1420",
        ],
        allow_credentials=False,
        allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
        allow_headers=["Content-Type", "X-DevPulse-Token", "X-Request-ID"],
    )

    @app.middleware("http")
    async def authenticate(request: Request, call_next):  # type: ignore[no-untyped-def]
        request_id = request.headers.get("X-Request-ID", uuid4().hex)
        request.state.request_id = request_id
        supplied_token = request.headers.get("X-DevPulse-Token")
        protected_request = request.method != "OPTIONS" and request.url.path.startswith(
            ("/api/", "/internal/", "/health")
        )
        authenticated = access_token is None or (
            supplied_token is not None and secrets.compare_digest(supplied_token, access_token)
        )
        if protected_request and not authenticated:
            return JSONResponse(
                status_code=401,
                content=ErrorResponse(
                    error=ErrorDetail(
                        code="unauthorised",
                        message="The local-core access token is missing or invalid.",
                        request_id=request_id,
                    )
                ).model_dump(mode="json"),
            )
        content_length = request.headers.get("content-length")
        if content_length:
            try:
                if int(content_length) > 65_536:
                    return _error(
                        request, 413, "request_too_large", "The request body is too large."
                    )
            except ValueError:
                return _error(request, 400, "invalid_request", "Invalid content length.")
        response = await call_next(request)
        response.headers["X-Request-ID"] = request_id
        return response

    @app.exception_handler(RequestValidationError)
    async def validation_error(request: Request, _: RequestValidationError) -> JSONResponse:
        return _error(request, 422, "invalid_request", "The request contains invalid values.")

    @app.exception_handler(HTTPException)
    async def http_error(request: Request, exc: HTTPException) -> JSONResponse:
        return _error(request, exc.status_code, "request_failed", str(exc.detail))

    @app.exception_handler(Exception)
    async def unexpected_error(request: Request, _: Exception) -> JSONResponse:
        logger.exception("Unhandled local API error")
        return _error(
            request,
            500,
            "internal_error",
            "The local service could not complete the request. Review diagnostics.",
        )

    @app.get("/health", response_model=HealthResponse, tags=["internal"])
    async def health() -> HealthResponse:
        return HealthResponse(version=__version__, instance_id=identity, qa_mode=local.qa_mode)

    @app.post("/internal/shutdown", status_code=202, tags=["internal"])
    async def shutdown(request: Request) -> dict[str, str]:
        local.record_lifecycle_event("shutdown_requested")
        callback = getattr(request.app.state, "shutdown_callback", None)
        if callback is not None:
            asyncio.get_running_loop().call_later(0.05, callback)
        return {"status": "shutting_down"}

    @app.post("/internal/events/{event_type}", status_code=202, tags=["internal"])
    async def lifecycle_event(event_type: str) -> dict[str, str]:
        try:
            local.record_lifecycle_event(event_type.replace("-", "_"))
        except ValueError as exc:
            raise HTTPException(status_code=404, detail="Unsupported lifecycle event.") from exc
        return {"status": "recorded"}

    @app.get("/api/v1/system/summary", response_model=SystemSummaryResponse, tags=["system"])
    async def system_summary() -> SystemSummaryResponse:
        repositories = local.projects()
        snapshot = await asyncio.to_thread(local.system_snapshot)
        return SystemSummaryResponse.from_domain(
            snapshot, repositories, local.last_refresh, local.refreshing
        )

    @app.get("/api/v1/projects", response_model=ProjectListResponse, tags=["projects"])
    async def projects() -> ProjectListResponse:
        items = local.projects()
        return ProjectListResponse(
            items=[ProjectSummary.from_domain(item) for item in items],
            total=len(items),
            last_successful_refresh=local.last_refresh,
        )

    @app.get(
        "/api/v1/projects/{project_identifier}",
        response_model=ProjectDetailResponse,
        tags=["projects"],
    )
    async def project(project_identifier: str) -> ProjectDetailResponse:
        item = local.project(project_identifier)
        if item is None:
            raise HTTPException(status_code=404, detail="Project not found.")
        return ProjectDetailResponse.from_domain(item)

    @app.get(
        "/api/v1/projects/{project_identifier}/open-path",
        response_model=RegisteredProjectPathResponse,
        tags=["projects"],
    )
    async def registered_project_open_path(
        project_identifier: str,
    ) -> RegisteredProjectPathResponse:
        try:
            path = await asyncio.to_thread(local.registered_project_path, project_identifier)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Project not found.") from exc
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return RegisteredProjectPathResponse(id=project_identifier, path=str(path))

    @app.post("/api/v1/projects/preview", response_model=ProjectDetailResponse, tags=["projects"])
    async def preview_project(request: PathRequest) -> ProjectDetailResponse:
        try:
            item = await asyncio.to_thread(local.preview_project, request.path)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return ProjectDetailResponse.from_domain(item)

    @app.post(
        "/api/v1/project-roots/preview", response_model=ProjectListResponse, tags=["projects"]
    )
    async def preview_root(request: PathRequest) -> ProjectListResponse:
        try:
            items = await asyncio.to_thread(local.preview_root, request.path)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return ProjectListResponse(
            items=[ProjectSummary.from_domain(item) for item in items],
            total=len(items),
            last_successful_refresh=None,
        )

    @app.post("/api/v1/projects", response_model=SettingsResponse, tags=["projects"])
    async def add_projects(request: ProjectPathsRequest) -> SettingsResponse:
        try:
            settings = await asyncio.to_thread(local.add_projects, request.paths)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return SettingsResponse.from_domain(settings)

    @app.delete(
        "/api/v1/projects/{project_identifier}", response_model=SettingsResponse, tags=["projects"]
    )
    async def remove_project(project_identifier: str) -> SettingsResponse:
        try:
            settings = await asyncio.to_thread(local.remove_project, project_identifier)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Project not found.") from exc
        return SettingsResponse.from_domain(settings)

    @app.patch(
        "/api/v1/projects/{project_identifier}", response_model=SettingsResponse, tags=["projects"]
    )
    async def update_project_path(
        project_identifier: str, request: ProjectPatch
    ) -> SettingsResponse:
        try:
            settings = await asyncio.to_thread(
                local.update_project,
                project_identifier,
                path=request.path,
                name=request.name,
                favorite=request.favorite,
                tags=request.tags,
                notes=request.notes,
                archived=request.archived,
            )
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Project not found.") from exc
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return SettingsResponse.from_domain(settings)

    @app.post("/api/v1/projects/refresh", response_model=ProjectListResponse, tags=["projects"])
    async def refresh_projects() -> ProjectListResponse:
        items = await asyncio.to_thread(local.refresh, force=True)
        return ProjectListResponse(
            items=[ProjectSummary.from_domain(item) for item in items],
            total=len(items),
            last_successful_refresh=local.last_refresh,
        )

    @app.get("/api/v1/system/history", response_model=SystemHistoryResponse, tags=["system"])
    async def system_history() -> SystemHistoryResponse:
        return SystemHistoryResponse(items=local.system_history())

    @app.get("/api/v1/activity", response_model=ActivityResponse, tags=["activity"])
    async def activity(limit: int = Query(default=30, ge=1, le=200)) -> ActivityResponse:
        return ActivityResponse(items=local.activity(limit))

    @app.delete("/api/v1/activity", status_code=204, tags=["activity"])
    async def clear_activity() -> None:
        local.clear_activity()

    @app.get("/api/v1/settings", response_model=SettingsResponse, tags=["settings"])
    async def settings() -> SettingsResponse:
        return SettingsResponse.from_domain(local.settings())

    @app.patch("/api/v1/settings", response_model=SettingsResponse, tags=["settings"])
    async def update_settings(patch: SettingsPatch) -> SettingsResponse:
        current = local.settings()
        updates = patch.model_dump(exclude_none=True)
        paths = updates.pop("project_directories", None)
        if paths is not None:
            validated = [
                local.preview_project(path).project.model_copy(
                    update={"name": path.name or str(path)}
                )
                for path in paths
            ]
            updates["projects"] = validated
        if "scan_roots" in updates:
            updates["scan_roots"] = [
                ScanRootConfig.model_validate(root) for root in updates["scan_roots"]
            ]
        payload = current.model_dump()
        payload.update(updates)
        updated = type(current).model_validate(payload)
        return SettingsResponse.from_domain(local.update_settings(updated))

    @app.get(
        "/api/v1/configuration/export",
        response_model=ConfigurationExportResponse,
        tags=["configuration"],
    )
    async def export_configuration(
        include_notes: bool = Query(default=False),
    ) -> ConfigurationExportResponse:
        payload = await asyncio.to_thread(local.export_configuration, include_notes=include_notes)
        return ConfigurationExportResponse.model_validate(payload)

    @app.post(
        "/api/v1/configuration/import/preview",
        response_model=ConfigurationImportPreview,
        tags=["configuration"],
    )
    async def preview_configuration_import(
        request: ConfigurationImportRequest,
    ) -> ConfigurationImportPreview:
        try:
            payload = await asyncio.to_thread(local.preview_configuration_import, request.payload)
        except (ValueError, KeyError, TypeError) as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return ConfigurationImportPreview.model_validate(payload)

    @app.post(
        "/api/v1/configuration/import",
        response_model=SettingsResponse,
        tags=["configuration"],
    )
    async def import_configuration(request: ConfigurationImportRequest) -> SettingsResponse:
        try:
            settings = await asyncio.to_thread(local.import_configuration, request.payload)
        except (ValueError, KeyError, TypeError) as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return SettingsResponse.from_domain(settings)

    @app.get("/api/v1/backups", response_model=list[BackupSummary], tags=["configuration"])
    async def backups() -> list[BackupSummary]:
        return [BackupSummary.model_validate(item) for item in local.backups()]

    @app.post("/api/v1/backups", response_model=BackupSummary, tags=["configuration"])
    async def create_backup() -> BackupSummary:
        return BackupSummary.model_validate(await asyncio.to_thread(local.create_backup))

    @app.post(
        "/api/v1/backups/{backup_identifier}/restore",
        response_model=SettingsResponse,
        tags=["configuration"],
    )
    async def restore_backup(backup_identifier: str) -> SettingsResponse:
        try:
            settings = await asyncio.to_thread(local.restore_backup, backup_identifier)
        except (ValueError, OSError, json.JSONDecodeError) as exc:
            raise HTTPException(
                status_code=400, detail="The selected backup could not be restored."
            ) from exc
        return SettingsResponse.from_domain(settings)

    @app.delete("/api/v1/backups/{backup_identifier}", status_code=204, tags=["configuration"])
    async def delete_backup(backup_identifier: str) -> None:
        try:
            await asyncio.to_thread(local.delete_backup, backup_identifier)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @app.get("/api/v1/qa/status", response_model=QaStatusResponse, tags=["qa"])
    async def qa_status() -> QaStatusResponse:
        return QaStatusResponse.model_validate(local.qa_status())

    @app.post("/api/v1/qa/reset", response_model=SettingsResponse, tags=["qa"])
    async def reset_qa_data() -> SettingsResponse:
        try:
            return SettingsResponse.from_domain(await asyncio.to_thread(local.reset_qa_data))
        except ValueError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc

    @app.post("/api/v1/qa/regenerate", response_model=SettingsResponse, tags=["qa"])
    async def regenerate_qa_data() -> SettingsResponse:
        try:
            return SettingsResponse.from_domain(await asyncio.to_thread(local.regenerate_qa_data))
        except ValueError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc

    @app.get("/api/v1/diagnostics", response_model=DiagnosticsResponse, tags=["diagnostics"])
    async def diagnostics() -> DiagnosticsResponse:
        return DiagnosticsResponse.model_validate(await asyncio.to_thread(local.safe_diagnostics))

    @app.get(
        "/api/v1/diagnostics/export",
        response_model=DiagnosticsExportResponse,
        tags=["diagnostics"],
    )
    async def diagnostics_export() -> DiagnosticsExportResponse:
        return DiagnosticsExportResponse(
            text=await asyncio.to_thread(local.safe_diagnostics_export)
        )

    return app


def _error(request: Request, status: int, code: str, message: str) -> JSONResponse:
    request_id = getattr(request.state, "request_id", uuid4().hex)
    return JSONResponse(
        status_code=status,
        content=ErrorResponse(
            error=ErrorDetail(code=code, message=message, request_id=request_id)
        ).model_dump(mode="json"),
    )


async def _refresh_on_schedule(local: LocalDataProvider) -> None:
    """Refresh immediately, then honor settings changes without restarting the service."""
    while True:
        try:
            await asyncio.to_thread(local.refresh, force=False)
        except Exception:
            logger.exception("Scheduled repository refresh failed")
            await asyncio.sleep(1)

        while True:
            interval = local.settings().refresh_interval_seconds
            if interval == 0:
                await asyncio.sleep(1)
                continue
            refreshed = local.last_refresh
            elapsed = (datetime.now(UTC) - refreshed).total_seconds() if refreshed else interval
            remaining = interval - elapsed
            if remaining <= 0:
                break
            await asyncio.sleep(min(remaining, 1))
