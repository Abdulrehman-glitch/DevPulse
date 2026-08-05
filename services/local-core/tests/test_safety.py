import hashlib
import json
import threading
from pathlib import Path

import pytest
from devpulse_core.models import ProjectConfig, ScanRootConfig, Settings
from devpulse_core.providers.local import LocalDataProvider, project_id
from devpulse_core.services.path_safety import UnsafeProjectPath, validate_selected_path
from devpulse_core.services.project_discovery import ProjectDiscovery
from devpulse_core.services.repository_scanner import RepositoryScanner
from devpulse_core.test_lab import generate_test_lab
from git import Actor, Repo


def _make_repository(path: Path) -> Repo:
    repo = Repo.init(path, initial_branch="main")
    source = path / "tracked.txt"
    source.write_text("immutable fixture\n", encoding="utf-8")
    repo.index.add(["tracked.txt"])
    actor = Actor("DevPulse Test", "test@invalid.local")
    repo.index.commit("Initial", author=actor, committer=actor)
    return repo


def _fingerprint(root: Path) -> dict[str, tuple[int, str]]:
    result: dict[str, tuple[int, str]] = {}
    for path in root.rglob("*"):
        if path.is_file():
            payload = path.read_bytes()
            result[str(path.relative_to(root))] = (
                len(payload),
                hashlib.sha256(payload).hexdigest(),
            )
    return result


def test_scanning_refresh_and_registration_removal_are_read_only(
    settings_store, tmp_path: Path
) -> None:
    root = tmp_path / "external-fixture"
    repo = _make_repository(root)
    before_status = repo.git.status("--porcelain=v1", "--untracked-files=all")
    before_files = _fingerprint(root)
    settings_store.save(Settings(projects=[ProjectConfig(name="Fixture", path=root)]))
    provider = LocalDataProvider(settings_store)
    provider.refresh(force=True)
    provider.refresh(force=True)
    assert provider.project(project_id(root)) is not None
    provider.remove_project(project_id(root))
    assert _fingerprint(root) == before_files
    assert repo.git.status("--porcelain=v1", "--untracked-files=all") == before_status


def test_path_boundaries_reject_root_traversal_app_data_and_reparse(
    app_paths, tmp_path: Path
) -> None:
    with pytest.raises(UnsafeProjectPath, match="roots"):
        validate_selected_path(Path(tmp_path.anchor), app_data=app_paths.data)
    child = tmp_path / "child"
    child.mkdir()
    with pytest.raises(UnsafeProjectPath, match="traversal"):
        validate_selected_path(child / ".." / "child", app_data=app_paths.data)
    app_paths.ensure()
    with pytest.raises(UnsafeProjectPath, match="protected"):
        validate_selected_path(app_paths.data, app_data=app_paths.data)
    link = tmp_path / "link"
    try:
        link.symlink_to(child, target_is_directory=True)
    except OSError:
        return
    with pytest.raises(UnsafeProjectPath, match="Junction"):
        validate_selected_path(link, app_data=app_paths.data)


def test_registered_project_open_path_rechecks_reparse_boundaries(
    settings_store, tmp_path: Path
) -> None:
    registered = tmp_path / "registered"
    repository = _make_repository(registered)
    repository.close()
    settings_store.save(Settings(projects=[ProjectConfig(name="Registered", path=registered)]))
    provider = LocalDataProvider(settings_store)
    identifier = project_id(registered)
    assert provider.registered_project_path(identifier) == registered.resolve()

    moved = tmp_path / "moved-registered"
    registered.rename(moved)
    try:
        registered.symlink_to(moved, target_is_directory=True)
    except OSError:
        moved.rename(registered)
        return
    with pytest.raises(UnsafeProjectPath, match="Junction"):
        provider.registered_project_path(identifier)


def test_discovery_depth_result_and_cancellation_limits(tmp_path: Path) -> None:
    root = tmp_path / "root"
    _make_repository(root / "a")
    _make_repository(root / "b")
    _make_repository(root / "deep" / "one" / "two" / "three")
    settings = Settings(
        scan_roots=[ScanRootConfig(path=root)],
        maximum_scan_depth=2,
        maximum_repositories_per_root=1,
    )
    assert len(ProjectDiscovery(settings).discover()) == 1
    cancel = threading.Event()
    cancel.set()
    projects = [ProjectConfig(name="a", path=root / "a")]
    assert RepositoryScanner(cache_duration_seconds=0).scan_all(projects, cancel_event=cancel) == []


def test_test_lab_stays_in_owned_application_data(app_paths) -> None:
    fixtures = generate_test_lab(app_paths)
    assert {"clean", "modified", "staged", "untracked", "detached", "missing"} <= fixtures.keys()
    for path in fixtures.values():
        assert path.is_relative_to(app_paths.test_lab)


def test_known_external_project_paths_never_appear_in_test_configuration() -> None:
    root = Path(__file__).resolve().parents[3]
    configuration_files = [
        root / "pyproject.toml",
        root / "package.json",
        root / "apps" / "desktop" / "vite.config.ts",
        root / "services" / "local-core" / "tests" / "conftest.py",
    ]
    forbidden = [
        "C:\\" + "SentinelX",
        "C:\\" + "InsightEdge",
        "C:\\" + "HyMedia",
    ]
    payload = "\n".join(path.read_text(encoding="utf-8") for path in configuration_files)
    assert all(item not in payload for item in forbidden)


def test_activity_file_is_isolated_and_clear_does_not_touch_cache(settings_store) -> None:
    provider = LocalDataProvider(settings_store)
    cache = settings_store.paths.cache / "sentinel.json"
    cache.write_text(json.dumps({"keep": True}), encoding="utf-8")
    assert provider.activity()
    provider.clear_activity()
    assert provider.activity() == []
    assert json.loads(cache.read_text(encoding="utf-8")) == {"keep": True}
