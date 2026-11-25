# Source publication rules

Read this before any publication action: `PublishDevelop`, `PromoteRelease`,
`ReleaseMaster`, a component release, or repair of a failed frozen publication.
An ordinary change ends at a passed `RegisterChange`. Publication runs only when
the user asks for it; once asked, carry that publication through, including
diagnosis and retries, without confirmation prompts. Detailed procedures live in
`docs/local-quality-gate.md`, `docs/release-checklist.md` and, for master
promotion, delivery cleanup, Develop retry and Release budgets,
`docs/source-publication-reference.md`.

## Develop

- Publish `develop` via `scripts/source-delivery.ps1 -Action PublishDevelop` with the exact fork/E2E stand: it integrates the queue, qualifies and finalizes an installable candidate without changing `master`. Missing owned assets select required Release capabilities; `-RequireRelease` selects the full catalog. See `docs/local-quality-gate.md`.
- Passed `Develop` already contains exact-tree Full/static proof. Never run separate `Full` for that tree.

## Master and components

- For a non-empty queue going to both channels, use `scripts/source-delivery.ps1 -Action PromoteRelease`; it reuses one candidate's Develop/Release proof. Use `scripts/source-delivery.ps1 -Action ReleaseMaster` only when the queue is empty and local `develop` equals `origin/develop`. Retain server support. Absent stand/`server-reset` evidence is unverified, never blocks publication, and permits no direct push. If code blocks, fix workflow/tests/docs.
- Do not tag or publish an `itl-ondemand-mcp` component build from Targeted proof. Its exact source commit and executable SHA must pass the real `ondemand-mcp` Release E2E stage for both backend families; fixture evidence and unrelated prior runs are not release qualification.

## Failure and repair

- Failure, conflict, remote movement, timeout, or no-progress preserves the queue/checkpoint and forbids publication.
- Repair a failed frozen publication through `scripts/source-repair.ps1`, not per-attempt registration.
