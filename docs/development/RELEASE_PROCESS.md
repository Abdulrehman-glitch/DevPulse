# Release process

Only the maintainer approves a release. This procedure prepares releases; it does not authorize repository visibility, a tag, or publication by itself.

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
4. Build the sidecar and production application. Store installers, executables, raw logs, and machine-specific reports only in private ignored output.
5. Inspect the installer without executing it. Record hashes, unsigned/signing state, bundled runtime, notices, and source commit.
6. Perform install, upgrade, uninstall, rollback, and residue testing only in an isolated Windows environment approved for lifecycle testing.
7. Review the complete history for secrets, personal identity, private paths, disputed media, workflows, tags, and prohibited artifacts.

## Tag and publish

After all required repository rules, CI checks, vulnerability reporting, code-signing status, provenance, SBOM, and human go/no-go gates pass, create the immutable `v*` tag through the release procedure. Build from that exact tag, verify artifact digests, and publish one prerelease with accurate limitations and rollback instructions.

Never reuse, move, or recreate historical private tags. Never replace an asset beneath an existing release. If validation fails, do not tag; fix through a reviewed commit and rerun the complete gate.
