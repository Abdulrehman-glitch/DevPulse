"""Packaged local-core executable entry point."""

from __future__ import annotations

import argparse
import json
import multiprocessing
import os
import socket
import sys
from pathlib import Path
from uuid import uuid4

import uvicorn

from devpulse_core.api import create_app
from devpulse_core.config import SettingsStore
from devpulse_core.logging import configure_logging
from devpulse_core.paths import AppPaths
from devpulse_core.providers import LocalDataProvider
from devpulse_core.startup import (
    LaunchProtocolError,
    read_launch_message,
    readiness_frame,
    reject_legacy_secret_arguments,
)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="DevPulse local core")
    result.add_argument("--host", default="127.0.0.1", choices=["127.0.0.1"])
    result.add_argument("--port", type=int, default=0)
    result.add_argument("--data-dir", type=Path, default=None)
    result.add_argument("--qa-mode", action="store_true")
    result.add_argument("--dev", action="store_true")
    return result


def write_qa_path_report(paths: AppPaths) -> Path:
    """Record only DevPulse-owned resolver outputs inside the validated QA data root."""
    root = paths.data.resolve()
    resolved = {
        "pythonLocalCoreConfigurationDirectory": paths.data.resolve(),
        "pythonCacheDirectory": paths.cache.resolve(),
        "pythonLogDirectory": paths.logs.resolve(),
        "qaRepositoryDirectory": paths.test_lab.resolve(),
        "diagnosticsExportDirectory": (paths.data / "diagnostics").resolve(),
        "activityStorage": paths.activity.resolve(),
    }
    environment_paths = {
        name: Path(value).resolve() if (value := os.getenv(name)) else None
        for name in (
            "APPDATA",
            "LOCALAPPDATA",
            "WEBVIEW2_USER_DATA_FOLDER",
            "DEVPULSE_DATA_DIR",
            "DEVPULSE_QA_ROOT",
        )
    }
    environment_matches = (
        os.getenv("DEVPULSE_QA_MODE") == "1"
        and all(
            path is not None and path.is_relative_to(root) for path in environment_paths.values()
        )
        and environment_paths["DEVPULSE_DATA_DIR"] == root
        and environment_paths["DEVPULSE_QA_ROOT"] == root
    )
    payload = {
        "schemaVersion": 2,
        "qaMode": True,
        "qaRoot": str(root),
        **{name: str(path) for name, path in resolved.items()},
        "updaterStorage": {"enabled": False, "path": None},
        "pluginStorage": {},
        "environment": {
            "qaModePresent": os.getenv("DEVPULSE_QA_MODE") == "1",
            "installQaPresent": os.getenv("DEVPULSE_INSTALL_QA") == "1",
            **{name: str(path) if path else None for name, path in environment_paths.items()},
        },
        "environmentMatchesCanonicalPlan": environment_matches,
        "allWritablePathsUnderQaRoot": all(path.is_relative_to(root) for path in resolved.values()),
    }
    destination = root / "local-core-path-report.json"
    temporary = destination.with_suffix(".tmp")
    temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    temporary.replace(destination)
    return destination


def resolve_runtime_paths(args: argparse.Namespace) -> AppPaths:
    """Choose production or strict QA paths without permitting a partial QA launch."""
    qa_environment_requested = any(
        (
            os.getenv("DEVPULSE_QA_MODE") == "1",
            os.getenv("DEVPULSE_INSTALL_QA") == "1",
            os.getenv("DEVPULSE_QA_AUTOMATION") == "1",
            os.getenv("DEVPULSE_QA_FAIL_START") == "1",
            os.getenv("DEVPULSE_QA_ROOT") is not None,
        )
    )
    if not args.qa_mode:
        if qa_environment_requested:
            raise ValueError("QA environment variables require the --qa-mode gate")
        return AppPaths.resolve(args.data_dir)

    if os.getenv("DEVPULSE_QA_MODE") != "1":
        raise ValueError("--qa-mode requires DEVPULSE_QA_MODE=1")
    if os.getenv("DEVPULSE_INSTALL_QA") not in (None, "0", "1"):
        raise ValueError("DEVPULSE_INSTALL_QA accepts only 0 or 1")
    root_value = os.getenv("DEVPULSE_QA_ROOT")
    if not root_value:
        raise ValueError("--qa-mode requires DEVPULSE_QA_ROOT")
    paths = AppPaths.resolve_qa(args.data_dir, Path(root_value))
    configured_data = os.getenv("DEVPULSE_DATA_DIR")
    if not configured_data or AppPaths.validate_qa_root(Path(configured_data)) != paths.data:
        raise ValueError("DEVPULSE_DATA_DIR must match the canonical QA root")
    for name in ("APPDATA", "LOCALAPPDATA", "WEBVIEW2_USER_DATA_FOLDER"):
        value = os.getenv(name)
        if not value or not Path(value).resolve().is_relative_to(paths.data):
            raise ValueError(f"{name} must resolve inside the canonical QA root")
    return paths


def resolve_access_token(provided: str | None) -> str:
    """Accept only a strong token supplied through the inherited launch channel."""
    if provided is None or len(provided) < 32:
        raise ValueError("The local-core access token must contain at least 32 characters")
    return provided


def main() -> None:
    try:
        reject_legacy_secret_arguments(sys.argv[1:])
        args = parser().parse_args()
        launch = read_launch_message()
    except LaunchProtocolError as error:
        raise SystemExit(78) from error
    try:
        paths = resolve_runtime_paths(args)
    except ValueError as error:
        raise SystemExit(78) from error
    if args.qa_mode and os.getenv("DEVPULSE_QA_FAIL_START") == "1":
        raise SystemExit(78)
    try:
        token = resolve_access_token(launch.token)
    except ValueError as error:
        raise SystemExit(78) from error
    instance_id = uuid4().hex
    if args.qa_mode:
        write_qa_path_report(paths)
    settings_store = SettingsStore(paths)
    provider = LocalDataProvider(settings_store, qa_mode=args.qa_mode)
    configure_logging(paths.logs, provider.settings().log_level)
    app = create_app(provider, access_token=token, instance_id=instance_id)

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((args.host, args.port))
    listener.listen(2048)
    port = int(listener.getsockname()[1])
    print(readiness_frame(port=port, process_id=os.getpid(), instance_id=instance_id), flush=True)
    # The startup frame is the only stdout protocol message. Route any later incidental
    # output to stderr; application logging remains in the configured local log file.
    sys.stdout = sys.stderr
    config = uvicorn.Config(
        app,
        loop="asyncio",
        http="h11",
        log_config=None,
        log_level="warning",
        access_log=False,
    )
    server = uvicorn.Server(config)

    def request_shutdown() -> None:
        provider.request_shutdown()
        server.should_exit = True

    app.state.shutdown_callback = request_shutdown
    try:
        server.run(sockets=[listener])
    finally:
        listener.close()


if __name__ == "__main__":
    multiprocessing.freeze_support()
    main()
