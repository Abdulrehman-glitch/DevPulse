from pathlib import Path

from devpulse_core.config import SettingsStore
from devpulse_core.models import ProjectConfig, Settings
from devpulse_core.providers.local import LocalDataProvider, project_id
from git import Repo


def test_local_provider_refreshes_temporary_repository(
    settings_store: SettingsStore, tmp_path: Path
) -> None:
    root = tmp_path / "project"
    repo = Repo.init(root, initial_branch="main")
    (root / "README.md").write_text("# Project\n", encoding="utf-8")
    repo.index.add(["README.md"])
    repo.index.commit("Initial")
    settings_store.save(Settings(projects=[ProjectConfig(name="Project", path=root)]))
    provider = LocalDataProvider(settings_store)
    items = provider.refresh()
    assert len(items) == 1
    assert provider.project(project_id(root)) is not None
    assert provider.last_refresh is not None
    assert provider.activity()[0].kind == "success"
    assert (settings_store.paths.cache / "repositories-v1.json").exists()


def test_provider_accepts_invalid_project_path_as_state(
    settings_store: SettingsStore, tmp_path: Path
) -> None:
    missing = tmp_path / "missing"
    settings_store.save(Settings(projects=[ProjectConfig(name="Missing", path=missing)]))
    result = LocalDataProvider(settings_store).refresh()[0]
    assert result.status == "missing"


def test_provider_cancels_refresh_between_repositories(
    settings_store: SettingsStore, tmp_path: Path
) -> None:
    projects = []
    for index in range(3):
        root = tmp_path / f"project-{index}"
        Repo.init(root, initial_branch="main")
        projects.append(ProjectConfig(name=root.name, path=root))
    settings_store.save(Settings(projects=projects))
    provider = LocalDataProvider(settings_store)
    provider.request_shutdown()

    assert provider.refresh() == []
