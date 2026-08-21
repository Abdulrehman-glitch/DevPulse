import json
from pathlib import Path

import pytest
from devpulse_core import config as config_module
from devpulse_core import persistence
from devpulse_core.config import ConfigurationError, SettingsStore
from devpulse_core.models import ProjectConfig, Settings

FIXTURES = Path(__file__).parent / "fixtures" / "config"


def test_first_run_configuration_is_created_outside_installation(
    settings_store: SettingsStore,
) -> None:
    settings = settings_store.load()
    assert settings_store.paths.settings.exists()
    assert settings.projects == []
    assert settings_store.paths.settings.parent == settings_store.paths.data


def test_settings_round_trip(settings_store: SettingsStore, tmp_path: Path) -> None:
    project = tmp_path / "repository"
    settings_store.save(
        Settings(
            projects=[ProjectConfig(name="Repository", path=project)],
            refresh_interval_seconds=120,
            appearance="system",
        )
    )
    loaded = settings_store.load()
    assert loaded.projects[0].path == project
    assert loaded.refresh_interval_seconds == 120
    assert loaded.appearance == "system"


@pytest.mark.parametrize(
    ("fixture_name", "source_version"),
    [("v2-terminal.json", 2), ("v3-alpha.json", 3), ("v4-public-alpha1.json", 4)],
)
def test_supported_prior_configuration_fixtures_migrate_atomically(
    settings_store: SettingsStore, fixture_name: str, source_version: int
) -> None:
    settings_store.paths.ensure()
    original = json.loads((FIXTURES / fixture_name).read_text(encoding="utf-8"))
    settings_store.paths.settings.write_text(json.dumps(original), encoding="utf-8")
    settings = settings_store.load()
    assert settings.schema_version == 5
    migrated = json.loads(settings_store.paths.settings.read_text(encoding="utf-8"))
    assert migrated["schema_version"] == 5
    assert settings_store.paths.data.joinpath(
        f"settings.pre-migration-v{source_version}.json"
    ).is_file()
    assert settings_store.migrated_from == source_version


def test_invalid_json_recovers_safe_defaults(settings_store: SettingsStore) -> None:
    settings_store.paths.ensure()
    settings_store.paths.settings.write_text('{"projects": [}', encoding="utf-8")
    recovered = settings_store.load()
    assert recovered == Settings()
    assert list(settings_store.paths.data.glob("settings.corrupt-*.json"))


def test_unknown_fields_are_preserved_and_block_migration(settings_store: SettingsStore) -> None:
    settings_store.paths.ensure()
    original = '{"schema_version": 4, "unexpected": true}'
    settings_store.paths.settings.write_text(original, encoding="utf-8")
    assert settings_store.load() == Settings()
    assert settings_store.paths.settings.read_text(encoding="utf-8") == original
    assert settings_store.migration_blocked is True
    assert list(settings_store.paths.data.glob("settings.unsupported-*.json"))
    with pytest.raises(ConfigurationError, match="writes are blocked"):
        settings_store.save(Settings(refresh_interval_seconds=120))
    assert settings_store.paths.settings.read_text(encoding="utf-8") == original
    fresh_store = SettingsStore(settings_store.paths)
    with pytest.raises(ConfigurationError, match="unsupported fields"):
        fresh_store.save(Settings(refresh_interval_seconds=180))
    assert settings_store.paths.settings.read_text(encoding="utf-8") == original


def test_last_known_good_backup_recovers_malformed_json(settings_store: SettingsStore) -> None:
    settings_store.save(Settings(refresh_interval_seconds=120))
    settings_store.save(Settings(refresh_interval_seconds=240))
    settings_store.paths.settings.write_text("{broken", encoding="utf-8")
    assert settings_store.load().refresh_interval_seconds == 120


