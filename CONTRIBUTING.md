# Contributing

DevPulse accepts focused public issues and pull requests within the process below. The maintainer may narrow intake when review capacity is limited.

## Issue first

Open or join an issue before substantial work. The issue should define the problem, scope, non-goals, acceptance criteria, risk, and evidence. Suspected vulnerabilities must never be placed in an ordinary issue; use the route in [SECURITY.md](SECURITY.md).

Use these branch patterns:

- `feat/<issue>-<slug>`
- `fix/<issue>-<slug>`
- `refactor/<issue>-<slug>`
- `docs/<issue>-<slug>`
- `test/<issue>-<slug>`
- `release/<version>`

Do not use ordinary direct development on `main`. Never force-push to or delete `main`.

## Commits and sign-off

Use Conventional Commit subjects such as `feat:`, `fix:`, `docs:`, `test:`, `build:`, `refactor:`, and `chore:`. Keep commits reviewable and avoid unrelated formatting or dependency churn.

Every contributed commit must carry a Developer Certificate of Origin-style sign-off created with `git commit -s`. The `Signed-off-by` line records that the contributor has the right to submit the work under the project licence. DevPulse does not require a Contributor Licence Agreement or an external paid sign-off bot.

## Pull requests

A pull request should solve one focused problem and must:

- link the accepted issue;
- restate acceptance criteria and identify non-goals;
- describe security, privacy, compatibility, and release impact;
- include tests and reproducible evidence proportionate to risk;
- include screenshots only when genuinely relevant and sourced from authentic, privacy-reviewed application output;
- update documentation and changelog material when behavior changes;
- resolve review conversations before merge.

Security changes require threat-model consideration. Dependency changes require a narrow lockfile diff, licence-inventory regeneration, native vulnerability audits, and the full affected test suite. Workflow changes require an explicit cost and permissions review.

AI assistance does not replace review. Do not submit unreviewed AI-generated bulk changes. Disclose material AI assistance when it meaningfully shaped code, tests, documentation, or provenance so reviewers can direct attention appropriately.

## Acceptance and review

Acceptance requires passing format, lint, type, test, security, licence, prohibited-artifact, and production-build gates relevant to the change. The maintainer may request a smaller scope, additional evidence, or design discussion.

At least the maintainer reviews ordinary changes; security and release-critical changes require explicit maintainer approval. Squash merge is the default, and the branch is deleted after merge. A pull request is not accepted until required checks pass and all conversations are resolved.
