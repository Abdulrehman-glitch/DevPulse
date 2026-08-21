"""Safe, bounded and read-only discovery of Git repository roots."""

from __future__ import annotations

import logging
import os
import stat
import time
from collections import deque
from pathlib import Path

from devpulse_core.models import ProjectConfig, Settings
from devpulse_core.services.path_safety import (
    UnsafeProjectPath,
    validate_descendant_path,
    validate_selected_path,
)

logger = logging.getLogger(__name__)


class ProjectDiscovery:
    def __init__(
        self,
        settings: Settings,
        *,
        app_data: Path | None = None,
        allowed_app_data_subtree: Path | None = None,
    ) -> None:
        self.settings = settings
        self.app_data = app_data
        self.allowed_app_data_subtree = allowed_app_data_subtree
        self.diagnostic_codes: list[str] = []

    def discover(self) -> list[ProjectConfig]:
        projects: list[ProjectConfig] = []
        seen: set[str] = set()
        for project in self.settings.projects:
            self._add(project, projects, seen)
            try:
                valid = project.path.exists() and project.path.is_dir()
            except OSError:
                self._diagnostic("registered_project_inaccessible")
                continue
            if not valid:
                self._diagnostic("registered_project_missing")
        for scan_root in self.settings.scan_roots:
            root = scan_root.path
            try:
                if self.app_data is not None:
                    root = validate_selected_path(
                        root,
                        app_data=self.app_data,
                        allowed_app_data_subtree=self.allowed_app_data_subtree,
                    )
                else:
                    root = root.resolve(strict=True)
                valid = root.is_dir()
            except (OSError, PermissionError, UnsafeProjectPath):
                self._diagnostic("scan_root_refused")
                continue
            if valid:
                self._discover_root(root, scan_root.recursive, projects, seen)
            else:
                self._diagnostic("scan_root_refused")
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
        entries_seen = 0
        added_at_start = len(projects)
        while queue:
            if time.monotonic() - started >= self.settings.scan_timeout_seconds:
                self._diagnostic("scan_timeout")
                break
            if visited >= self.settings.maximum_directories_per_scan:
                self._diagnostic("scan_directory_limit")
                break
            if entries_seen >= self.settings.maximum_entries_per_scan:
                self._diagnostic("scan_entry_limit")
                break
            if len(projects) - added_at_start >= self.settings.maximum_repositories_per_root:
                self._diagnostic("scan_repository_limit")
                break
            path, depth = queue.popleft()
            visited += 1
            try:
                path = validate_descendant_path(path, approved_root=root)
                if self._is_repository(path):
                    self._add(ProjectConfig(name=path.name or str(path), path=path), projects, seen)
                    continue
                if not recursive or depth >= self.settings.maximum_scan_depth:
                    continue
                with os.scandir(path) as children:
                    limit_reached = self._queue_children(children, queue, depth, entries_seen)
                    entries_seen += limit_reached[1]
                    if limit_reached[0]:
                        self._diagnostic("scan_entry_limit")
                        break
            except (OSError, PermissionError, UnsafeProjectPath):
                self._diagnostic("scan_path_changed_or_inaccessible")
                continue

    def _queue_children(
        self,
        children: os.ScandirIterator[str],
        queue: deque[tuple[Path, int]],
        depth: int,
        entries_seen: int,
    ) -> tuple[bool, int]:
        added_entries = 0
        for child in children:
            added_entries += 1
            if entries_seen + added_entries > self.settings.maximum_entries_per_scan:
                return True, added_entries
            try:
                is_directory = child.is_dir(follow_symlinks=False)
            except OSError:
                self._diagnostic("scan_entry_inaccessible")
                continue
            if (
                is_directory
                and not child.name.startswith(".")
                and child.name.casefold() not in self.settings.ignored_directories
                and not self._is_reparse(Path(child.path))
            ):
                queue.append((Path(child.path), depth + 1))
        return False, added_entries

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

    def _diagnostic(self, code: str) -> None:
        if code not in self.diagnostic_codes:
            self.diagnostic_codes.append(code)
        logger.warning("Repository discovery boundary event: %s", code)
