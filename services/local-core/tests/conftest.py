"""Fixtures remain entirely inside pytest temporary directories."""

import os
from pathlib import Path

import pytest
from devpulse_core.config import SettingsStore
from devpulse_core.paths import AppPaths


def pytest_configure(config: pytest.Config) -> None:
    """Use a unique DevPulse-owned test directory on every Windows-safe run."""
    if not config.option.basetemp:
        parent = Path.cwd() / ".tmp" / "test-lab"
        parent.mkdir(parents=True, exist_ok=True)
        config.option.basetemp = str(parent / f"pytest-{os.getpid()}")


@pytest.fixture
def app_paths(tmp_path: Path) -> AppPaths:
    return AppPaths.resolve(tmp_path / "app-data")


@pytest.fixture
def settings_store(app_paths: AppPaths) -> SettingsStore:
    return SettingsStore(app_paths)
