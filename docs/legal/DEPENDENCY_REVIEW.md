# Dependency review

This review is generated deterministically from the committed npm and Cargo lockfiles, Cargo metadata filtered for the Windows target, and installed Python distribution metadata from the pinned validation environment.

## Summary

- Components: 668
- npm: 315
- Cargo: 309
- Python: 44
- Runtime: 321
- Build/development: 347

The old aggregate UNKNOWN result is not used. Every component has an individual declaration, scope, evidence hash where available, and publication classification in `dependency-licences.json`.

## Classification policy

- `RESOLVED COMPATIBLE`: a declared permissive licence compatible with distribution under the project licence.
- `REVIEWED WITH NOTICE`: a compatible licence with specific attribution or file-level obligations recorded in notices.
- `DEVELOPMENT-ONLY`: not part of the shipped runtime graph for the supported Windows target.
- `RUNTIME REVIEW REQUIRED`: unresolved or potentially copyleft runtime terms; publication is blocked until resolved.
- `REPLACE BEFORE PUBLICATION`: incompatible or source-available runtime terms; publication is blocked.
- `TOOLING LIMITATION`: metadata is insufficient for a non-runtime tool and is listed explicitly.

## Items requiring attention

No component remains in `RUNTIME REVIEW REQUIRED`, `REPLACE BEFORE PUBLICATION`, or `TOOLING LIMITATION`.

## Review conclusions

The generated inventory is a technical compliance aid, not legal advice. Permissive dependencies remain subject to their own notice conditions. MPL-2.0, CC-BY, and similar entries are retained with explicit notice classification rather than being described as unknown. Build and development tools are separated from the runtime graph.

Before a release, regenerate this inventory after any lockfile change, review the classification diff, run all ecosystem vulnerability checks, and include `THIRD_PARTY_NOTICES.md` with distributed artifacts. The installer must not ship any component that is absent from the locked inventory.
