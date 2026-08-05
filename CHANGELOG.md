# Changelog

All notable changes to the curated public-history candidate will be documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Established an initially private, curated pre-public staging baseline.
- Added Apache-2.0 licensing, branding boundaries, asset provenance, dependency notices, and governance documentation.
- Added deterministic multi-ecosystem dependency compliance generation.
- Added a project-owned interim geometric application mark.

### Changed

- Prepared application and package metadata for `0.3.0-alpha.1`.
- Updated PostCSS, GitPython, and validation pip pins to remediate advisory findings.
- Replaced the incomplete lockfile-only SBOM generator with deterministic CycloneDX output derived from the reviewed dependency inventory.

### Fixed

- Made packaged-sidecar event monitoring exhaustive so the release-mode desktop build compiles and fails closed on unsupported startup events.
- Aligned the integrated local-validation command with the curated repository's workflow-free, installer-free staging policy.

### Security

- Replaced command-line and disk-handshake token transfer with a bounded, versioned anonymous-stdin launch protocol and non-secret readiness frame.
- Added a current threat model and local-core startup protocol documentation.

Versions through `v0.2.0-beta.1` belong to the preserved private pre-public archive and are not recreated in this history.
