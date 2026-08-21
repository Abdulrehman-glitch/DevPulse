import os
from pathlib import Path

import pytest
from devpulse_core.models import ProjectConfig, ScanRootConfig, Settings
from devpulse_core.services import project_discovery as discovery_module
from devpulse_core.services.path_safety import UnsafeProjectPath, validate_selected_path
from devpulse_core.services.project_discovery import ProjectDiscovery
from devpulse_core.services.repository_scanner import RepositoryScanner
from devpulse_core.services.technology_detector import TechnologyDetector
from git import Repo


def _discover(root: Path, app_data: Path, **limits: int) -> ProjectDiscovery:
    settings = Settings(scan_roots=[ScanRootConfig(path=root)], **limits)
    discovery = ProjectDiscovery(settings, app_data=app_data)
    discovery.discover()
    return discovery


def test_scanner_handles_spaces_unicode_and_excluded_generated_directories(tmp_path: Path) -> None:
    root = tmp_path / "Workspace with spaces Ünicode"
    visible = root / "team" / "résumé-project"
    Repo.init(visible)
    for excluded in ("node_modules", "target", "dist", "build", ".venv"):
        Repo.init(root / excluded / "must-not-be-seen")
    settings = Settings(scan_roots=[ScanRootConfig(path=root)], maximum_scan_depth=4)
    result = ProjectDiscovery(settings, app_data=tmp_path / "app-data").discover()
    assert {item.path for item in result} == {visible.resolve()}


def test_scanner_entry_budget_stops_a_large_synthetic_tree(tmp_path: Path) -> None:
    root = tmp_path / "large-tree"
    for index in range(150):
        (root / f"directory-{index:03d}").mkdir(parents=True)
    discovery = _discover(
        root,
        tmp_path / "app-data",
        maximum_entries_per_scan=100,
        maximum_directories_per_scan=500,
    )
    assert "scan_entry_limit" in discovery.diagnostic_codes


def test_scanner_refuses_home_and_application_data_roots(tmp_path: Path) -> None:
    app_data = tmp_path / "DevPulse-data"
    app_data.mkdir()
    with pytest.raises(UnsafeProjectPath, match="protected"):
        validate_selected_path(app_data, app_data=app_data)
    with pytest.raises(UnsafeProjectPath, match="protected"):
        validate_selected_path(Path.home(), app_data=app_data)


def test_symlink_or_reparse_escape_is_not_traversed_when_supported(tmp_path: Path) -> None:
    root = tmp_path / "approved"
    outside = tmp_path / "outside"
    root.mkdir()
    Repo.init(outside / "escaped-repository")
    link = root / "linked-outside"
    try:
        link.symlink_to(outside, target_is_directory=True)
    except OSError:
        pytest.skip("Directory links are unavailable for this account")
    result = ProjectDiscovery(
        Settings(scan_roots=[ScanRootConfig(path=root)], maximum_scan_depth=4),
        app_data=tmp_path / "app-data",
    ).discover()
    assert result == []


def test_root_disappearing_during_scan_fails_safely(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    root = tmp_path / "disappearing"
    root.mkdir()
    original = ProjectDiscovery._is_repository

    def remove_root(path: Path) -> bool:
        result = original(path)
        if path == root:
            path.rmdir()
        return result

    monkeypatch.setattr(ProjectDiscovery, "_is_repository", staticmethod(remove_root))
    discovery = _discover(root, tmp_path / "app-data")
    assert "scan_path_changed_or_inaccessible" in discovery.diagnostic_codes


def test_permission_failure_is_an_error_code_not_a_sensitive_path(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    root = tmp_path / "private-name-must-not-leak"
    denied = root / "denied"
    denied.mkdir(parents=True)
    real_scandir = os.scandir

    def deny_selected(path: os.PathLike[str] | str):
        if Path(path) == denied:
            raise PermissionError("injected permission denial")
        return real_scandir(path)

    monkeypatch.setattr(discovery_module.os, "scandir", deny_selected)
    discovery = _discover(root, tmp_path / "app-data")
    assert "scan_path_changed_or_inaccessible" in discovery.diagnostic_codes
    assert str(root) not in caplog.text


def test_tree_mutation_after_queueing_cannot_escape_the_approved_root(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    root = tmp_path / "approved"
    queued = root / "queued"
    outside = tmp_path / "outside"
    queued.mkdir(parents=True)
    Repo.init(outside / "escaped")
    original = ProjectDiscovery._queue_children
    mutated = False

    def mutate_after_queue(self, children, queue, depth, entries_seen):
        nonlocal mutated
        result = original(self, children, queue, depth, entries_seen)
        if not mutated:
            queued.rmdir()
            try:
                queued.symlink_to(outside, target_is_directory=True)
            except OSError:
                pytest.skip("Directory links are unavailable for this account")
            mutated = True
        return result

    monkeypatch.setattr(ProjectDiscovery, "_queue_children", mutate_after_queue)
    discovery = _discover(root, tmp_path / "app-data")
    assert "scan_path_changed_or_inaccessible" in discovery.diagnostic_codes


def test_repository_gitdir_indirection_cannot_leave_the_project_root(tmp_path: Path) -> None:
    project = tmp_path / "project"
    project.mkdir()
    external = tmp_path / "external-metadata"
    Repo.init(external)
    (project / ".git").write_text(f"gitdir: {external / '.git'}\n", encoding="utf-8")

    result = RepositoryScanner(
        cache_duration_seconds=0,
        app_data=tmp_path / "app-data",
    ).scan(ProjectConfig(name="Project", path=project))

    assert result.status == "unsupported_path"
    assert result.error == "Git metadata leaves the approved project boundary."


def test_repository_status_output_is_bounded(tmp_path: Path) -> None:
    project = tmp_path / "bounded-status"
    repository = Repo.init(project, initial_branch="main")
    for index in range(75):
        (project / f"untracked-{index:03d}.txt").write_text("fixture\n", encoding="utf-8")

    result = RepositoryScanner(
        cache_duration_seconds=0,
        app_data=tmp_path / "app-data",
        maximum_changed_paths=50,
    ).scan(ProjectConfig(name="Bounded", path=project))
    repository.close()

    assert result.changed_files == 50
    assert "Changed-path display limit reached" in result.warnings


def test_linked_manifest_and_workflow_metadata_are_not_read_or_enumerated(
    tmp_path: Path,
) -> None:
    project = tmp_path / "project"
    outside = tmp_path / "outside"
    workflows = outside / "workflows"
    project.mkdir()
    workflows.mkdir(parents=True)
    (outside / "package.json").write_text('{"dependencies":{"react":"fixture"}}', encoding="utf-8")
    (workflows / "outside.yml").write_text("name: outside\n", encoding="utf-8")
    (project / ".github").mkdir()
    try:
        (project / "package.json").symlink_to(outside / "package.json")
        (project / ".github" / "workflows").symlink_to(workflows, target_is_directory=True)
    except OSError:
        pytest.skip("Filesystem links are unavailable for this account")

    detector = TechnologyDetector()
    technologies = detector.detect(project)
    assert "React" not in technologies
    assert "GitHub Actions" not in technologies
    assert detector.ci_provider(project) is None
