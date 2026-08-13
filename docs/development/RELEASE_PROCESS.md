# Release process

Only the maintainer approves a release. This procedure does not authorize a tag or publication by itself.

## Version update

1. Set the SemVer value in `VERSION`.
2. Run `npm run versions:sync`.
3. Run `npm run versions:check` and inspect the diff.

`scripts/sync-version.mjs` is authoritative for npm workspace manifests and lock metadata, the Rust package and lock entry, Tauri configuration, Python package and runtime metadata, API metadata, UI fallbacks, tests, and release scripts.

For `0.3.0-alpha.1`, Windows resources that require four numeric fields use `0.3.0.1`; the user-facing product version remains `0.3.0-alpha.1`. This mapping must be explicit in artifact evidence and must not relabel the prerelease as a stable build.

## Candidate validation

1. Start from reviewed `main` with a clean worktree and locked toolchains.
2. Install dependencies from lockfiles and run every command in [TESTING.md](TESTING.md).
3. Regenerate asset hashes, dependency licences, notices, vulnerability evidence, API contract, and any approved SBOM.
4. Build the sidecar and production application. Store local executables, raw logs, and machine-specific reports only in ignored output.
5. Inspect the installer without executing it. Record hashes, unsigned/signing state, bundled runtime, notices, and source commit.
6. Dispatch `.github/workflows/release-qa.yml` with the full 40-character intended release commit. The workflow and selected commit must resolve to the same SHA.
7. Require authentic NSIS install, authenticated smoke, uninstall, reinstall, final cleanup, runtime-only CycloneDX SBOM generation, checksum creation, and installer attestation on the standard GitHub-hosted Windows runner.
8. Review the complete history and candidate assets for secrets, personal identity, private paths, disputed media, workflow policy, tags, and prohibited artifacts.

## Tag and publish

After all required repository rules, CI checks, vulnerability reporting, code-signing status, provenance, SBOM, and release-QA gates pass, create an annotated immutable `v*` tag at the already validated commit. Verify the tag target and artifact digests, then publish one prerelease with accurate limitations and rollback instructions.

Never reuse, move, or recreate historical private tags. Never replace an asset beneath an existing release. If validation fails, do not tag; fix through a reviewed commit and rerun the complete gate.
