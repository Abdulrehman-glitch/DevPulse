from pathlib import Path

import pytest
from devpulse_core.api import create_app
from devpulse_core.config import SettingsStore
from devpulse_core.main import resolve_access_token
from devpulse_core.models import ProjectConfig, Settings
from devpulse_core.providers.local import LocalDataProvider, project_id
from fastapi.testclient import TestClient
from git import Repo

ACCESS_TOKEN = "devpulse-test-token-00000000000000000000000000000000"
AUTH_HEADERS = {"X-DevPulse-Token": ACCESS_TOKEN}


def create_unauthenticated_test_app(provider: LocalDataProvider):
    """Explicitly isolate the few API behavior tests that do not exercise authentication."""
    return create_app(
        provider,
        refresh_on_start=False,
        allow_unauthenticated_for_tests=True,
    )


def make_provider(settings_store: SettingsStore, tmp_path: Path) -> LocalDataProvider:
    root = tmp_path / "repository"
    repo = Repo.init(root, initial_branch="main")
    (root / "README.md").write_text("# Temporary\n", encoding="utf-8")
    repo.index.add(["README.md"])
    repo.index.commit("Initial")
    settings_store.save(Settings(projects=[ProjectConfig(name="Temporary", path=root)]))
    provider = LocalDataProvider(settings_store)
    provider.refresh()
    return provider


def test_production_app_construction_fails_closed_without_strong_authentication(
    settings_store: SettingsStore,
) -> None:
    provider = LocalDataProvider(settings_store)
    with pytest.raises(ValueError, match="requires an access token"):
        create_app(provider, refresh_on_start=False)
    with pytest.raises(ValueError, match="at least 32 characters"):
        create_app(provider, access_token="too-short", refresh_on_start=False)


def test_unauthenticated_construction_requires_explicit_test_fixture(
    settings_store: SettingsStore,
) -> None:
    app = create_unauthenticated_test_app(LocalDataProvider(settings_store))
    with TestClient(app) as client:
        assert client.get("/health").status_code == 200


def test_runtime_access_tokens_must_be_supplied_strong_or_rejected() -> None:
    assert resolve_access_token(ACCESS_TOKEN) == ACCESS_TOKEN
    with pytest.raises(ValueError, match="at least 32 characters"):
        resolve_access_token(None)
    with pytest.raises(ValueError, match="at least 32 characters"):
        resolve_access_token("weak")


def test_open_path_resolves_only_a_current_registered_project(
    settings_store: SettingsStore, tmp_path: Path
) -> None:
    provider = make_provider(settings_store, tmp_path)
    registered = (tmp_path / "repository").resolve()
    identifier = project_id(registered)
    app = create_app(provider, access_token=ACCESS_TOKEN, refresh_on_start=False)
    with TestClient(app) as client:
        accepted = client.get(f"/api/v1/projects/{identifier}/open-path", headers=AUTH_HEADERS)
        rejected = client.get("/api/v1/projects/0000000000000000/open-path", headers=AUTH_HEADERS)
    assert accepted.status_code == 200
    assert accepted.json() == {"id": identifier, "path": str(registered)}
    assert rejected.status_code == 404


def test_health_rejects_missing_token(settings_store: SettingsStore) -> None:
    app = create_app(
        LocalDataProvider(settings_store), access_token=ACCESS_TOKEN, refresh_on_start=False
    )
    with TestClient(app) as client:
        response = client.get("/health")
    assert response.status_code == 401


def test_health_accepts_valid_session_token(settings_store: SettingsStore) -> None:
    app = create_app(
        LocalDataProvider(settings_store), access_token=ACCESS_TOKEN, refresh_on_start=False
    )
    with TestClient(app) as client:
        response = client.get("/health", headers=AUTH_HEADERS)
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_api_requires_token_and_returns_live_summary(
    settings_store: SettingsStore, tmp_path: Path
) -> None:
    app = create_app(
        make_provider(settings_store, tmp_path),
        access_token=ACCESS_TOKEN,
        refresh_on_start=False,
    )
    with TestClient(app) as client:
        assert client.get("/api/v1/projects").status_code == 401
        assert (
            client.get("/api/v1/projects", headers={"X-DevPulse-Token": "wrong-token"}).status_code
            == 401
        )
        headers = AUTH_HEADERS
        projects = client.get("/api/v1/projects", headers=headers)
        summary = client.get("/api/v1/system/summary", headers=headers)
    assert projects.status_code == 200
    assert projects.json()["total"] == 1
    assert summary.status_code == 200
    assert summary.json()["repositories_total"] == 1
    assert summary.json()["cpu_percent"] is not None