def test_alpha3_configuration_migrates_once_and_preserves_beta_metadata(
    settings_store: SettingsStore, tmp_path: Path
) -> None:
    settings_store.paths.ensure()
    original = {
        "schema_version": 3,
        "onboarding_completed": True,
        "projects": [
            {
                "name": "Preserved artificial project",
                "path": str(tmp_path / "registered"),
                "favorite": True,
                "tags": ["portfolio", "beta"],
                "notes": "Keep this local note",
                "archived": True,
            }
        ],
        "notification_preferences": {"warning": False},
        "notification_severity_threshold": "error",
        "saved_views": [
            {
                "id": "attention",
                "name": "Attention",
                "query": "",
                "status": "all",
                "technology": "all",
                "tag": "all",
                "warning": "with",
                "minimum_health": 0,
                "sort": "warnings",
                "favorites_only": False,
                "show_archived": False,
            }
        ],
        "active_saved_view": "attention",
    }
    settings_store.paths.settings.write_text(json.dumps(original), encoding="utf-8")

    migrated = settings_store.load()
    assert migrated.schema_version == 5
    assert migrated.projects[0].favorite is True
    assert migrated.projects[0].tags == {"portfolio", "beta"}
    assert migrated.projects[0].notes == "Keep this local note"
    assert migrated.projects[0].archived is True
    assert migrated.notification_preferences == {"warning": False}
    assert migrated.saved_views[0].id == "attention"
    assert migrated.active_saved_view == "attention"
    assert settings_store.paths.data.joinpath("settings.pre-migration-v3.json").is_file()

    second_store = SettingsStore(settings_store.paths)
    loaded_again = second_store.load()
    assert loaded_again == migrated
    assert second_store.migrated_from is None


def test_newer_configuration_is_refused_without_overwrite(settings_store: SettingsStore) -> None:
    settings_store.paths.ensure()
    newer = {"schema_version": 6, "projects": [{"name": "Newer", "path": "C:\\QA"}]}
    settings_store.paths.settings.write_text(json.dumps(newer), encoding="utf-8")

    loaded = settings_store.load()

    assert loaded == Settings()
    assert settings_store.downgrade_blocked is True
    assert json.loads(settings_store.paths.settings.read_text()) == newer
    assert list(settings_store.paths.data.glob("settings.unsupported-*.json"))


@pytest.mark.parametrize("invalid_version", [True, 0, -1, "5"])
def test_invalid_schema_version_is_preserved_without_overwrite(
    settings_store: SettingsStore, invalid_version: object
) -> None:
    settings_store.paths.ensure()
    original = {"schema_version": invalid_version, "projects": []}
    settings_store.paths.settings.write_text(json.dumps(original), encoding="utf-8")
    assert settings_store.load() == Settings()
    assert json.loads(settings_store.paths.settings.read_text(encoding="utf-8")) == original
    assert settings_store.migration_blocked is True


def test_interrupted_migration_keeps_validated_source_for_retry(
    settings_store: SettingsStore, monkeypatch: pytest.MonkeyPatch
) -> None:
    settings_store.paths.ensure()
    original = json.loads((FIXTURES / "v4-public-alpha1.json").read_text(encoding="utf-8"))
    settings_store.paths.settings.write_text(json.dumps(original), encoding="utf-8")
    real_atomic_write = config_module.atomic_write_json

    def fail_settings_commit(path: Path, payload: object) -> None:
        if path == settings_store.paths.settings:
            raise OSError("injected migration interruption")
        real_atomic_write(path, payload)

    monkeypatch.setattr(config_module, "atomic_write_json", fail_settings_commit)
    loaded = settings_store.load()
    assert loaded.schema_version == 5
    assert json.loads(settings_store.paths.settings.read_text(encoding="utf-8")) == original
    assert settings_store.migration_blocked is True
    assert settings_store.paths.data.joinpath("settings.pre-migration-v4.json").is_file()


def test_failed_atomic_save_preserves_previous_file_and_removes_temporary_file(
    settings_store: SettingsStore, monkeypatch: pytest.MonkeyPatch
) -> None:
    settings_store.save(Settings(refresh_interval_seconds=120))
    before = settings_store.paths.settings.read_bytes()

    def fail_replace(_source: object, _destination: object) -> None:
        raise OSError("injected replace failure")

    monkeypatch.setattr(persistence.os, "replace", fail_replace)
    with pytest.raises(OSError, match="injected replace failure"):
        settings_store.save(Settings(refresh_interval_seconds=240))
    assert settings_store.paths.settings.read_bytes() == before
    assert not list(settings_store.paths.data.glob(".settings.json.*.tmp"))


def test_stale_partial_file_is_never_adopted(settings_store: SettingsStore) -> None:
    settings_store.save(Settings(refresh_interval_seconds=120))
    partial = settings_store.paths.data / ".settings.json.interrupted.tmp"
    partial.write_text('{"schema_version":5,"refresh_interval_seconds":240', encoding="utf-8")
    assert settings_store.load().refresh_interval_seconds == 120
