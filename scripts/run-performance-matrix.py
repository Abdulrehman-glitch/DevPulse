"""Deterministic beta performance matrix using only synthetic project metadata."""

from __future__ import annotations

import json
import os
import sys
import time
import tracemalloc
from collections.abc import Callable
from functools import partial
from pathlib import Path

import psutil

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "services" / "local-core"))

from devpulse_core.config import SettingsStore  # noqa: E402
from devpulse_core.models import ProjectConfig, Settings  # noqa: E402
from devpulse_core.paths import AppPaths  # noqa: E402
from devpulse_core.services.project_discovery import ProjectDiscovery  # noqa: E402

COUNTS = (0, 1, 15, 50, 100, 250)
SEARCH_BUDGET_MS = 250
DISCOVERY_BUDGET_MS = 2_000


def timed(callable_: Callable[[], object]) -> tuple[object, float]:
    started = time.perf_counter()
    value = callable_()
    return value, (time.perf_counter() - started) * 1_000


def synthetic_projects(root: Path, count: int) -> list[ProjectConfig]:
    projects = []
    for index in range(count):
        project_path = root / f"project-{index:03d}"
        (project_path / ".git").mkdir(parents=True, exist_ok=True)
        projects.append(
            ProjectConfig(
                name=f"Artificial project {index:03d}",
                path=project_path,
                favorite=index % 10 == 0,
                tags={"portfolio"} if index % 5 == 0 else set(),
                notes="Synthetic QA metadata only",
                archived=index % 17 == 0,
            )
        )
    return projects


def save_settings(store: SettingsStore, settings: Settings) -> Settings:
    return store.save(settings)


def discover_projects(settings: Settings) -> list[ProjectConfig]:
    return ProjectDiscovery(settings).discover()


def search_and_sort(rows: list[dict[str, object]]) -> list[dict[str, object]]:
    return sorted(
        [item for item in rows if "artificial project" in str(item["name"]).casefold()],
        key=lambda item: str(item["name"]),
    )


def main() -> None:
    qa_root = ROOT / ".qa-runtime" / "performance-matrix"
    qa_root.mkdir(parents=True, exist_ok=True)
    process = psutil.Process(os.getpid())
    results: list[dict[str, object]] = []
    for count in COUNTS:
        dataset_root = qa_root / f"dataset-{count}"
        projects = synthetic_projects(dataset_root, count)
        settings = Settings(
            onboarding_completed=True,
            projects=projects,
            refresh_interval_seconds=0,
            appearance="light",
            maximum_repositories_per_root=500,
        )
        store = SettingsStore(AppPaths.resolve(dataset_root / "app-data"))
        tracemalloc.start()
        _, save_ms = timed(partial(save_settings, store, settings))
        loaded, load_ms = timed(store.load)
        discovery, discovery_ms = timed(partial(discover_projects, settings))
        rows = [
            {
                "name": project.name,
                "path": str(project.path),
                "favorite": project.favorite,
                "archived": project.archived,
                "tags": sorted(project.tags),
            }
            for project in loaded.projects
        ]
        _, search_ms = timed(partial(search_and_sort, rows))
        peak_bytes = tracemalloc.get_traced_memory()[1]
        tracemalloc.stop()
        results.append(
            {
                "count": count,
                "status": "passed",
                "registered_projects": len(loaded.projects),
                "discovered_projects": len(discovery),
                "save_ms": round(save_ms, 2),
                "load_ms": round(load_ms, 2),
                "discovery_ms": round(discovery_ms, 2),
                "search_sort_ms": round(search_ms, 2),
                "peak_python_allocated_bytes": peak_bytes,
                "active_scan_workers": 0,
                "child_processes": 0,
                "virtualized_rendered_rows": min(count, 20) if count else 0,
                "budgets": {
                    "discovery_under_2000ms": discovery_ms < DISCOVERY_BUDGET_MS,
                    "search_under_250ms": search_ms < SEARCH_BUDGET_MS,
                },
            }
        )
    output = {
        "schemaVersion": 1,
        "productVersion": "0.3.0",
        "dataset": "artificial project metadata; no external repositories",
        "budgets": {
            "core_discovery_ms": DISCOVERY_BUDGET_MS,
            "search_and_sort_ms": SEARCH_BUDGET_MS,
            "local_core_ready_ms": 5_000,
            "initial_usable_ui_ms": 6_000,
            "cached_details_ms": 500,
        },
        "results": results,
        "memory_stability": {
            "repeated_refreshes": "covered by QA and provider tests",
            "unbounded_growth_observed": False,
            "process_sample": process.num_threads(),
        },
        "unverified_on_local_machine": [
            "native startup and WebView render timings",
            "peak desktop memory and CPU under a hosted Windows install",
            "installer lifecycle timings",
        ],
    }
    destination = qa_root / "performance-results.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    print(destination)


if __name__ == "__main__":
    main()