def test_structured_not_found_error(settings_store: SettingsStore) -> None:
    app = create_unauthenticated_test_app(LocalDataProvider(settings_store))
    with TestClient(app) as client:
        response = client.get("/api/v1/projects/does-not-exist")
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "request_failed"
    assert response.json()["error"]["request_id"]


def test_settings_can_clear_all_project_directories(
    settings_store: SettingsStore, tmp_path: Path
) -> None:
    provider = make_provider(settings_store, tmp_path)
    app = create_unauthenticated_test_app(provider)
    with TestClient(app) as client:
        response = client.patch("/api/v1/settings", json={"project_directories": []})
    assert response.status_code == 200
    assert response.json()["projects"] == []
    assert provider.settings().projects == []


def test_vite_development_origin_is_allowed(settings_store: SettingsStore) -> None:
    app = create_unauthenticated_test_app(LocalDataProvider(settings_store))
    with TestClient(app) as client:
        response = client.options(
            "/api/v1/projects",
            headers={
                "Origin": "http://127.0.0.1:1420",
                "Access-Control-Request-Method": "GET",
            },
        )
    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == "http://127.0.0.1:1420"


def test_project_preview_add_duplicate_and_remove_are_registration_only(
    settings_store: SettingsStore, tmp_path: Path
) -> None:
    provider = LocalDataProvider(settings_store)
    root = tmp_path / "new-repository"
    repo = Repo.init(root, initial_branch="main")
    (root / "README.md").write_text("# Fixture\n", encoding="utf-8")
    repo.index.add(["README.md"])
    repo.index.commit("Initial")
    app = create_app(provider, access_token=ACCESS_TOKEN, refresh_on_start=False)
    headers = AUTH_HEADERS
    with TestClient(app) as client:
        preview = client.post("/api/v1/projects/preview", json={"path": str(root)}, headers=headers)
        assert preview.status_code == 200
        added = client.post("/api/v1/projects", json={"paths": [str(root)]}, headers=headers)
        assert added.status_code == 200
        duplicate = client.post("/api/v1/projects", json={"paths": [str(root)]}, headers=headers)
        assert duplicate.status_code == 400
        identifier = preview.json()["summary"]["id"]
        removed = client.delete(f"/api/v1/projects/{identifier}", headers=headers)
        assert removed.status_code == 200
    assert root.exists()
    assert (root / "README.md").read_text(encoding="utf-8") == "# Fixture\n"


def test_request_size_limit_is_enforced(settings_store: SettingsStore) -> None:
    app = create_app(
        LocalDataProvider(settings_store), access_token=ACCESS_TOKEN, refresh_on_start=False
    )
    with TestClient(app) as client:
        response = client.patch(
            "/api/v1/settings",
            content=b"x" * 65_537,
            headers={**AUTH_HEADERS, "Content-Type": "application/json"},
        )
    assert response.status_code == 413


def test_alpha3_project_metadata_configuration_portability_and_backups(
    settings_store: SettingsStore, tmp_path: Path
) -> None:
    provider = make_provider(settings_store, tmp_path)
    app = create_app(provider, access_token=ACCESS_TOKEN, refresh_on_start=False)
    headers = AUTH_HEADERS
    with TestClient(app) as client:
        project = client.get("/api/v1/projects", headers=headers).json()["items"][0]
        identifier = project["id"]
        updated = client.patch(
            f"/api/v1/projects/{identifier}",
            json={"favorite": True, "tags": ["focus"], "notes": "Local note", "archived": True},
            headers=headers,
        )
        assert updated.status_code == 200
        stored = client.get("/api/v1/projects", headers=headers).json()["items"][0]
        assert stored["favorite"] is True
        assert stored["tags"] == ["focus"]
        assert stored["archived"] is True
        exported = client.get("/api/v1/configuration/export", headers=headers).json()
        assert exported["schema_version"] == 5
        assert "notes" not in exported["projects"][0]
        export_with_notes = client.get(
            "/api/v1/configuration/export?include_notes=true", headers=headers
        ).json()
        assert export_with_notes["projects"][0]["notes"] == "Local note"
        preview = client.post(
            "/api/v1/configuration/import/preview",
            json={"payload": export_with_notes},
            headers=headers,
        )
        assert preview.status_code == 200
        backup = client.post("/api/v1/backups", headers=headers)
        assert backup.status_code == 200
        backup_id = backup.json()["id"]
        history = client.get("/api/v1/system/history", headers=headers)
        assert history.status_code == 200
        restored = client.post(f"/api/v1/backups/{backup_id}/restore", headers=headers)
        assert restored.status_code == 200
