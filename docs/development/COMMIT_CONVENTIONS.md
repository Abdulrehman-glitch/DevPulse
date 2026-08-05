# Commit conventions

Use a short Conventional Commit subject in the imperative mood:

```text
type(optional-scope): concise outcome
```

Supported types include `feat`, `fix`, `security`, `docs`, `test`, `build`, `refactor`, `perf`, `chore`, `legal`, and `revert`. Use a body for rationale, risk, migration behavior, provenance, or evidence that is not obvious from the diff.

Keep commits focused and linear. Do not create merge commits in release preparation, mix mechanical formatting with behavioral work, or rewrite a commit after its hash has been recorded in audit evidence without regenerating that evidence.

Contributed commits require DCO-style sign-off with `git commit -s`. Do not use a private consumer identity in public history; use a verified GitHub no-reply identity or another intentionally public address.

Branch names follow the patterns in [CONTRIBUTING.md](../../CONTRIBUTING.md). Release commits prepare metadata and evidence; tags are created only by the reviewed release procedure.

