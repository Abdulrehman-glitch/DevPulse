# Local-core startup protocol

## Sequence

1. The Rust desktop resolves its application-data directory and generates a new 64-character hexadecimal token from two random UUID values.
2. It starts the Python local core with non-secret arguments only: loopback host, dynamic port, data directory, and the optional QA-mode flag. QA path variables may be supplied in the environment; the token is never an environment value.
3. The parent writes one UTF-8 line to the child’s anonymous stdin pipe:

   `DEVPULSE_LAUNCH {"protocol_version":1,"token":"<64 hexadecimal characters>"}`

4. The child reads at most 1,024 bytes with a five-second timeout. It accepts only the exact versioned schema and fails closed before binding a listener if validation fails.
5. The child binds `127.0.0.1` on an ephemeral port, constructs the authenticated application, and emits one UTF-8 readiness line:

   `DEVPULSE_READY {"instance_id":"<32 hexadecimal characters>","pid":1234,"port":43210,"protocol_version":1,"status":"ready"}`

6. The parent bounds the readiness frame to 512 bytes, rejects unknown or malformed fields, constructs the loopback URL itself, and verifies `/health` with the in-memory token and returned instance identifier.
7. Only after that health check does the desktop expose the ready connection to the frontend.

## Failure behavior

Missing, late, malformed, oversized, weak, or version-mismatched launch data exits without starting the server. Invalid or late readiness data causes the parent to terminate its owned child and report a non-secret error category. The legacy `--token` and `--handshake-file` options are rejected before argument parsing so their supplied values are not echoed.

Before readiness, the child may write exactly one bounded reason marker to stderr: `DEVPULSE_STARTUP_ERROR` followed by an allow-listed code for launch protocol, QA path boundary, QA failure injection, or access-credential validation. Unknown internal inputs collapse to `startup_validation`; exception text, paths, launch frames, and credential values are never included.

Packaged builds use a console-subsystem PyInstaller sidecar because windowed mode removes Python standard streams. Tauri starts that process with `CREATE_NO_WINDOW` and anonymous pipes, so no console window is shown. The parent retains the child handle and assigns the packaged process to a kill-on-close Windows Job Object.

No handshake file is created. Readiness is non-secret and remains on the inherited stdout channel. Application logs use stderr or the configured local log file after the single startup frame.

After initial readiness, the parent performs authenticated health checks. The connection state is `starting`, `ready`, `recovering`, `failed`, or `stopped`. An unexpected child exit, readiness failure, startup timeout, or repeated authenticated health failure can schedule at most two automatic recovery attempts, using 500 ms and 1.5 second backoff. Attempt number, limit, safe failure category, and a user action are observable; session credentials are not. A manual retry starts a new bounded sequence.

Shutdown invalidates scheduled recovery, requests authenticated loopback shutdown, and manages only the exact retained child. Packaged Windows children also remain in the parent's kill-on-close Job Object. DevPulse never terminates processes by global name.

## Protocol evolution

Rust and Python define protocol version `1` and test that the constants agree. Any incompatible schema change must increment both constants, update bounded parsers and tests, and document migration behavior. Unknown fields are rejected to prevent accidental secret reintroduction.
