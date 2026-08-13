# Roadmap

This roadmap describes direction, not fixed delivery dates or commitments.

## Release engineering

- add Windows code signing without weakening key custody;
- expand disposable-runner compatibility coverage across supported Windows versions;
- validate upgrade and rollback behavior once a trustworthy prior public installer exists;
- keep release SBOM and artifact-attestation verification part of every public release gate.

## Reliability and architecture

- improve sidecar crash recovery and safe diagnostics;
- strengthen scanner containment, exclusions, and filesystem race handling;
- define stable configuration schemas and migration policy;
- design a signed updater and rollback model;
- expand cross-machine Windows compatibility testing.

## Project intelligence

- improve technology detection confidence and explainability;
- make health scoring transparent and configurable;
- refine activity and repository-state summaries without collecting hosted telemetry by default.

## User experience and onboarding

- improve first-run project selection and error recovery;
- expand keyboard, focus, contrast, and screen-reader validation;
- replace the interim mark with a final project-owned visual identity;
- improve documentation for privacy boundaries and diagnostic sharing.

## Extensibility

- define safe provider and plugin boundaries before exposing extension APIs;
- keep any future hosted service implementation separate from this local desktop repository;
- document compatibility and versioning expectations for external integrations.

## Stable 1.0 readiness

- complete signed release provenance, SBOM delivery, code signing, and updater verification;
- demonstrate reliable install/uninstall and data migration across supported Windows configurations;
- establish sustainable external-contributor review and security-response practices;
- resolve all release blockers and document a supported configuration contract.
