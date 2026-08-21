"""Transparent project health scoring."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from itertools import islice
from pathlib import Path

from devpulse_core.models import HealthCheck
from devpulse_core.services.path_safety import UnsafeProjectPath, validate_descendant_path


class HealthScoreService:
    def calculate(
        self,
        root: Path,
        *,
        is_git_repository: bool,
        is_clean: bool | None,
        last_commit_date: datetime | None,
        technologies: list[str],
    ) -> tuple[int, list[HealthCheck]]:
        names, directories = self._root_entries(root)
        checks = [
            self._check("Git repository detected", 10, is_git_repository, ".git is available"),
            self._check(
                "README present",
                10,
                any(name.startswith("readme") for name in names),
                "README file in project root",
            ),
            self._check(
                ".gitignore present", 5, ".gitignore" in names, ".gitignore in project root"
            ),
            self._check(
                "Dependency file present",
                10,
                bool(names & self._dependency_files()),
                "Recognised dependency manifest",
            ),
            self._check(
                "Tests present",
                15,
                self._has_tests(names, directories),
                "Root test file or tests directory",
            ),
            self._check(
                "CI workflow present",
                10,
                self._has_ci(root, names),
                "GitHub Actions or pipeline configuration",
            ),
            self._check("No uncommitted changes", 15, is_clean is True, "Working tree is clean"),
            self._check(
                "Recent commit within 30 days",
                10,
                self._is_recent(last_commit_date),
                "Latest commit age is at most 30 days",
            ),
            self._check(
                "Environment example present",
                5,
                bool(names & {".env.example", ".env.sample", "env.example", "example.env"}),
                "Example environment file in root",
            ),
            self._check(
                "Licence present",
                5,
                any(name.startswith(("licence", "license", "copying")) for name in names),
                "Licence file in root",
            ),
            self._check(
                "Docker support present",
                5,
                "Docker" in technologies,
                "Dockerfile or Compose configuration",
            ),
        ]
        return sum(check.points for check in checks if check.earned), checks

    @staticmethod
    def _check(label: str, points: int, earned: bool, detail: str) -> HealthCheck:
        return HealthCheck(label=label, points=points, earned=earned, detail=detail)

    @staticmethod
    def _root_entries(root: Path) -> tuple[set[str], set[str]]:
        names: set[str] = set()
        directories: set[str] = set()
        try:
            for item in islice(root.iterdir(), 500):
                names.add(item.name.casefold())
                try:
                    if validate_descendant_path(item, approved_root=root).is_dir():
                        directories.add(item.name.casefold())
                except (OSError, UnsafeProjectPath):
                    pass
        except OSError:
            pass
        return names, directories

    @staticmethod
    def _dependency_files() -> set[str]:
        return {
            "pyproject.toml",
            "requirements.txt",
            "package.json",
            "pipfile",
            "poetry.lock",
            "package-lock.json",
            "yarn.lock",
            "pnpm-lock.yaml",
        }

    @staticmethod
    def _has_tests(names: set[str], directories: set[str]) -> bool:
        return bool(directories & {"test", "tests", "spec", "specs", "__tests__"}) or any(
            name.startswith("test_")
            or name.endswith((".test.py", ".test.ts", ".test.js", ".spec.ts", ".spec.js"))
            for name in names
        )

    @staticmethod
    def _has_ci(root: Path, names: set[str]) -> bool:
        if names & {"azure-pipelines.yml", "azure-pipelines.yaml", ".gitlab-ci.yml", "jenkinsfile"}:
            return True
        workflows = root / ".github" / "workflows"
        try:
            canonical = validate_descendant_path(workflows, approved_root=root)
            return canonical.is_dir() and any(
                item.suffix.casefold() in {".yml", ".yaml"}
                for item in islice(canonical.iterdir(), 500)
            )
        except (OSError, UnsafeProjectPath):
            return False

    @staticmethod
    def _is_recent(commit_date: datetime | None) -> bool:
        if commit_date is None:
            return False
        if commit_date.tzinfo is None:
            commit_date = commit_date.replace(tzinfo=UTC)
        return commit_date >= datetime.now(UTC) - timedelta(days=30)
