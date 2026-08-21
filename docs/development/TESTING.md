# Testing

Run checks from a clean worktree with locked dependencies. Redirect caches and build output to an isolated workspace when preparing release evidence.

`npm run validate:local` executes the integrated installer-free gate. It builds but does not launch the desktop executable and never executes an installer.

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
cargo check --release --locked --manifest-path apps/desktop/src-tauri/Cargo.toml
cargo clippy --locked --manifest-path apps/desktop/src-tauri/Cargo.toml --all-targets -- -D warnings
cargo test --locked --manifest-path apps/desktop/src-tauri/Cargo.toml
npm run tauri:check
npm run workflows:check
```

Use an isolated `cargo-audit` binary and the RustSec database. Review target-excluded informational warnings separately from packages in the supported Windows graph.

The manual `Windows compatibility` workflow builds and executes the authentic installer on the standard GitHub-hosted `windows-2022` and `windows-2025` x64 images. It also exercises WebView2 detection, spaces/non-ASCII paths, two process cultures, installed sidecar readiness, clean uninstall/reinstall, and the ephemeral TEST-certificate signing verifier. It uploads no workflow artifact. See [WINDOWS_COMPATIBILITY.md](WINDOWS_COMPATIBILITY.md).

## Publication checks

Regenerate dependency compliance, scan the complete Git history for credentials and personal identity, reject prohibited artifact types, validate every documentation link and JSON/YAML file, compare all version locations, and review every workflow for immutable action pins, least privilege, bounded runtime, and standard runners.

Installer execution is not part of ordinary local validation. Install/uninstall lifecycle testing is restricted by the harness to a GitHub-hosted disposable Windows runner; never test an installer against a normal user profile merely to make a build pass.
