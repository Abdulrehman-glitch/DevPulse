# DevPulse

DevPulse is a Windows desktop application for reviewing local development projects and system health from one interface. A React frontend runs inside Tauri; a desktop-owned Python local core performs project discovery, repository inspection, diagnostics, and system sampling through an authenticated loopback API.

## Status

DevPulse is an alpha-stage, initially private publication candidate prepared as `0.3.0-alpha.1`. It is not a production support promise, and contributions are not accepted while staging remains private.

This Git history starts with a curated pre-public baseline. Historical development and versions through `v0.2.0-beta.1` remain in a preserved private archive and are not recreated here. No public release has been issued from this history. See [PUBLICATION_STATUS.md](PUBLICATION_STATUS.md).

## Supported platform

The supported target is 64-bit Windows. The current build uses Tauri 2, the Microsoft WebView2 runtime already present on supported Windows systems, and a packaged CPython local-core sidecar. Cross-machine Windows compatibility and installer install/uninstall lifecycle testing remain pre-release gates; macOS and Linux are not currently supported claims.

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

Current limitations include unsigned Windows artifacts, no updater, no public CI, no completed clean-machine installer lifecycle validation, a single maintainer, and an interim visual identity. No screenshot is included because the staging run did not need to launch the full desktop product to establish authenticity.

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

Contribution intake is closed during private staging. Once the repository is public, proposed work will follow the issue-first, focused-pull-request, review, testing, and DCO-style sign-off process in [CONTRIBUTING.md](CONTRIBUTING.md).

Do not disclose suspected vulnerabilities in an ordinary issue. GitHub private vulnerability reporting will be enabled and verified as an immediate public-launch gate; follow [SECURITY.md](SECURITY.md) for the accurate current route.

## Roadmap and licence

See [ROADMAP.md](ROADMAP.md) for direction without unsupported delivery dates. DevPulse source and documentation are licensed under [Apache License 2.0](LICENSE). Third-party components retain their own terms in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Project names and visual identity are addressed separately in [TRADEMARKS.md](TRADEMARKS.md).

