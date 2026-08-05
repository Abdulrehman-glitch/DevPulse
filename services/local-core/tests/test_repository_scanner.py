import os
import time
from pathlib import Path

from devpulse_core.models import ProjectConfig
from devpulse_core.services.repository_scanner import RepositoryScanner
from git import Repo


def config(path: Path) -> ProjectConfig:
    return ProjectConfig(name=path.name, path=path)


def fingerprint(root: Path) -> dict[str, tuple[int, int]]:
    return {
        str(path.relative_to(root)): (path.stat().st_size, path.stat().st_mtime_ns)
        for path in root.rglob("*")
        if path.is_file()
    }


def test_missing_and_non_git_paths_are_data(tmp_path: Path) -> None:
    missing = RepositoryScanner().scan(config(tmp_path / "missing"))
    normal = tmp_path / "notes"
    normal.mkdir()
    not_git = RepositoryScanner().scan(config(normal))
    assert missing.status == "missing"
    assert not_git.status == "not_git"


def test_repository_snapshot_includes_git_technology_and_health(tmp_path: Path) -> None:
    root = tmp_path / "api"
    repo = Repo.init(root, initial_branch="main")
    (root / "pyproject.toml").write_text(
        '[project]\nname="api"\ndependencies=["fastapi", "pytest"]\n', encoding="utf-8"
    )
    repo.index.add(["pyproject.toml"])
    repo.index.commit("Add API metadata")
    result = RepositoryScanner(cache_duration_seconds=0).scan(config(root))
    assert result.branch == "main"
    assert result.is_clean is True
    assert result.commits[0].message == "Add API metadata"
    assert result.primary_technology == "FastAPI"


def test_changed_files_are_counted_once(tmp_path: Path) -> None:
    root = tmp_path / "changed"
    repo = Repo.init(root, initial_branch="main")
    tracked = root / "tracked.txt"
    tracked.write_text("one\n", encoding="utf-8")
    repo.index.add(["tracked.txt"])
    repo.index.commit("Initial")
    tracked.write_text("two\n", encoding="utf-8")
    (root / "new.txt").write_text("new\n", encoding="utf-8")
    result = RepositoryScanner(cache_duration_seconds=0).scan(config(root))
    assert result.changed_files == 2
    assert result.status == "modified"


def test_porcelain_parser_preserves_states() -> None:
    modified, staged, untracked = RepositoryScanner.parse_porcelain_status(
        " M modified.py\nM  staged.py\n?? new.py\nMM both.py\nR  old.py -> renamed.py"
    )
    assert modified == ["both.py", "modified.py"]
    assert staged == ["both.py", "renamed.py", "staged.py"]
    assert untracked == ["new.py"]


def test_external_repository_remains_byte_and_metadata_unchanged(tmp_path: Path) -> None:
    root = tmp_path / "external-read-only-fixture"
    repo = Repo.init(root, initial_branch="main")
    source = root / "file.txt"
    source.write_text("content\n", encoding="utf-8")
    repo.index.add(["file.txt"])
    repo.index.commit("Initial")
    before_head = repo.head.commit.hexsha
    before_branch = repo.active_branch.name
    before_remote = list(repo.remotes)
    before = fingerprint(root)
    time.sleep(0.01)
    RepositoryScanner(cache_duration_seconds=0).scan(config(root))
    after = fingerprint(root)
    assert repo.head.commit.hexsha == before_head
    assert repo.active_branch.name == before_branch
    assert list(repo.remotes) == before_remote
    assert after == before
    assert os.environ.get("GIT_OPTIONAL_LOCKS") is None
