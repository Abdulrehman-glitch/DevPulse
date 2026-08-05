from time import perf_counter

import pytest
from devpulse_core.models import ProjectConfig, Settings
from devpulse_core.services.project_discovery import ProjectDiscovery


def test_artificial_250_project_discovery_stays_bounded(tmp_path) -> None:
    projects = [
        ProjectConfig(
            name=f"Artificial project {index:03d}", path=tmp_path / f"project-{index:03d}"
        )
        for index in range(250)
    ]
    started = perf_counter()
    result = ProjectDiscovery(
        Settings(projects=projects, maximum_repositories_per_root=500)
    ).discover()
    duration_ms = (perf_counter() - started) * 1_000
    assert result == projects
    assert duration_ms < 2_000


@pytest.mark.parametrize("count", [0, 1, 15, 50, 100, 250])
def test_deterministic_performance_matrix_preserves_every_artificial_dataset(
    tmp_path, count: int
) -> None:
    projects = [
        ProjectConfig(
            name=f"Artificial project {index:03d}", path=tmp_path / f"project-{index:03d}"
        )
        for index in range(count)
    ]
    started = perf_counter()
    result = ProjectDiscovery(
        Settings(projects=projects, maximum_repositories_per_root=500)
    ).discover()
    duration_ms = (perf_counter() - started) * 1_000
    assert len(result) == count
    assert duration_ms < 2_000
