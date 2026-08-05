import argparse
import json
import threading
import time
from pathlib import Path

import pytest
from devpulse_core.config import SettingsStore
from devpulse_core.diagnostics import build_safe_diagnostics, export_safe_diagnostics, redact_text
from devpulse_core.main import resolve_runtime_paths, write_qa_path_report
from devpulse_core.models import ProjectConfig, Settings
from devpulse_core.paths import AppPaths
from devpulse_core.providers.local import LocalDataProvider
from devpulse_core.test_lab import (
    generate_test_lab,
    manifest_is_valid,
    reset_test_lab,
    validate_test_lab_target,
)


def test_qa_provider_generates_representative_artificial_git_states(tmp_path: Path) -> None:
    paths = AppPaths.resolve(tmp_path / ".qa-runtime")
    provider = LocalDataProvider(SettingsStore(paths), qa_mode=True)
    repositories = provider.refresh(force=True)
    by_name = {item.project.name: item for item in repositories}

    assert len(repositories) == 15
    assert by_name["Clean Python Service"].status == "clean"
    assert by_name["Modified FastAPI Service"].modified_count == 1
    assert by_name["Staged Changes"].staged_count == 1
    assert by_name["Untracked Files"].untracked_count == 1
    assert by_name["Ahead Of Local Bare Remote"].ahead_count == 1
    assert by_name["Behind Local Bare Remote"].behind_count == 1
    assert by_name["Detached HEAD"].detached_head is True
    assert by_name["Missing Repository Entry"].status == "missing"
    assert all(item.project.path.is_relative_to(paths.test_lab) for item in repositories)
    assert manifest_is_valid(paths)


def test_python_qa_path_report_contains_only_the_canonical_qa_root(tmp_path: Path) -> None:
    root = tmp_path / "DevPulse-QA-python-paths"
    paths = AppPaths.resolve_qa(root, root)
    paths.ensure()
    report_path = write_qa_path_report(paths)
    report = json.loads(report_path.read_text(encoding="utf-8"))

    assert report["qaRoot"] == str(paths.data)
    assert report["allWritablePathsUnderQaRoot"] is True
    for key in (
        "pythonLocalCoreConfigurationDirectory",
        "pythonCacheDirectory",
        "pythonLogDirectory",
        "qaRepositoryDirectory",
        "diagnosticsExportDirectory",
        "activityStorage",
    ):
        assert Path(report[key]).is_relative_to(paths.data)


def test_python_qa_resolution_requires_one_canonical_explicit_root(tmp_path: Path) -> None:
    root = tmp_path / "DevPulse-QA-python-paths"
    paths = AppPaths.resolve_qa(root, root)
    assert paths.data == root.resolve()
    assert paths.cache.is_relative_to(paths.data)
    assert paths.logs.is_relative_to(paths.data)
    assert paths.activity.is_relative_to(paths.data)
    assert paths.test_lab.is_relative_to(paths.data)

    with pytest.raises(ValueError, match="explicit data"):
        AppPaths.resolve_qa(None, root)
    with pytest.raises(ValueError, match="DEVPULSE_QA_ROOT"):
        AppPaths.resolve_qa(root)
    with pytest.raises(ValueError, match="does not match"):
        AppPaths.resolve_qa(root, tmp_path / "DevPulse-QA-other")
    with pytest.raises(ValueError, match="parent traversal"):
        AppPaths.resolve_qa(root / "folder" / ".." / "DevPulse-QA-escape", root)
    with pytest.raises(ValueError, match="filesystem root"):
        AppPaths.validate_qa_root(Path(tmp_path.anchor))


def test_python_qa_resolution_rejects_link_escape_where_supported(tmp_path: Path) -> None:
    outside = tmp_path / "outside"
    outside.mkdir()
    linked_root = tmp_path / "DevPulse-QA-linked"
    try:
        linked_root.symlink_to(outside, target_is_directory=True)
    except OSError:
        pytest.skip("Creating directory links is unavailable for this account")
    with pytest.raises(ValueError, match="symbolic link or junction"):
        AppPaths.resolve_qa(linked_root, linked_root)


