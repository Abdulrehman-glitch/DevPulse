"""Safe, bounded and read-only discovery of Git repository roots."""

from __future__ import annotations

import logging
import os
import stat
import time
from collections import deque
from pathlib import Path

from devpulse_core.models import ProjectConfig, Settings

logger = logging.getLogger(__name__)


class ProjectDiscovery:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    def discover(self) -> list[ProjectConfig]:
        projects: list[ProjectConfig] = []
        seen: set[str] = set()
        for project in self.settings.projects:
            self._add(project, projects, seen)
            try:
                valid = project.path.exists() and project.path.is_dir()
            except OSError as exc:
                logger.warning("Repository path inaccessible: %s (%s)", project.path, exc)
                continue
            if not valid:
                logger.warning("Invalid repository path: %s", project.path)
        for scan_root in self.settings.scan_roots:
            root = scan_root.path
            try:
                valid = root.exists() and root.is_dir()
            except OSError as exc:
                logger.warning("Repository root inaccessible: %s (%s)", root, exc)
                continue
            if valid:
                self._discover_root(root, scan_root.recursive, projects, seen)
            else:
                logger.warning("Invalid repository path: %s", root)
        return projects

    def _discover_root(
        self,
        root: Path,
        recursive: bool,
        projects: list[ProjectConfig],
        seen: set[str],
    ) -> None:
        queue: deque[tuple[Path, int]] = deque([(root, 0)])
        started = time.monotonic()
        visited = 0
        added_at_start = len(projects)
        while queue:
            if time.monotonic() - started >= self.settings.scan_timeout_seconds:
                logger.warning("Repository discovery timed out at %s", root)
                break
            if visited >= self.settings.maximum_directories_per_scan:
                logger.warning("Repository discovery directory limit reached at %s", root)
                break
            if len(projects) - added_at_start >= self.settings.maximum_repositories_per_root:
                logger.warning("Repository discovery result limit reached at %s", root)
                break
            path, depth = queue.popleft()
            visited += 1
            try:
                if self._is_repository(path):
                    self._add(ProjectConfig(name=path.name or str(path), path=path), projects, seen)
                    continue
                if not recursive or depth >= self.settings.maximum_scan_depth:
                    continue
                children = list(os.scandir(path))
            except (OSError, PermissionError) as exc:
                logger.warning("Repository path inaccessible: %s (%s)", path, exc)
                continue
            for child in children:
                try:
                    is_directory = child.is_dir(follow_symlinks=False)
                except OSError:
                    continue
                if (
                    is_directory
                    and not child.name.startswith(".")
                    and child.name.casefold() not in self.settings.ignored_directories
                    and not self._is_reparse(Path(child.path))
                ):
                    queue.append((Path(child.path), depth + 1))

    @staticmethod
    def _is_repository(path: Path) -> bool:
        try:
            marker = path / ".git"
            return marker.is_dir() or marker.is_file()
        except OSError:
            return False

    @staticmethod
    def _is_reparse(path: Path) -> bool:
        try:
            metadata = path.lstat()
            attributes = getattr(metadata, "st_file_attributes", 0)
            return path.is_symlink() or bool(
                attributes & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0)
            )
        except OSError:
            return True

    @staticmethod
    def _add(project: ProjectConfig, projects: list[ProjectConfig], seen: set[str]) -> None:
        key = os.path.normcase(os.path.abspath(project.path))
        if key not in seen:
            seen.add(key)
            projects.append(project)
