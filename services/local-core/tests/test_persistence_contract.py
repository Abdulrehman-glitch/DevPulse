import json

from devpulse_core.activity import ActivityStore
from devpulse_core.config import SettingsStore
from devpulse_core.models import Settings
from devpulse_core.providers.local import LocalDataProvider


def test_future_activity_schema_is_preserved_and_not_overwritten(app_paths) -> None:
    app_paths.ensure()
    original = '{"version":2,"events":[{"future":true}]}'
    app_paths.activity.write_text(original, encoding="utf-8")
    store = ActivityStore(app_paths.activity)

    assert store.load() == []
    assert store.write_blocked is True
    assert store.save([]) is False
    assert app_paths.activity.read_text(encoding="utf-8") == original
    assert list(app_paths.activity.parent.glob("events-v1.unsupported-*.json"))


def test_future_repository_cache_is_preserved_during_refresh(app_paths) -> None:
    app_paths.ensure()
    SettingsStore(app_paths).save(Settings())
    cache = app_paths.cache / "repositories-v1.json"
    original = {"version": 2, "repositories": [{"future": True}]}
    cache.write_text(json.dumps(original), encoding="utf-8")

    provider = LocalDataProvider(SettingsStore(app_paths))
    assert provider.refresh(force=True) == []
    assert json.loads(cache.read_text(encoding="utf-8")) == original
    assert list(app_paths.cache.glob("repositories-v1.unsupported-*.json"))


def test_corrupt_activity_and_cache_are_preserved_before_recovery(app_paths) -> None:
    app_paths.ensure()
    app_paths.activity.write_text("{malformed", encoding="utf-8")
    cache = app_paths.cache / "repositories-v1.json"
    cache.write_text("{malformed", encoding="utf-8")
    SettingsStore(app_paths).save(Settings())

    provider = LocalDataProvider(SettingsStore(app_paths))
    provider.refresh(force=True)

    assert list(app_paths.activity.parent.glob("events-v1.corrupt-*.json"))
    assert list(app_paths.cache.glob("repositories-v1.corrupt-*.json"))
    assert json.loads(app_paths.activity.read_text(encoding="utf-8"))["version"] == 1
    assert json.loads(cache.read_text(encoding="utf-8"))["version"] == 1
