# Changelog

All notable changes to the curated public-history candidate will be documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Established an initially private, curated pre-public staging baseline.
- Added Apache-2.0 licensing, branding boundaries, asset provenance, dependency notices, and governance documentation.
- Added deterministic multi-ecosystem dependency compliance generation.
- Added a final project-owned pulse-aperture identity with deterministic SVG-to-PNG/ICO generation and Windows shell sizes from 16 through 256 pixels.
- Added an actionable repository attention queue, human-readable repository state vocabulary, scan freshness, and recent repository activity to the Overview.
- Added status-led repository details with compact warnings, Git state, recent commits, changed-file names, health signals, and local-only project metadata.
- Added fixture-driven regression coverage for structured NSIS archive inspection.

### Changed

- Promoted application, package, installer, release-QA, and artifact metadata from the public `0.3.0-alpha.1` baseline to the final `0.3.0` keeper release.
- Updated PostCSS, GitPython, and validation pip pins to remediate advisory findings.
- Replaced the incomplete lockfile-only SBOM generator with deterministic CycloneDX output derived from the reviewed dependency inventory.
- Reworked the desktop shell, typography, spacing, surfaces, focus states, motion, empty states, and light/dark themes around a restrained signal-teal identity.
- Replaced the wide project dashboard table with a dense desktop repository view that keeps project, state, branch/upstream, sync, local changes, and last activity visible without horizontal scrolling at supported widths.
- Demoted machine utilisation to secondary context behind repository health and activity.

### Fixed

- Made packaged-sidecar event monitoring exhaustive so the release-mode desktop build compiles and fails closed on unsupported startup events.
- Aligned the integrated local-validation command with the curated repository's workflow-free, installer-free staging policy.
- Restored the content shell to the top when navigating between app views or opening repository details.
- Corrected NSIS inspection to identify the structured 7-Zip `Type = Nsis` metadata record and validate its physical size instead of treating an optional outer `Path` field as the absolute installer path.

### Security

- Replaced command-line and disk-handshake token transfer with a bounded, versioned anonymous-stdin launch protocol and non-secret readiness frame.
- Added a current threat model and local-core startup protocol documentation.
- Preserved fail-closed installer payload verification: exactly one desktop executable, packaged local core, and uninstaller are required, and every unexpected executable remains a hard failure.

Versions through `v0.2.0-beta.1` belong to the preserved private pre-public archive and are not recreated in this history.
