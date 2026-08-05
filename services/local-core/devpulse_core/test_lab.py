"""Deterministic artificial repositories confined to a DevPulse QA root."""

from __future__ import annotations

import json
import os
import shutil
import stat
from pathlib import Path

from git import Actor, Repo

from devpulse_core.models import ProjectConfig, Settings
from devpulse_core.paths import AppPaths

_ACTOR = Actor("DevPulse QA", "qa@invalid.local")
_MANIFEST_VERSION = 2


def generate_test_lab(paths: AppPaths | None = None) -> dict[str, Path]:
    """Create small, realistic repositories only below ``paths.test_lab``."""
    app_paths = paths or AppPaths.resolve()
    root = validate_test_lab_target(app_paths.test_lab, app_paths.data)
    if root.exists():
        reset_test_lab(app_paths)
    root.mkdir(parents=True, exist_ok=False)

    fixtures: dict[str, Path] = {}
    fixtures["clean"] = _python_project(root / "clean-python")
    fixtures["modified"] = _fastapi_project(root / "modified-fastapi")
    (fixtures["modified"] / "app" / "main.py").write_text(
        'from fastapi import FastAPI\n\napp = FastAPI(title="QA modified")\n', encoding="utf-8"
    )
    fixtures["react"] = _react_project(root / "react-typescript-dashboard")
    fixtures["staged"] = _repository(root / "staged-changes", {"README.md": "# Staged\n"})
    _write(fixtures["staged"] / "src" / "staged.py", "STAGED = True\n")
    with Repo(fixtures["staged"]) as staged_repo:
        staged_repo.index.add(["src/staged.py"])
    fixtures["untracked"] = _repository(root / "untracked-files", {"README.md": "# Untracked\n"})
    _write(fixtures["untracked"] / "notes" / "local.txt", "Artificial untracked note.\n")
    fixtures["ahead"] = _tracking_project(root, "ahead-local", ahead=True)
    fixtures["behind"] = _tracking_project(root, "behind-local", behind=True)
    fixtures["detached"] = _repository(root / "detached-head", {"README.md": "# Detached\n"})
    with Repo(fixtures["detached"]) as detached_repo:
        detached_repo.git.checkout("--detach")
    fixtures["no_remote"] = _repository(
        root / "no-remote",
        {"README.md": "# Local only\n", "tests/test_local.py": "def test_ok():\n    assert True\n"},
    )
    fixtures["complete"] = _complete_project(root / "well-documented-service")
    fixtures["low_health"] = _repository(root / "low-health", {"scratch.txt": "prototype\n"})
    fixtures["ignored"] = _ignored_project(root / "ignored-dependencies")
    fixtures["nested_parent"] = _repository(
        root / "nested-boundary", {"README.md": "# Parent repository\n", ".gitignore": "child/\n"}
    )
    fixtures["nested"] = _repository(
        fixtures["nested_parent"] / "child", {"README.md": "# Nested child\n"}
    )
    fixtures["invalid"] = root / "access-error-simulation"
    fixtures["invalid"].mkdir()
    (fixtures["invalid"] / ".git").write_text(
        "gitdir: Z:/devpulse-qa-intentionally-missing\n", encoding="utf-8"
    )
    fixtures["missing"] = root / "missing-repository"

    manifest = {
        "version": _MANIFEST_VERSION,
        "artificial": True,
        "fixtures": {name: str(path.relative_to(root)) for name, path in fixtures.items()},
    }
    (root / "qa-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return fixtures


def qa_settings(paths: AppPaths, fixtures: dict[str, Path]) -> Settings:
    """Return settings that register only artificial QA fixture paths."""
    order = [
        "clean",
        "modified",
        "react",
        "staged",
        "untracked",
        "ahead",
        "behind",
        "detached",
        "no_remote",
        "complete",
        "low_health",
        "ignored",
        "nested_parent",
        "invalid",
        "missing",
    ]
    lab = validate_test_lab_target(paths.test_lab, paths.data)
    projects = []
    for key in order:
        path = fixtures[key]
        if not _lexically_within(path, lab):
            raise RuntimeError("QA fixture escaped the artificial test-lab boundary.")
        projects.append(ProjectConfig(name=_display_name(key), path=path))
    return Settings(
        onboarding_completed=True,
        projects=projects,
        scan_roots=[],
        refresh_interval_seconds=0,
        appearance="light",
    )


def reset_test_lab(paths: AppPaths, target: Path | None = None) -> None:
    """Delete only the validated QA test-lab directory."""
    root = validate_test_lab_target(target or paths.test_lab, paths.data)
    if not root.exists():
        return
    if root.is_symlink() or _has_reparse_component(root, paths.data):
        raise RuntimeError("QA reset refused a symbolic-link or junction boundary.")
    if (root / ".git").exists():
        raise RuntimeError("QA reset refused a source-controlled directory.")
    _remove_tree(root)


def validate_test_lab_target(target: Path, qa_root: Path) -> Path:
    raw = str(target).strip()
    if not raw or not target.is_absolute():
        raise RuntimeError("QA test-lab path must be a non-empty absolute path.")
    if any(part == ".." for part in target.parts):
        raise RuntimeError("QA test-lab path cannot contain parent traversal.")
    qa = qa_root.resolve(strict=False)
    if qa == Path(qa.anchor):
        raise RuntimeError("QA root cannot be a filesystem root.")
    expected = qa / "test-lab"
    resolved = target.resolve(strict=False)
    if resolved != expected or resolved == qa:
        raise RuntimeError("QA reset target must be the test-lab directly below the QA root.")
    if not _lexically_within(resolved, qa):
        raise RuntimeError("QA reset target is outside the QA root.")
    if (resolved / ".git").exists():
        raise RuntimeError("QA reset target cannot be source controlled.")
    return resolved


def manifest_is_valid(paths: AppPaths) -> bool:
    try:
        root = validate_test_lab_target(paths.test_lab, paths.data)
        payload = json.loads((root / "qa-manifest.json").read_text(encoding="utf-8"))
        return payload.get("version") == _MANIFEST_VERSION and payload.get("artificial") is True
    except (OSError, ValueError, TypeError, json.JSONDecodeError, RuntimeError):
        return False


def _python_project(path: Path) -> Path:
    return _repository(
        path,
        {
            "README.md": "# Clean Python QA fixture\n",
            "pyproject.toml": '[project]\nname = "qa-clean-python"\nversion = "1.0.0"\n',
            "src/qa_clean/__init__.py": "VALUE = 1\n",
            "tests/test_clean.py": "def test_value():\n    assert 1 == 1\n",
            ".github/workflows/ci.yml": "name: CI\non: [push]\njobs: {}\n",
        },
    )


def _fastapi_project(path: Path) -> Path:
    return _repository(
        path,
        {
            "README.md": "# FastAPI service\n",
            "pyproject.toml": (
                '[project]\nname = "qa-fastapi"\nversion = "1.0.0"\ndependencies = ["fastapi"]\n'
            ),
            "app/main.py": "from fastapi import FastAPI\n\napp = FastAPI()\n",
            "tests/test_api.py": "def test_placeholder():\n    assert True\n",
            "Dockerfile": "FROM python:3.12-slim\n",
        },
    )


def _react_project(path: Path) -> Path:
    return _repository(
        path,
        {
            "README.md": "# React TypeScript QA fixture\n",
            "package.json": json.dumps(
                {"name": "qa-react", "private": True, "dependencies": {"react": "19.0.0"}},
                indent=2,
            )
            + "\n",
            "tsconfig.json": '{"compilerOptions":{"strict":true}}\n',
            "src/App.tsx": "export function App() { return <main>QA fixture</main>; }\n",
            "src/App.test.tsx": "// Artificial test fixture.\n",
        },
    )


def _complete_project(path: Path) -> Path:
    return _repository(
        path,
        {
            "README.md": "# Documented service\n",
            "pyproject.toml": '[project]\nname = "qa-documented"\nversion = "2.0.0"\n',
            "tests/test_service.py": "def test_service():\n    assert True\n",
            ".github/workflows/ci.yml": "name: CI\non: [push]\njobs: {}\n",
            "Dockerfile": "FROM python:3.12-slim\n",
            "LICENSE": "Artificial QA fixture license.\n",
            ".gitignore": "__pycache__/\n",
        },
    )


def _ignored_project(path: Path) -> Path:
    result = _repository(
        path,
        {
            "README.md": "# Ignored dependency boundaries\n",
            ".gitignore": "node_modules/\n.venv/\n",
            "package.json": '{"name":"qa-ignored","private":true}\n',
        },
    )
    _write(result / "node_modules" / "artificial-package" / "index.js", "module.exports = {};\n")
    _write(result / ".venv" / "marker.txt", "Artificial; never executed.\n")
    return result


def _tracking_project(root: Path, name: str, *, ahead: bool = False, behind: bool = False) -> Path:
    remote_path = root / "remotes" / f"{name}.git"
    remote_path.parent.mkdir(parents=True, exist_ok=True)
    remote_repo = Repo.init(remote_path, bare=True)
    remote_repo.close()
    project = _repository(root / name, {"README.md": f"# {name}\n"})
    repo = Repo(project)
    repo.create_remote("origin", str(remote_path))
    repo.git.push("--set-upstream", "origin", "main")
    if ahead:
        _write(project / "ahead.txt", "Artificial local-only commit.\n")
        repo.index.add(["ahead.txt"])
        repo.index.commit("Local commit ahead of origin", author=_ACTOR, committer=_ACTOR)
    if behind:
        builder = root / "builders" / f"{name}-updater"
        updater = Repo.clone_from(str(remote_path), builder, branch="main")
        _write(builder / "remote.txt", "Artificial remote-only commit.\n")
        updater.index.add(["remote.txt"])
        updater.index.commit("Remote commit ahead of local", author=_ACTOR, committer=_ACTOR)
        updater.git.push("origin", "main")
        updater.close()
        _remove_tree(builder)
        repo.remotes.origin.fetch()
    repo.close()
    return project


def _repository(path: Path, files: dict[str, str]) -> Path:
    path.mkdir(parents=True, exist_ok=False)
    repo = Repo.init(path, initial_branch="main")
    for relative, content in files.items():
        _write(path / relative, content)
    repo.index.add(list(files))
    repo.index.commit("Initial artificial QA commit", author=_ACTOR, committer=_ACTOR)
    repo.close()
    return path


def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def _display_name(key: str) -> str:
    return {
        "clean": "Clean Python Service",
        "modified": "Modified FastAPI Service",
        "react": "React TypeScript Dashboard With A Deliberately Long QA Name",
        "staged": "Staged Changes",
        "untracked": "Untracked Files",
        "ahead": "Ahead Of Local Bare Remote",
        "behind": "Behind Local Bare Remote",
        "detached": "Detached HEAD",
        "no_remote": "Repository Without Remote",
        "complete": "Documented CI Docker Service",
        "low_health": "Low Health Prototype",
        "ignored": "Ignored Dependencies",
        "nested_parent": "Nested Repository Boundary",
        "invalid": "Access Error Simulation",
        "missing": "Missing Repository Entry",
    }[key]


def _lexically_within(path: Path, root: Path) -> bool:
    try:
        path.resolve(strict=False).relative_to(root.resolve(strict=False))
        return True
    except ValueError:
        return False


def _has_reparse_component(path: Path, root: Path) -> bool:
    current = root.resolve(strict=False)
    try:
        relative = path.resolve(strict=False).relative_to(current)
    except ValueError:
        return True
    for part in relative.parts:
        current /= part
        try:
            metadata = current.lstat()
        except OSError:
            continue
        attributes = getattr(metadata, "st_file_attributes", 0)
        if current.is_symlink() or attributes & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0):
            return True
    return False


def _remove_tree(path: Path) -> None:
    def remove_readonly(function, item: str, _: object) -> None:  # type: ignore[no-untyped-def]
        os.chmod(item, stat.S_IWRITE)
        function(item)

    shutil.rmtree(path, onexc=remove_readonly)
