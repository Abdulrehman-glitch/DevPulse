import socket

from devpulse_core.config import SettingsStore
from devpulse_core.models import Settings
from devpulse_core.providers.local import LocalDataProvider


def test_default_local_operation_attempts_no_outbound_network(app_paths, monkeypatch) -> None:
    """Fail closed if representative default operation opens any client socket."""
    attempts: list[object] = []

    def reject_connect(_socket: socket.socket, address: object) -> None:
        attempts.append(address)
        raise AssertionError("Unexpected network connection attempted")

    monkeypatch.setattr(socket.socket, "connect", reject_connect)
    SettingsStore(app_paths).save(Settings())
    provider = LocalDataProvider(SettingsStore(app_paths))

    assert provider.refresh(force=True) == []
    diagnostics = provider.safe_diagnostics_export()
    assert "X-DevPulse-Token" not in diagnostics
    assert attempts == []
