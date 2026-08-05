# Testing

Run checks from a clean worktree with locked dependencies. Redirect caches and build output to an isolated workspace when preparing release evidence.

## Frontend

```powershell
npm run format:check
npm run lint
npm run typecheck
npm test
npm run build
npm audit --omit=dev
npm audit
```

## Python local core

```powershell
.\.venv\Scripts\python.exe -m ruff format --check .
.\.venv\Scripts\python.exe -m ruff check .
.\.venv\Scripts\python.exe -m pytest
.\.venv\Scripts\python.exe -m pip check
```

Use an isolated `pip-audit` tool to scan the installed validation environment. Token-handoff tests cover bounded launch input, timeout, malformed and oversized data, legacy argument rejection, non-secret readiness, log leakage, authenticated health, and shutdown.

## Rust and packaging configuration

```powershell
cargo fmt --check --manifest-path apps/desktop/src-tauri/Cargo.toml
cargo check --locked --manifest-path apps/desktop/src-tauri/Cargo.toml
cargo clippy --locked --manifest-path apps/desktop/src-tauri/Cargo.toml --all-targets -- -D warnings
cargo test --locked --manifest-path apps/desktop/src-tauri/Cargo.toml
npm run tauri:check
```

Use an isolated `cargo-audit` binary and the RustSec database. Review target-excluded informational warnings separately from packages in the supported Windows graph.

## Publication checks

Regenerate dependency compliance, scan the complete Git history for credentials and personal identity, reject prohibited artifact types, validate every documentation link and JSON/YAML file, compare all version locations, and verify no workflow directory exists during private staging.

Installer execution is not part of ordinary local validation. Install/uninstall lifecycle testing must use an isolated Windows environment and the documented human gate; never test an installer against a normal user profile merely to make a build pass.

