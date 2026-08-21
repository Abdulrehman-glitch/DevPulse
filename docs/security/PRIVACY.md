# Privacy and network behaviour

DevPulse `0.3.0` is a local Windows desktop application. It has no account system, hosted telemetry, analytics, crash-report upload, updater, SaaS backend, or background source upload. These capabilities are not merely disabled by a preference; no runtime implementation for them exists in this release.

## Runtime network inventory

Default installed operation uses one documented network boundary: authenticated HTTP between the Rust desktop parent and its owned Python local core on an ephemeral IPv4 loopback address, `127.0.0.1`. The parent validates the address and port before health, lifecycle, project-registration, shutdown, or frontend API requests. The local core binds only to loopback and requires the per-process session token on every production endpoint.

Project discovery and repository inspection read local filesystem and Git metadata. They do not fetch remotes. Opening a registered project starts Windows Explorer after revalidating the local path. QA fixture fetches use an artificial local bare Git repository and are not production behaviour.

Development and release commands can contact the npm, PyPI, Cargo, GitHub, and vulnerability-advisory services named by those tools. That is maintainer activity, not application telemetry.

## Stored fields and retention

DevPulse application data contains non-secret settings, registered project display metadata and paths, a reproducible repository snapshot cache, local activity events, explicit configuration backups, and rotating local logs. The [reliability contract](../architecture/RELIABILITY_CONTRACT.md) identifies each format, schema, owner, recovery behaviour, and bound.

The application does not read application source-file bodies as part of repository status discovery. Technology checks may read up to 256 KB from recognised root dependency manifests such as `package.json`, `pyproject.toml`, and `requirements.txt`; they deliberately do not read `.env` files. Health checks otherwise inspect bounded names and metadata indicators. Git status returns changed path names, which stay in local process state and cache. Nothing uploads these values or file bodies.

Safe diagnostic exports contain application/OS version, QA flag, lifecycle and scan status, counts, schema version, a generic data-boundary label, bounded error codes, and log severity summaries. They exclude the session token, authentication headers, free-form log messages, source contents, repository paths, user-profile paths, remote URLs, and credentials. Users should still review any file before sharing it.

Users can remove projects, clear activity, delete explicit backups, or remove the per-user DevPulse application-data directory after DevPulse is stopped. Future-schema files are deliberately preserved rather than silently overwritten.

## Verification

The local-core privacy test replaces client-socket connection handling with a fail-closed observer while representative default provider startup, refresh, and diagnostics execute. Frontend and Rust tests reject non-loopback, credential-bearing, path-bearing, query-bearing, fragment-bearing, missing-port, and zero-port local-core addresses. Startup and lifecycle tests verify the session token never enters process arguments, environment capture, readiness data, traces, messages, or exported diagnostics.
