import json
from pathlib import Path

from devpulse_core.config import SettingsStore
from devpulse_core.models import ProjectConfig, Settings


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


def test_terminal_configuration_is_migrated_in_memory(settings_store: SettingsStore) -> None:
    settings_store.paths.ensure()
    original = {
        "projects": [{"name": "Legacy", "path": "../legacy", "commands": {"Tests": "pytest"}}],
        "recursive_scan_roots": ["../projects"],
        "max_scan_depth": 2,
        "refresh_interval": 120,
        "max_commits": 7,
    }
    settings_store.paths.settings.write_text(json.dumps(original), encoding="utf-8")
    settings = settings_store.load()
    assert settings.maximum_scan_depth == 2
    assert settings.scan_roots[0].recursive is True
    migrated = json.loads(settings_store.paths.settings.read_text(encoding="utf-8"))
    assert migrated["schema_version"] == 4
    assert migrated["projects"][0]["path"] == "..\\legacy"
    assert "commands" not in migrated["projects"][0]
    assert settings_store.paths.data.joinpath("settings.pre-migration-v2.json").is_file()


def test_invalid_json_recovers_safe_defaults(settings_store: SettingsStore) -> None:
    settings_store.paths.ensure()
    settings_store.paths.settings.write_text('{"projects": [}', encoding="utf-8")
    recovered = settings_store.load()
    assert recovered == Settings()
    assert list(settings_store.paths.data.glob("settings.corrupt-*.json"))


def test_unknown_fields_recover_safe_defaults(settings_store: SettingsStore) -> None:
    settings_store.paths.ensure()
    settings_store.paths.settings.write_text('{"unexpected": true}', encoding="utf-8")
    assert settings_store.load() == Settings()


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
        "future_field": "ignored at migration boundary",
    }
    settings_store.paths.settings.write_text(json.dumps(original), encoding="utf-8")

    migrated = settings_store.load()
    assert migrated.schema_version == 4
    assert migrated.projects[0].favorite is True
    assert migrated.projects[0].tags == {"portfolio", "beta"}
    assert migrated.projects[0].notes == "Keep this local note"
    assert migrated.projects[0].archived is True
    assert migrated.notification_preferences == {"warning": False}
    assert migrated.saved_views[0].id == "attention"
    assert migrated.active_saved_view == "attention"
    assert "future_field" not in json.loads(settings_store.paths.settings.read_text())
    assert settings_store.paths.data.joinpath("settings.pre-migration-v3.json").is_file()

    second_store = SettingsStore(settings_store.paths)
    loaded_again = second_store.load()
    assert loaded_again == migrated
    assert second_store.migrated_from is None


def test_newer_configuration_is_refused_without_overwrite(settings_store: SettingsStore) -> None:
    settings_store.paths.ensure()
    newer = {"schema_version": 5, "projects": [{"name": "Newer", "path": "C:\\QA"}]}
    settings_store.paths.settings.write_text(json.dumps(newer), encoding="utf-8")

    loaded = settings_store.load()

    assert loaded == Settings()
    assert settings_store.downgrade_blocked is True
    assert json.loads(settings_store.paths.settings.read_text()) == newer
    assert list(settings_store.paths.data.glob("settings.unsupported-*.json"))
