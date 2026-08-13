# DevPulse

DevPulse is a Windows desktop application for reviewing local development projects and system health from one interface. A React frontend runs inside Tauri; a desktop-owned Python local core performs project discovery, repository inspection, diagnostics, and system sampling through an authenticated loopback API.

## Status

DevPulse is an alpha-stage public project on the `0.3.0-alpha.1` release line. It is not yet a production support promise.

This Git history starts with a curated pre-public baseline. Historical development and versions through `v0.2.0-beta.1` remain in a preserved private archive and are not recreated here. Public release provenance begins with the curated `v0.3.0-alpha.1` line. See [PUBLICATION_STATUS.md](PUBLICATION_STATUS.md).

## Supported platform

The supported target is 64-bit Windows. The current build uses Tauri 2, the Microsoft WebView2 runtime already present on supported Windows systems, and a packaged CPython local-core sidecar. Release installers must pass install, smoke, uninstall, reinstall, and residue checks on a disposable GitHub-hosted Windows runner. macOS and Linux are not currently supported claims.

## Capabilities

- discovers and registers local development projects within configured boundaries;
- summarizes repository state and detected technologies without changing project files;
- presents system, project-health, activity, diagnostics, and settings views;
- keeps application data and logs in DevPulse-owned locations;
- provides an explicit QA mode whose writable paths must remain inside one validated sandbox root.

## Architecture

The desktop parent generates an ephemeral API token and starts the Python local core as an owned child. It sends the token once through anonymous child stdin, receives a non-secret readiness frame through stdout, validates the selected loopback port and instance identifier, and performs an authenticated health check before the frontend can use the API.

The local core binds only to `127.0.0.1`. Production endpoints require the session token. The token exists in parent and child process memory while the core runs; it is not placed in argv, environment variables, disk handshakes, logs, or reports. This protects against accidental and unrelated local callers, not against an administrator, malware, or an equivalent-privilege process that can inspect DevPulse memory.

See [the system overview](docs/architecture/SYSTEM_OVERVIEW.md), [startup protocol](docs/architecture/LOCAL_CORE_STARTUP.md), and [threat model](docs/security/THREAT_MODEL.md).

## Privacy and limitations

DevPulse is local-first and does not include a hosted SaaS implementation. Project information is processed locally. Diagnostic exports can still contain project names or paths and must be reviewed before sharing. The scanner is intended to be read-only, but hostile filesystem races and a compromised same-user process are outside its security boundary.

Current limitations include unsigned Windows artifacts, no updater, a single maintainer, an interim visual identity, and a Windows-only support claim. Release artifacts are alpha quality and require a preinstalled WebView2 runtime.

## Development

Use the versions pinned in `.node-version`, `.python-version`, and `rust-toolchain.toml`.

```powershell
npm ci
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --no-deps -r requirements-ci.lock
npm run versions:check
```

Common validation commands are:

```powershell
npm run format:check
npm run lint
npm run typecheck
npm test
npm run build
.\.venv\Scripts\python.exe -m ruff check .
.\.venv\Scripts\python.exe -m pytest
cargo test --locked --manifest-path apps/desktop/src-tauri/Cargo.toml
```

Full setup, testing, and release instructions are in [docs/development](docs/development/SETUP.md).

## Contributions and security

Proposed work follows the issue-first, focused-pull-request, review, testing, and DCO-style sign-off process in [CONTRIBUTING.md](CONTRIBUTING.md).

Do not disclose suspected vulnerabilities in an ordinary issue. Use GitHub private vulnerability reporting as described in [SECURITY.md](SECURITY.md).

## Roadmap and licence

See [ROADMAP.md](ROADMAP.md) for direction without unsupported delivery dates. DevPulse source and documentation are licensed under [Apache License 2.0](LICENSE). Third-party components retain their own terms in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Project names and visual identity are addressed separately in [TRADEMARKS.md](TRADEMARKS.md).
