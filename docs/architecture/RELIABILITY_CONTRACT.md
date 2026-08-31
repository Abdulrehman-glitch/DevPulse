# Reliability contract

This contract governs the DevPulse-owned persistence, scanner, local-core lifecycle, and diagnostic boundaries introduced for `0.3.0`. It covers the documented public `0.3.0` state; it is not a promise of perpetual compatibility with undocumented pre-1.0 files.

## Persisted data ownership

| Format | Owner and location | Version and validation | Failure, migration, and rollback |
| --- | --- | --- | --- |
| Settings | Python local core, `settings.json` in DevPulse application data | Pydantic `Settings`, `schema_version: 5`, unknown fields forbidden | Schemas 2–4 validate in memory, receive one `settings.pre-migration-vN.json` copy, and are atomically replaced. Malformed current data may recover from `settings.last-known-good.json`; a forensic `settings.corrupt-*.json` copy is retained. Future, invalid-version, and unknown-field data is preserved as `settings.unsupported-*.json`, left untouched, and blocks writes. A failed replace leaves the source authoritative for retry. |
| Last-known-good settings | Python local core, `settings.last-known-good.json` | Same settings schema and validation path | Updated atomically only from a validated current file. It is recovery input, not an independent user format. |
| Activity history | Python local core, `activity/events-v1.json` | Envelope `version: 1`; every event is validated | Writes use atomic replacement and retain at most 1,000 events. Corrupt input is copied to `events-v1.corrupt-*.json` before a new history is written. Future versions are copied, left untouched, and write-blocked until the user explicitly clears the history or compatible software reads it. |
| Repository snapshot cache | Python local core, `cache/repositories-v1.json` | Envelope `version: 1`; every repository snapshot is validated | This is reproducible cache state. Writes are atomic. Corrupt input is preserved before regeneration. Future versions are preserved and write-blocked for the process; scanning continues in memory without overwriting them. |
| Configuration exports and backups | Python local core, user-selected export payload or `backups/<id>.json` | Export `schema_version: 5`; imports accept documented schemas 3–5, reject unknown settings, and validate the final model | DevPulse-owned backups use atomic writes. Import is validate-before-save. Deleting a backup is an explicit user operation. Files outside DevPulse application data are never mutated as a migration side effect. |
| Local logs | Python local core, `logs/local-core.log` plus three rotations | Structured JSON lines; 2 MB per file | Local-only rotating diagnostics. They are not uploaded. Safe diagnostic exports do not copy free-form messages. |
| Lifecycle trace | Rust desktop parent, `logs/lifecycle-state.jsonl` plus one previous file | Bounded JSON-line events with fixed state names and redacted detail | Rotated at 256 KiB. Session tokens, addresses, filesystem paths, and credentials are rejected or redacted before persistence. |
| Window state | Tauri window-state plugin in its platform application-data location | Owned and versioned by the pinned plugin, not by the Python schema | Disabled in QA mode. DevPulse does not migrate this third-party format. Removing it resets window placement only. |
| QA path/checkpoint evidence and artificial test lab | Release QA harness under the validated disposable `DEVPULSE_QA_ROOT` | Versioned JSON evidence used only by QA | Disposable runner evidence. QA startup refuses missing, linked, repository-backed, or mismatched roots and never falls back to production data. |

Python production JSON persistence helpers place a unique temporary file beside the destination, flush it, and use an operating-system replace. A failed operation removes only its owned temporary file. No migration follows links or writes outside the resolved DevPulse data root.

Legacy terminal `commands` mappings are preserved in the pre-migration copy but are deliberately not copied into writable schema-5 settings because DevPulse no longer executes configured project commands. This is the only supported-field retirement in the documented migration set. Rollback is manual: stop DevPulse, retain the current file, and restore the matching pre-migration copy before running an older build. An older build must never be pointed at schema 5 in place.

## Scanner boundary

Production starts with no scan roots. A root is accepted only when it is an existing absolute canonical directory outside filesystem roots, the user profile root, DevPulse application data, and symbolic-link or Windows junction components. Each queued descendant is resolved again immediately before inspection. A changed root, disappearing path, or descendant that resolves beyond the approved canonical root is skipped with a non-sensitive diagnostic code.

Discovery excludes configured dependency, build, generated, cache, VCS, environment, and IDE directories. Depth, directory count, entry count, repository count, and wall-clock time are independently bounded. Repository Git commands are read-only, disable optional locks and prompts, have a per-command timeout, and truncate the displayed changed-path set. Permission errors and concurrent filesystem mutation produce partial results rather than expanding the boundary.

## Local-core lifecycle

The Rust parent is the sole owner of the local-core child and its in-memory session token. The observable lifecycle is `starting`, `ready`, `recovering`, `failed`, or `stopped`. Startup readiness and authenticated health are time-bounded. An unexpected exit, readiness failure, startup timeout, or two consecutive authenticated health failures schedules at most two automatic attempts with bounded backoff. The attempt count, limit, safe failure code, and user action are visible to the frontend.

Automatic and manual recovery terminate only the exact child DevPulse owns. Packaged Windows children remain assigned to the kill-on-close Job Object. Shutdown invalidates pending recovery, requests authenticated local shutdown, waits for a bounded interval, and then terminates only the retained child handle if necessary. There is no process-name or global kill path.

The session token remains in parent and child memory only. It is sent once through anonymous stdin and later in loopback request headers; it is absent from argv, environment variables, readiness frames, disk handshake files, lifecycle traces, diagnostic exports, and user-facing messages.

## Cross-layer failure rule

Migration or scanner failure cannot broaden sidecar permissions or trigger destructive recovery. The local core may return safe defaults or partial scan results while the authenticated process remains healthy. A true process or authenticated-health failure uses the same bounded parent recovery lifecycle. Recovery reopens DevPulse-owned state through the validation rules above, so unsupported state remains write-blocked and scanner roots are revalidated after every restart.
