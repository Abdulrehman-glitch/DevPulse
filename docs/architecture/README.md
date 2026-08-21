# Architecture

DevPulse is split into a Tauri desktop parent, a React frontend, a Python local-core child, and shared TypeScript contracts.

- [SYSTEM_OVERVIEW.md](SYSTEM_OVERVIEW.md) defines components, ownership, data flow, writable paths, and external boundaries.
- [LOCAL_CORE_STARTUP.md](LOCAL_CORE_STARTUP.md) defines the versioned stdin/readiness protocol and failure behavior.
- [RELIABILITY_CONTRACT.md](RELIABILITY_CONTRACT.md) defines persisted schemas, migrations, scanner containment, recovery states, and diagnostic rules.
- [The threat model](../security/THREAT_MODEL.md) defines the same-user security boundary and remaining limitations.

Material architecture changes should update these sources of truth and record the tradeoff in the governing issue or a future architecture decision record.
