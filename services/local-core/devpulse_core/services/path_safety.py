"""Canonical path validation for explicitly selected repository locations."""

from __future__ import annotations

import os
import stat
from pathlib import Path


class UnsafeProjectPath(ValueError):
    """Raised when a selected path is outside DevPulse's scanning boundary."""


def validate_selected_path(
    candidate: Path,
    *,
    app_data: Path,
    require_git: bool = False,
    allowed_app_data_subtree: Path | None = None,
) -> Path:
    raw = str(candidate).strip()
    if not raw or not candidate.is_absolute():
        raise UnsafeProjectPath("Choose an absolute folder path.")
    if any(part == ".." for part in candidate.parts):
        raise UnsafeProjectPath("Parent-directory traversal is not allowed.")
    if os.name == "nt" and raw.startswith(("\\\\", "//")):
        raise UnsafeProjectPath("Network and device paths are not supported in this release.")
    try:
        canonical = candidate.resolve(strict=True)
    except FileNotFoundError as exc:
        raise UnsafeProjectPath("The selected folder no longer exists.") from exc
    except (OSError, PermissionError) as exc:
        raise UnsafeProjectPath("The selected folder could not be accessed.") from exc
    if not canonical.is_dir():
        raise UnsafeProjectPath("Choose a folder, not a file.")
    if canonical == Path(canonical.anchor):
        raise UnsafeProjectPath("Filesystem roots cannot be scanned.")

    protected = _protected_roots(app_data)
    allowed = (
        allowed_app_data_subtree.resolve(strict=False)
        if allowed_app_data_subtree is not None
        else None
    )
    if canonical == Path.home().resolve() or (
        any(_same_or_within(canonical, item) for item in protected)
        and not (allowed is not None and _same_or_within(canonical, allowed))
    ):
        raise UnsafeProjectPath("This operating-system or application-data folder is protected.")
    if _contains_reparse_component(candidate):
        raise UnsafeProjectPath("Junction and symbolic-link paths are not supported.")
    if require_git and not ((canonical / ".git").is_dir() or (canonical / ".git").is_file()):
        raise UnsafeProjectPath("The selected folder is not a Git repository.")
    return canonical


def _protected_roots(app_data: Path) -> set[Path]:
    roots = {app_data.resolve()}
    if os.name == "nt":
        for variable in ("WINDIR", "ProgramFiles", "ProgramFiles(x86)", "ProgramData"):
            if value := os.environ.get(variable):
                try:
                    roots.add(Path(value).resolve())
                except OSError:
                    continue
    return roots


def _same_or_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _contains_reparse_component(path: Path) -> bool:
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        try:
            metadata = current.lstat()
        except OSError:
            return False
        attributes = getattr(metadata, "st_file_attributes", 0)
        if current.is_symlink() or attributes & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0):
            return True
    return False
