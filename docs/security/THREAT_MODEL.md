# Threat model

## Scope and trust boundary

DevPulse is a single-user Windows desktop application. A Rust/Tauri parent owns a Python local-core child and communicates with it over an ephemeral HTTP port bound only to `127.0.0.1`. The application reads configured local project metadata and writes only its own application data, cache, logs, and explicit QA output.

The design protects the local API from unrelated web content and accidental unauthenticated callers. It does not claim to isolate secrets from malware, a debugger, an administrator, or another process already running with equivalent authority as the same Windows user. A same-user process that can inspect or modify DevPulse memory may still defeat the boundary.

## Local API credential

The Rust parent generates a fresh 256-bit hexadecimal session token in memory for each local-core start. It sends one versioned, size-bounded launch frame through the child’s anonymous stdin pipe. The token is not placed in process arguments, environment variables, temporary files, readiness files, logs, exception text, or generated reports.

The Python child reads exactly one launch frame before opening the server. Missing input times out; oversized, malformed, extra-field, weak-token, or unsupported-version input fails closed. The child emits one bounded readiness frame on stdout containing only protocol version, loopback port, process identifier, status, and instance identifier. Subsequent incidental stdout is redirected to stderr. The Rust parent validates the frame before making an authenticated health request.

The token remains in the memory of both processes while the local core runs because the desktop must authenticate each request. It expires when the owned process lifecycle ends. This is process-memory protection, not hardware-backed storage or an operating-system credential vault.

## Network and browser boundary

The local core binds only to IPv4 loopback and selects an ephemeral port. Every production endpoint, including health and shutdown, requires the session token. The desktop sends it in the `X-DevPulse-Token` request header. A strict Tauri content-security policy permits loopback connections needed by the desktop; the token is not stored in browser persistence.

Loopback binding alone is insufficient because unrelated local web pages may attempt requests to local services. Per-session authentication remains necessary even though the service is not reachable from another host.

## Filesystem and project data

Project scanning is read-only. Production has no default scan root. Configured roots and every queued descendant are re-canonicalised, symbolic links and Windows junctions are rejected, and depth, directories, entries, repositories, Git command duration, and displayed changed paths are bounded. Permission failures and concurrent changes return partial, non-sensitive results. QA mode requires one explicit canonical sandbox root. A same-user attacker, administrator, kernel component, or hostile filesystem driver remains outside this boundary.

## Process lifecycle and diagnostics

The parent tracks the exact child process. Packaged Windows builds place it in a kill-on-close Job Object; development builds retain and terminate the exact child handle. Startup, authenticated health, at most two automatic recovery attempts, and shutdown are bounded. Raw startup pipe contents are never written to diagnostics. Lifecycle traces redact secrets and paths; safe exports include only bounded codes and log severities, never free-form log messages. Users should still review diagnostic exports before sharing them.

## Out of scope and remaining limitations

- compromise of the Windows account, administrator, kernel, or DevPulse process;
- protection against memory inspection by an equivalent-privilege process;
- code signing and updater authenticity, which are not yet implemented;
- confidential vulnerability intake until GitHub private vulnerability reporting is enabled at public launch;
- claims beyond the explicitly tested Windows x64 compatibility matrix.
