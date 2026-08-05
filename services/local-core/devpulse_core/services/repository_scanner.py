"""Read-only Git inspection with short-lived in-memory caching."""

from __future__ import annotations

import logging
import os
import threading
import time
from collections.abc import Callable
from contextlib import suppress
from datetime import UTC, datetime
from pathlib import Path
from typing import ClassVar

from git import GitCommandError, InvalidGitRepositoryError, NoSuchPathError, Repo

from devpulse_core.models import CommitInfo, ProjectConfig, RepositoryInfo, WarningFinding
from devpulse_core.services.health_score import HealthScoreService
from devpulse_core.services.path_safety import UnsafeProjectPath, validate_selected_path
from devpulse_core.services.technology_detector import TechnologyDetector

logger = logging.getLogger(__name__)
ProgressCallback = Callable[[int, int, ProjectConfig], None]


class RepositoryScanner:
    """Inspect metadata without changing files, branches, remotes, or the Git index."""

    IMPORTANT_NAMES: ClassVar[set[str]] = {
        "readme.md",
        "readme.rst",
        "readme.txt",
        ".gitignore",
        "pyproject.toml",
        "requirements.txt",
        "package.json",
        "dockerfile",
        "docker-compose.yml",
        "docker-compose.yaml",
        "compose.yml",
        "compose.yaml",
        ".env.example",
        "azure-pipelines.yml",
        "azure-pipelines.yaml",
        "license",
        "license.md",
        "licence",
        "licence.md",
    }

    def __init__(
        self,
        cache_duration_seconds: int = 30,
        maximum_commits: int = 5,
        app_data: Path | None = None,
        allowed_app_data_subtree: Path | None = None,
    ) -> None:
        self.cache_duration_seconds = cache_duration_seconds
        self.maximum_commits = maximum_commits
        self.technology_detector = TechnologyDetector()
        self.health_service = HealthScoreService()
        self.app_data = app_data
        self.allowed_app_data_subtree = allowed_app_data_subtree
        self._cache: dict[str, tuple[float, RepositoryInfo]] = {}
        self._cache_lock = threading.Lock()

    def scan_all(
        self,
        projects: list[ProjectConfig],
        *,
        force: bool = False,
        progress: ProgressCallback | None = None,
        cancel_event: threading.Event | None = None,
    ) -> list[RepositoryInfo]:
        repositories: list[RepositoryInfo] = []
        total = len(projects)
        for index, project in enumerate(projects, start=1):
            if cancel_event is not None and cancel_event.is_set():
                break
            repositories.append(self.scan(project, force=force))
            if progress:
                progress(index, total, project)
        return repositories

    def scan(self, project: ProjectConfig, *, force: bool = False) -> RepositoryInfo:
        key = os.path.normcase(os.path.abspath(project.path))
        if not force and (cached := self._cached(key)) is not None:
            return cached
        started = time.monotonic()
        result = self._scan_uncached(project)
        result = result.model_copy(
            update={"last_scan_duration_ms": max(0, int((time.monotonic() - started) * 1000))}
        )
        with self._cache_lock:
            self._cache[key] = (time.monotonic(), result)
        return result

    def clear_cache(self) -> None:
        with self._cache_lock:
            self._cache.clear()

    def _cached(self, key: str) -> RepositoryInfo | None:
        if self.cache_duration_seconds <= 0:
            return None
        with self._cache_lock:
            cached = self._cache.get(key)
        if cached and time.monotonic() - cached[0] <= self.cache_duration_seconds:
            return cached[1]
        return None

    def _scan_uncached(self, project: ProjectConfig) -> RepositoryInfo:
        now = datetime.now(UTC)
        path = project.path
        if self.app_data is not None:
            try:
                path = validate_selected_path(
                    path,
                    app_data=self.app_data,
                    allowed_app_data_subtree=self.allowed_app_data_subtree,
                )
                project = project.model_copy(update={"path": path})
            except UnsafeProjectPath as exc:
                if path.exists():
                    return self._error_info(project, now, "unsupported_path", str(exc))
        try:
            exists = path.exists() and path.is_dir()
        except OSError as exc:
            return self._error_info(project, now, "access_error", f"Repository access error: {exc}")
        if not exists:
            return RepositoryInfo(
                project=project,
                exists=False,
                is_git_repository=False,
                status="missing",
                warnings=["Project directory does not exist"],
                error="Project directory does not exist",
                last_scan_timestamp=now,
            )
        try:
            repo = Repo(path, search_parent_directories=False)
            # Git status/rev-list remain read-only and cannot opportunistically refresh the index.
            repo.git.update_environment(GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")
        except (InvalidGitRepositoryError, NoSuchPathError):
            return RepositoryInfo(
                project=project,
                exists=True,
                is_git_repository=False,
                status="not_git",
                warnings=["Path is not a Git repository"],
                last_scan_timestamp=now,
            )
        except (OSError, GitCommandError) as exc:
            return self._error_info(project, now, "access_error", f"Repository access error: {exc}")

        try:
            branch, detached = self._branch_name(repo)
            porcelain = repo.git.status("--porcelain=v1", "--untracked-files=all")
            modified, staged, untracked = self.parse_porcelain_status(porcelain)
            changed = sorted(set(modified) | set(staged) | set(untracked))
            commits = self._commits(repo)
            last = commits[0] if commits else None
            tracking = None
            if repo.head.is_valid() and not detached:
                with suppress(GitCommandError, TypeError, ValueError):
                    tracking = repo.active_branch.tracking_branch()
            ahead, behind = self._ahead_behind(repo)
            technologies = self.technology_detector.detect(path)
            clean = not changed
            status = self._status(detached, modified, staged, untracked)
            health_score, breakdown = self.health_service.calculate(
                path,
                is_git_repository=True,
                is_clean=clean,
                last_commit_date=last.date if last else None,
                technologies=technologies,
            )
            warnings: list[str] = []
            if detached:
                warnings.append("HEAD is detached; branch tracking is unavailable")
            if not repo.head.is_valid():
                warnings.append("Repository has no commits")
            if repo.head.is_valid() and not detached and tracking is None:
                warnings.append("Current branch has no upstream tracking branch")
            if changed:
                warnings.append("Repository has uncommitted changes")
            root_files = self._root_files(path)
            if not any(name.startswith("readme") for name in root_files):
                warnings.append("README file is missing")
            if not any(
                name in {"test", "tests", "spec", "specs", "__tests__"} for name in root_files
            ):
                warnings.append("A recognised tests directory is missing")
            if ".gitignore" not in root_files:
                warnings.append(".gitignore file is missing")
            if not set(root_files) & self._lockfiles():
                warnings.append("Dependency lockfile is missing")
            if not self.technology_detector.ci_provider(path):
                warnings.append("CI workflow is missing")
            if last is not None and (datetime.now(UTC) - last.date).days > 30:
                warnings.append("Repository has no commit in the last 30 days")
            warning_details = self._warning_details(warnings, modified, staged, untracked)
            age_days = (datetime.now(UTC) - last.date).days if last else None
            result = RepositoryInfo(
                project=project,
                exists=True,
                is_git_repository=True,
                branch=branch,
                tracking_branch=tracking.name if tracking else None,
                detached_head=detached,
                is_clean=clean,
                status=status,
                changed_files=len(changed),
                modified_count=len(modified),
                staged_count=len(staged),
                untracked_count=len(untracked),
                ahead_count=ahead,
                behind_count=behind,
                modified_files=modified,
                staged_files=staged,
                untracked_files=untracked,
                last_commit_message=last.message if last else "No commits yet",
                last_commit_author=last.author if last else "-",
                last_commit_date=last.date if last else None,
                repository_age_days=age_days,
                recent_activity=age_days is not None and age_days <= 30,
                commits=commits,
                technologies=technologies,
                primary_technology=self.technology_detector.primary(technologies),
                important_files=self._important_files(path),
                root_files=root_files,
                dependency_manager=self.technology_detector.dependency_manager(path),
                testing_framework=self.technology_detector.testing_framework(path, technologies),
                ci_provider=self.technology_detector.ci_provider(path),
                container_support="Docker" in technologies,
                deployment_indicators=self.technology_detector.deployment_indicators(path),
                monorepo=self._is_monorepo(path, root_files),
                application_directories=self._application_directories(path),
                documentation_directory=(path / "docs").is_dir(),
                remote_present=bool(repo.remotes),
                health_score=health_score,
                health_breakdown=breakdown,
                warnings=warnings,
                warning_details=warning_details,
                last_scan_timestamp=now,
            )
            repo.close()
            return result
        except (OSError, ValueError, TypeError, GitCommandError) as exc:
            logger.warning("Could not inspect repository at %s: %s", path, exc)
            repo.close()
            return RepositoryInfo(
                project=project,
                exists=True,
                is_git_repository=True,
                status="access_error",
                warnings=["Repository inspection failed"],
                error=str(exc),
                last_scan_timestamp=now,
            )

    @staticmethod
    def parse_porcelain_status(output: str) -> tuple[list[str], list[str], list[str]]:
        modified: set[str] = set()
        staged: set[str] = set()
        untracked: set[str] = set()
        for line in output.splitlines():
            if len(line) < 3:
                continue
            x, y = line[0], line[1]
            path = line[3:].strip().strip('"')
            if " -> " in path:
                path = path.rsplit(" -> ", 1)[1].strip('"')
            if x == "?" and y == "?":
                untracked.add(path)
                continue
            if x not in {" ", "?"}:
                staged.add(path)
            if y not in {" ", "?"} or x == "U":
                modified.add(path)
        return sorted(modified), sorted(staged), sorted(untracked)

    @staticmethod
    def _branch_name(repo: Repo) -> tuple[str, bool]:
        if not repo.head.is_valid():
            return "unborn", False
        if repo.head.is_detached:
            return f"detached@{repo.head.commit.hexsha[:7]}", True
        return repo.active_branch.name, False

    def _commits(self, repo: Repo) -> list[CommitInfo]:
        if not repo.head.is_valid():
            return []
        return [
            CommitInfo(
                short_sha=commit.hexsha[:7],
                message=commit.summary,
                author=commit.author.name or "Unknown",
                date=commit.authored_datetime,
            )
            for commit in repo.iter_commits(max_count=self.maximum_commits)
        ]

    @staticmethod
    def _ahead_behind(repo: Repo) -> tuple[int, int]:
        if not repo.head.is_valid() or repo.head.is_detached:
            return 0, 0
        tracking = repo.active_branch.tracking_branch()
        if tracking is None:
            return 0, 0
        behind, ahead = (
            int(value)
            for value in repo.git.rev_list(
                "--left-right", "--count", f"{tracking.name}...HEAD"
            ).split()
        )
        return ahead, behind

    @staticmethod
    def _status(
        detached: bool, modified: list[str], staged: list[str], untracked: list[str]
    ) -> str:
        if detached:
            return "detached"
        if modified or staged:
            return "modified"
        if untracked:
            return "untracked"
        return "clean"

    @classmethod
    def _important_files(cls, path: Path) -> list[str]:
        try:
            return sorted(
                item.name
                for item in path.iterdir()
                if item.is_file() and item.name.casefold() in cls.IMPORTANT_NAMES
            )
        except OSError:
            return []

    @classmethod
    def _root_files(cls, path: Path) -> list[str]:
        try:
            return sorted(
                item.name for item in path.iterdir() if item.is_file() and len(item.name) <= 240
            )[:250]
        except OSError:
            return []

    @staticmethod
    def _lockfiles() -> set[str]:
        return {
            "poetry.lock",
            "uv.lock",
            "package-lock.json",
            "pnpm-lock.yaml",
            "yarn.lock",
            "cargo.lock",
            "gemfile.lock",
            "composer.lock",
        }

    @staticmethod
    def _is_monorepo(path: Path, root_files: list[str]) -> bool:
        lowered = {name.casefold() for name in root_files}
        if lowered & {"pnpm-workspace.yaml", "lerna.json", "nx.json", "turbo.json"}:
            return True
        return any((path / item).is_dir() for item in ("apps", "packages", "services"))

    @staticmethod
    def _application_directories(path: Path) -> list[str]:
        result: list[str] = []
        try:
            for item in path.iterdir():
                if item.is_dir() and item.name.casefold() in {
                    "app",
                    "apps",
                    "src",
                    "client",
                    "server",
                    "services",
                    "packages",
                }:
                    result.append(item.name)
        except OSError:
            return []
        return sorted(result)

    @staticmethod
    def _warning_details(
        warnings: list[str], modified: list[str], staged: list[str], untracked: list[str]
    ) -> list[WarningFinding]:
        details: list[WarningFinding] = []
        for message in warnings:
            lower = message.casefold()
            if "uncommitted" in lower:
                code, title, why, action = (
                    "working_tree_modified",
                    "Uncommitted files",
                    "Local work is not represented by the latest commit.",
                    "Review the working tree manually in your normal Git client.",
                )
            elif "detached" in lower:
                code, title, why, action = (
                    "detached_head",
                    "Detached HEAD",
                    "New commits may not belong to a named branch.",
                    "Choose the intended branch manually before creating commits.",
                )
            elif "upstream" in lower:
                code, title, why, action = (
                    "no_tracking_branch",
                    "No remote tracking branch",
                    "Ahead/behind comparison is unavailable for this branch.",
                    "Configure an upstream branch manually if this repository should sync "
                    "with a remote.",
                )
            elif "readme" in lower:
                code, title, why, action = (
                    "missing_readme",
                    "Missing README",
                    "New contributors may not have an orientation document.",
                    "Add a README manually if this project would benefit from one.",
                )
            elif "tests" in lower:
                code, title, why, action = (
                    "missing_tests",
                    "Missing tests",
                    "There is no recognised test directory at the repository root.",
                    "Confirm the project layout or add tests manually.",
                )
            elif "gitignore" in lower:
                code, title, why, action = (
                    "missing_gitignore",
                    "Missing .gitignore",
                    "Generated or local files may be easier to add accidentally.",
                    "Create a project-appropriate .gitignore manually.",
                )
            elif "lockfile" in lower:
                code, title, why, action = (
                    "missing_lockfile",
                    "Missing dependency lockfile",
                    "Dependency resolution may vary between machines.",
                    "Use the project’s documented dependency workflow manually.",
                )
            elif "ci workflow" in lower:
                code, title, why, action = (
                    "missing_ci",
                    "Missing CI workflow",
                    "Changes may not have an automated validation gate.",
                    "Review whether a CI workflow is appropriate for this repository.",
                )
            elif "30 days" in lower:
                code, title, why, action = (
                    "stale_repository",
                    "Stale repository",
                    "The latest local commit is older than the configured attention window.",
                    "Confirm the project’s maintenance cadence manually.",
                )
            else:
                code, title, why, action = (
                    "repository_warning",
                    "Repository warning",
                    "DevPulse found a condition worth reviewing.",
                    "Review the repository manually; DevPulse does not apply fixes.",
                )
            details.append(
                WarningFinding(
                    code=code,
                    title=title,
                    what=message,
                    why=why,
                    suggested_action=action,
                )
            )
        return details

    @staticmethod
    def _error_info(
        project: ProjectConfig, timestamp: datetime, status: str, message: str
    ) -> RepositoryInfo:
        return RepositoryInfo(
            project=project,
            exists=True,
            is_git_repository=False,
            status=status,
            warnings=[message],
            error=message,
            last_scan_timestamp=timestamp,
        )