def test_python_sidecar_refuses_partial_qa_environment(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    root = tmp_path / "DevPulse-QA-sidecar"
    args = argparse.Namespace(qa_mode=True, data_dir=root)
    for name in (
        "DEVPULSE_QA_MODE",
        "DEVPULSE_INSTALL_QA",
        "DEVPULSE_QA_AUTOMATION",
        "DEVPULSE_QA_FAIL_START",
        "DEVPULSE_QA_ROOT",
        "DEVPULSE_DATA_DIR",
        "APPDATA",
        "LOCALAPPDATA",
        "WEBVIEW2_USER_DATA_FOLDER",
    ):
        monkeypatch.delenv(name, raising=False)

    monkeypatch.setenv("DEVPULSE_QA_MODE", "1")
    with pytest.raises(ValueError, match="DEVPULSE_QA_ROOT"):
        resolve_runtime_paths(args)

    monkeypatch.setenv("DEVPULSE_INSTALL_QA", "1")
    monkeypatch.setenv("DEVPULSE_QA_ROOT", str(root))
    monkeypatch.setenv("DEVPULSE_DATA_DIR", str(root))
    with pytest.raises(ValueError, match="APPDATA"):
        resolve_runtime_paths(args)

    monkeypatch.setenv("APPDATA", str(root / "process-env" / "roaming"))
    monkeypatch.setenv("LOCALAPPDATA", str(root / "process-env" / "local"))
    monkeypatch.setenv(
        "WEBVIEW2_USER_DATA_FOLDER",
        str(root / "webview2"),
    )
    assert resolve_runtime_paths(args).data == root.resolve()


def test_normal_python_path_resolution_is_unchanged(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    configured = tmp_path / "production-data"
    monkeypatch.setenv("DEVPULSE_DATA_DIR", str(configured))
    assert AppPaths.resolve().data == configured.resolve()


def test_qa_reset_is_deterministic_and_refuses_unsafe_targets(tmp_path: Path) -> None:
    paths = AppPaths.resolve(tmp_path / ".qa-runtime")
    first = generate_test_lab(paths)
    assert first["clean"].exists()
    reset_test_lab(paths)
    assert not paths.test_lab.exists()
    second = generate_test_lab(paths)
    assert sorted(second) == sorted(first)

    with pytest.raises(RuntimeError, match="absolute"):
        validate_test_lab_target(Path(""), paths.data)
    with pytest.raises(RuntimeError, match="parent traversal"):
        validate_test_lab_target(paths.data / "folder" / ".." / "test-lab", paths.data)
    with pytest.raises(RuntimeError, match="directly below"):
        validate_test_lab_target(tmp_path / "outside", paths.data)
    (paths.test_lab / ".git").mkdir(exist_ok=True)
    with pytest.raises(RuntimeError, match="source controlled"):
        reset_test_lab(paths)


def test_qa_reset_rejects_symlink_escape_where_supported(tmp_path: Path) -> None:
    paths = AppPaths.resolve(tmp_path / ".qa-runtime")
    paths.data.mkdir(parents=True)
    outside = tmp_path / "outside"
    outside.mkdir()
    try:
        paths.test_lab.symlink_to(outside, target_is_directory=True)
    except OSError:
        pytest.skip("Creating directory links is unavailable for this account")
    with pytest.raises(RuntimeError):
        reset_test_lab(paths)
    assert outside.exists()


def test_qa_mode_never_reads_or_changes_production_configuration(tmp_path: Path) -> None:
    production_paths = AppPaths.resolve(tmp_path / "production-data")
    production_store = SettingsStore(production_paths)
    production_store.save(
        Settings(projects=[ProjectConfig(name="Production sentinel", path=tmp_path / "real")])
    )
    before = production_paths.settings.read_bytes()

    qa_paths = AppPaths.resolve(tmp_path / ".qa-runtime")
    provider = LocalDataProvider(SettingsStore(qa_paths), qa_mode=True)

    assert provider.qa_mode is True
    assert all(item.path.is_relative_to(qa_paths.test_lab) for item in provider.settings().projects)
    assert production_paths.settings.read_bytes() == before
    assert "Production sentinel" not in qa_paths.settings.read_text(encoding="utf-8")


def test_safe_diagnostics_redacts_tokens_credentials_urls_and_paths(tmp_path: Path) -> None:
    log = tmp_path / "local-core.log"
    secret = "0123456789abcdef0123456789abcdef"
    log.write_text(
        json.dumps(
            {
                "level": "ERROR",
                "message": (
                    f"token={secret} password=hunter2 https://user:pass@example.invalid/repo "
                    r"C:\Users\Private\Documents\thesis.docx"
                ),
            }
        )
        + "\n",
        encoding="utf-8",
    )
    payload = build_safe_diagnostics(
        qa_mode=True,
        data_root=tmp_path,
        schema_version=4,
        project_count=15,
        cache_status="ready",
        last_scan_status="completed",
        recent_error_codes=["token=another-secret"],
        startup_duration_ms=42,
        log_path=log,
    )
    exported = export_safe_diagnostics(payload)
    assert secret not in exported
    assert "hunter2" not in exported
    assert "user:pass" not in exported
    assert "thesis.docx" not in exported
    assert "<redacted>" in exported
    assert "<remote-url>" in exported
    assert redact_text("Authorization: bearer-value") == "Authorization: <redacted>"


def test_invalid_qa_settings_manifest_and_cache_recover_inside_qa_root(tmp_path: Path) -> None:
    paths = AppPaths.resolve(tmp_path / ".qa-runtime")
    paths.ensure()
    paths.settings.write_text("{invalid", encoding="utf-8")
    paths.test_lab.mkdir()
    (paths.test_lab / "qa-manifest.json").write_text("[]", encoding="utf-8")
    cache = paths.cache / "repositories-v1.json"
    cache.write_text("not-json", encoding="utf-8")

    provider = LocalDataProvider(SettingsStore(paths), qa_mode=True)
    repositories = provider.refresh(force=True)

    assert len(repositories) == 15
    assert manifest_is_valid(paths)
    assert json.loads(paths.settings.read_text(encoding="utf-8"))["onboarding_completed"] is True
    assert json.loads(cache.read_text(encoding="utf-8"))["version"] == 1


def test_qa_reset_waits_for_active_repository_scan(tmp_path: Path) -> None:
    paths = AppPaths.resolve(tmp_path / ".qa-runtime")
    provider = LocalDataProvider(SettingsStore(paths), qa_mode=True)
    scan_started = threading.Event()
    allow_scan = threading.Event()
    reset_finished = threading.Event()
    original_scan_all = provider._scanner.scan_all

    def delayed_scan(*args: object, **kwargs: object):  # type: ignore[no-untyped-def]
        scan_started.set()
        assert allow_scan.wait(timeout=5)
        return original_scan_all(*args, **kwargs)

    def reset_lab() -> None:
        provider.reset_qa_data()
        reset_finished.set()

    provider._scanner.scan_all = delayed_scan  # type: ignore[method-assign]
    refresh_thread = threading.Thread(target=provider.refresh)
    reset_thread = threading.Thread(target=reset_lab)
    refresh_thread.start()
    assert scan_started.wait(timeout=2)
    reset_thread.start()
    time.sleep(0.1)
    assert not reset_finished.is_set()

    allow_scan.set()
    refresh_thread.join(timeout=10)
    reset_thread.join(timeout=10)

    assert reset_finished.is_set()
    assert not paths.test_lab.exists()
