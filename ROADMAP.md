# Roadmap

This roadmap describes direction, not fixed delivery dates or commitments.

## Current staging and publication work

- complete the Phase 1D human go/no-go review;
- transition the repository name and visibility without importing private history;
- enable cost-controlled public CI and then activate reviewed branch and tag rulesets;
- enable and verify private vulnerability reporting;
- validate installer install, upgrade, uninstall, and residue behavior in an isolated Windows environment;
- publish `0.3.0-alpha.1` only after every launch gate passes.

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

