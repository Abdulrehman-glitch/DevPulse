import io
import json
import sys
import threading
from pathlib import Path

import pytest
from devpulse_core import main as main_module
from devpulse_core.startup import (
    LAUNCH_PREFIX,
    MAX_LAUNCH_FRAME_BYTES,
    READY_PREFIX,
    STARTUP_PROTOCOL_VERSION,
    LaunchProtocolError,
    read_launch_message,
    readiness_frame,
)

TOKEN = "a" * 64


def launch_bytes(**changes: object) -> bytes:
    payload: dict[str, object] = {
        "protocol_version": STARTUP_PROTOCOL_VERSION,
        "token": TOKEN,
    }
    payload.update(changes)
    return LAUNCH_PREFIX + json.dumps(payload, separators=(",", ":")).encode() + b"\n"


def test_token_is_accepted_from_the_bounded_stdin_launch_channel() -> None:
    launch = read_launch_message(io.BytesIO(launch_bytes()))
    assert launch.protocol_version == STARTUP_PROTOCOL_VERSION
    assert launch.token == TOKEN


@pytest.mark.parametrize(
    "frame",
    [
        b"not-a-launch-frame\n",
        LAUNCH_PREFIX + b"not-json\n",
        launch_bytes(protocol_version=999),
        launch_bytes(extra=True),
        launch_bytes(token="weak"),
    ],
)
def test_malformed_launch_data_fails_closed_without_output(frame: bytes, capsys) -> None:
    with pytest.raises(LaunchProtocolError):
        read_launch_message(io.BytesIO(frame))
    captured = capsys.readouterr()
    assert TOKEN not in captured.out + captured.err


def test_oversized_launch_data_fails_closed() -> None:
    oversized = LAUNCH_PREFIX + b"{" + b"x" * MAX_LAUNCH_FRAME_BYTES + b"}\n"
    with pytest.raises(LaunchProtocolError, match="invalid"):
        read_launch_message(io.BytesIO(oversized))


class BlockingInput:
    def readline(self, _limit: int) -> bytes:
        threading.Event().wait(1)
        return b""


def test_missing_launch_data_times_out() -> None:
    with pytest.raises(LaunchProtocolError, match="timed out"):
        read_launch_message(BlockingInput(), timeout_seconds=0.01)  # type: ignore[arg-type]


def test_readiness_frame_is_versioned_bounded_and_non_secret() -> None:
    frame = readiness_frame(port=43210, process_id=42, instance_id="b" * 32)
    assert frame.startswith(READY_PREFIX)
    assert len(frame.encode()) < 512
    assert TOKEN not in frame
    assert "token" not in frame.lower()
    payload = json.loads(frame.removeprefix(READY_PREFIX))
    assert payload == {
        "instance_id": "b" * 32,
        "pid": 42,
        "port": 43210,
        "protocol_version": STARTUP_PROTOCOL_VERSION,
        "status": "ready",
    }


@pytest.mark.parametrize("option", ["--token", "--token=secret", "--handshake-file"])
def test_obsolete_secret_arguments_are_rejected_without_echo(
    option: str, monkeypatch, capsys
) -> None:
    monkeypatch.setattr(sys, "argv", ["devpulse-local-core", option, TOKEN])
    with pytest.raises(SystemExit) as stopped:
        main_module.main()
    assert stopped.value.code == 78
    captured = capsys.readouterr()
    assert TOKEN not in captured.out + captured.err


def test_rust_and_python_protocol_versions_agree() -> None:
    repository = Path(__file__).resolve().parents[3]
    lifecycle = (repository / "apps/desktop/src-tauri/src/lifecycle.rs").read_text(encoding="utf-8")
    assert f"const STARTUP_PROTOCOL_VERSION: u8 = {STARTUP_PROTOCOL_VERSION};" in lifecycle
    assert '"--token".to_string()' not in lifecycle
    assert '"--handshake-file".to_string()' not in lifecycle
