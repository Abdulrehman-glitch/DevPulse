import json
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace

import psutil
from devpulse_core.models import ProjectConfig, ScanRootConfig, Settings
from devpulse_core.services import system_monitor
from devpulse_core.services.health_score import HealthScoreService
from devpulse_core.services.project_discovery import ProjectDiscovery
from devpulse_core.services.system_monitor import SystemMonitor
from devpulse_core.services.technology_detector import TechnologyDetector
from git import Repo


def test_discovery_is_bounded_and_ignores_dependency_folders(tmp_path: Path) -> None:
    root = tmp_path / "root"
    visible = root / "team" / "repository"
    Repo.init(visible)
    Repo.init(root / "node_modules" / "dependency")
    Repo.init(root / ".hidden" / "secret")
    settings = Settings(
        scan_roots=[ScanRootConfig(path=root, recursive=True)], maximum_scan_depth=3
    )
    assert {item.path for item in ProjectDiscovery(settings).discover()} == {visible}


def test_invalid_explicit_path_is_retained(tmp_path: Path) -> None:
    missing = tmp_path / "missing"
    settings = Settings(projects=[ProjectConfig(name="Missing", path=missing)])
    assert ProjectDiscovery(settings).discover()[0].path == missing


def test_technology_detection_reads_only_bounded_public_manifests(tmp_path: Path) -> None:
    (tmp_path / "pyproject.toml").write_text(
        '[project]\ndependencies=["fastapi", "psycopg", "pytest"]\n', encoding="utf-8"
    )
    (tmp_path / "package.json").write_text(
        json.dumps({"dependencies": {"react": "latest"}, "devDependencies": {"vite": "latest"}}),
        encoding="utf-8",
    )
    (tmp_path / ".env").write_text("SUPER_SECRET=must-not-be-read\n", encoding="utf-8")
    technologies = TechnologyDetector().detect(tmp_path)
    assert {"Python", "FastAPI", "PostgreSQL", "pytest", "Node.js", "React", "Vite"} <= set(
        technologies
    )


def test_large_configuration_file_is_not_read(tmp_path: Path) -> None:
    (tmp_path / "requirements.txt").write_bytes(b"fastapi\n" + b"x" * 300_000)
    assert TechnologyDetector().detect(tmp_path) == ["Python"]


def test_health_score_preserves_transparent_hundred_point_model(tmp_path: Path) -> None:
    for name in (
        "README.md",
        ".gitignore",
        "pyproject.toml",
        ".env.example",
        "LICENSE",
        "Dockerfile",
    ):
        (tmp_path / name).write_text("present\n", encoding="utf-8")
    (tmp_path / "tests").mkdir()
    workflows = tmp_path / ".github" / "workflows"
    workflows.mkdir(parents=True)
    (workflows / "ci.yml").write_text("name: CI\n", encoding="utf-8")
    score, checks = HealthScoreService().calculate(
        tmp_path,
        is_git_repository=True,
        is_clean=True,
        last_commit_date=datetime.now(UTC) - timedelta(days=1),
        technologies=["Python", "Docker"],
    )
    assert score == 100
    assert sum(item.points for item in checks) == 100


def test_system_monitor_keeps_available_metrics(monkeypatch: object, tmp_path: Path) -> None:
    def denied(interval: object = None) -> float:
        raise psutil.AccessDenied(pid=42)

    monkeypatch.setattr(system_monitor.psutil, "cpu_percent", denied)  # type: ignore[attr-defined]
    monkeypatch.setattr(
        system_monitor.psutil, "virtual_memory", lambda: SimpleNamespace(percent=48.0)
    )  # type: ignore[attr-defined]
    monkeypatch.setattr(
        system_monitor.psutil, "disk_usage", lambda path: SimpleNamespace(percent=71.0)
    )  # type: ignore[attr-defined]
    snapshot = SystemMonitor(tmp_path).snapshot()
    assert snapshot.cpu_percent is None
    assert snapshot.memory_percent == 48.0
    assert snapshot.disk_percent == 71.0
