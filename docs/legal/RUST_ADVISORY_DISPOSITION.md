# Rust advisory disposition for v0.3.0

## Current audit

On 2026-08-21, `cargo-audit 0.22.2` against the locked graph reported **zero known vulnerabilities**. RustSec reports five informational unmaintained warnings in the supported Windows graph:

| Advisory            | Package                    |
| ------------------- | -------------------------- |
| `RUSTSEC-2025-0081` | `unic-char-property 0.9.0` |
| `RUSTSEC-2025-0075` | `unic-char-range 0.9.0`    |
| `RUSTSEC-2025-0080` | `unic-common 0.9.0`        |
| `RUSTSEC-2025-0100` | `unic-ucd-ident 0.9.0`     |
| `RUSTSEC-2025-0098` | `unic-ucd-version 0.9.0`   |

RustSec classifies these as unmaintained and lists no patched `0.9.x` releases. That maintenance status increases future exposure; it is not evidence of a known exploit in DevPulse.

## Exact dependency path

The shared supported path is `DevPulse -> Tauri 2.11.5 / tauri-build 2.6.3 -> tauri-utils 2.9.3 -> urlpattern 0.3.0 -> unic-ucd-ident 0.9.0`. From there:

- `unic-ucd-ident -> unic-char-property -> unic-char-range`;
- `unic-ucd-ident -> unic-char-range` directly; and
- `unic-ucd-ident -> unic-ucd-version -> unic-common`.

`cargo tree --locked --target x86_64-pc-windows-msvc -i <package>` confirms each package remains in the Windows graph. GTK3/glib and `proc-macro-error` audit warnings are not present in that target-specific tree and do not support a Windows release claim.

## Narrow-upgrade investigation

The latest published `tauri-utils 2.9.3` requires `urlpattern ^0.3`; `urlpattern 0.3.0` is the only compatible published selection. A dry-run precise update to `urlpattern 0.6.0` fails dependency resolution rather than producing a safe lockfile change.

Upstream Tauri changed `tauri-utils` to `urlpattern 0.6` in [commit `dd725f4`](https://github.com/tauri-apps/tauri/commit/dd725f4b13c30a86b398ccc59eb498f151f461c5) on 2026-07-06, after the latest `tauri-v2.11.5` release. That upstream lock diff removes all five `unic-*` crates, but no compatible Tauri release containing the change is available as of this review. Pinning an unpublished Tauri commit or forking Tauri for this maintenance warning would expand release risk and is not approved.

The same audit identified target-excluded `event-listener 5.4.1` under the non-Windows `zbus` graph. A narrow compatible lock update to `event-listener 5.4.2` was available and applied, removing `RUSTSEC-2026-0221` without changing direct dependencies.

## v0.3.0 risk acceptance and follow-up

DevPulse accepts the five unmaintained Unicode packages for `v0.3.0` because there is no known vulnerability, no compatible released upstream removal, and the replacement is already present on Tauri's upstream branch. Release qualification must retain the exact tree/audit evidence, regenerate licensing/SBOM outputs after the narrow lock change, and pass the full Rust and application suites.

The next dependency-maintenance review should test the first stable Tauri release that includes `urlpattern 0.6` as a focused upgrade. It must inspect the complete lock diff, run `cargo audit`, regenerate notices/licence inventory/SBOM, execute the full Rust/frontend/Python validation, rebuild the application, and rerun Windows installer qualification. This is a scoped follow-up, not authorisation for a broad dependency sweep.
