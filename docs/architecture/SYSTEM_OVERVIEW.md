# System overview

## Components

`apps/desktop/src` contains the React user interface. It renders project, system, activity, diagnostics, and settings views and calls Tauri commands; it does not start or authenticate the local core directly.

`apps/desktop/src-tauri` contains the Rust desktop shell. It owns application lifecycle, single-instance behavior, window policy, application paths, child-process creation and cleanup, the ephemeral session token, and authenticated loopback requests.

`services/local-core/devpulse_core` contains the Python service. It validates settings and paths, discovers configured projects, reads repository and system state, maintains DevPulse-owned activity/configuration data, emits redacted diagnostics, and serves the local API.

`packages/shared-types` contains frontend-facing shared TypeScript contracts. `services/local-core/openapi/v1.json` is the generated API contract checked by validation.

## Runtime flow

```text
React UI
   │ Tauri invoke
   ▼
Rust desktop parent ── anonymous stdin launch frame ──▶ Python local core
   │                                                      │
   └── authenticated HTTP on 127.0.0.1:<ephemeral> ◀─────┘
```

The Rust parent constructs the loopback URL from a validated readiness port and retains the token in process memory. The frontend receives connection data only through trusted Tauri commands. Startup must pass versioned frame validation and an authenticated health check.

## Read and write boundaries

The local core reads only configured project roots and system information required by product features. Project scanning is intended to be read-only; DevPulse must never alter an external repository’s Git state, files, remotes, or settings.

Production writes are limited to DevPulse-owned application configuration, cache, activity, and log locations. QA mode is stricter: `DEVPULSE_QA_MODE=1`, an explicit canonical `DEVPULSE_QA_ROOT`, and matching data/environment paths are all required before startup. Every QA writable path must remain below that root.

Build outputs, virtual environments, package caches, sidecar binaries, installers, databases, logs, and test results are ignored and must not enter source history. Release artifacts are produced from a reviewed tag into private output before publication.

## External boundaries

The application has no hosted SaaS implementation in this repository. Dependency installation and advisory checks contact their official registries or advisory sources during development; the product’s local project workflow does not require a DevPulse cloud service.

Opening a project path is limited to a currently registered canonical directory. External links, updater behavior, plugins, telemetry submission, and remote administration are not implicit capabilities and require separate design and threat review.

