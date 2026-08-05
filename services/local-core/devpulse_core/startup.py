"""Bounded, versioned startup protocol for the desktop-owned local core."""

from __future__ import annotations

import json
import queue
import re
import sys
import threading
from collections.abc import Sequence
from dataclasses import dataclass
from typing import BinaryIO

STARTUP_PROTOCOL_VERSION = 1
MAX_LAUNCH_FRAME_BYTES = 1024
LAUNCH_TIMEOUT_SECONDS = 5.0
LAUNCH_PREFIX = b"DEVPULSE_LAUNCH "
READY_PREFIX = "DEVPULSE_READY "
_TOKEN_PATTERN = re.compile(r"[0-9a-f]{64}")
_LEGACY_SECRET_OPTIONS = ("--token", "--handshake-file")


class LaunchProtocolError(ValueError):
    """A safe, non-secret startup-protocol failure."""


@dataclass(frozen=True)
class LaunchMessage:
    protocol_version: int
    token: str


def reject_legacy_secret_arguments(arguments: Sequence[str]) -> None:
    """Reject obsolete secret-bearing options without echoing their values."""
    for argument in arguments:
        if any(
            argument == option or argument.startswith(f"{option}=")
            for option in _LEGACY_SECRET_OPTIONS
        ):
            raise LaunchProtocolError("Obsolete local-core launch arguments were rejected.")


def _read_one_frame(stream: BinaryIO) -> bytes:
    frame = stream.readline(MAX_LAUNCH_FRAME_BYTES + 2)
    if not frame:
        raise LaunchProtocolError("Local-core launch data was not provided.")
    if len(frame) > MAX_LAUNCH_FRAME_BYTES or not frame.endswith(b"\n"):
        raise LaunchProtocolError("Local-core launch data exceeded its bound.")
    return frame[:-1]


def read_launch_message(
    stream: BinaryIO | None = None,
    *,
    timeout_seconds: float = LAUNCH_TIMEOUT_SECONDS,
) -> LaunchMessage:
    """Read exactly one secret launch frame from inherited stdin and fail closed."""
    source = stream if stream is not None else sys.stdin.buffer
    result: queue.Queue[bytes | None] = queue.Queue(maxsize=1)

    def read_worker() -> None:
        try:
            result.put(_read_one_frame(source))
        except Exception:
            result.put(None)

    threading.Thread(target=read_worker, name="devpulse-launch-reader", daemon=True).start()
    try:
        frame = result.get(timeout=timeout_seconds)
    except queue.Empty as error:
        raise LaunchProtocolError("Local-core launch data timed out.") from error
    if frame is None:
        raise LaunchProtocolError("Local-core launch data was invalid.")
    if not frame.startswith(LAUNCH_PREFIX):
        raise LaunchProtocolError("Local-core launch data used an invalid frame type.")
    try:
        payload = json.loads(frame[len(LAUNCH_PREFIX) :].decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise LaunchProtocolError("Local-core launch data was malformed.") from error
    if type(payload) is not dict or set(payload) != {"protocol_version", "token"}:
        raise LaunchProtocolError("Local-core launch data used an invalid schema.")
    if type(payload["protocol_version"]) is not int:
        raise LaunchProtocolError("Local-core launch protocol version was invalid.")
    if payload["protocol_version"] != STARTUP_PROTOCOL_VERSION:
        raise LaunchProtocolError("Local-core launch protocol version was unsupported.")
    token = payload["token"]
    if type(token) is not str or _TOKEN_PATTERN.fullmatch(token) is None:
        raise LaunchProtocolError("Local-core launch credential was invalid.")
    return LaunchMessage(protocol_version=payload["protocol_version"], token=token)


def readiness_frame(*, port: int, process_id: int, instance_id: str) -> str:
    """Create the sole non-secret machine-readable readiness frame."""
    if not 1 <= port <= 65535 or process_id <= 0 or not re.fullmatch(r"[0-9a-f]{32}", instance_id):
        raise LaunchProtocolError("Local-core readiness data was invalid.")
    payload = {
        "instance_id": instance_id,
        "pid": process_id,
        "port": port,
        "protocol_version": STARTUP_PROTOCOL_VERSION,
        "status": "ready",
    }
    return READY_PREFIX + json.dumps(payload, separators=(",", ":"), sort_keys=True)
