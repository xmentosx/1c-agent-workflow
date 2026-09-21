# ITL Workflow Repository Instructions

## Scope

These rules govern the `1c-agent-workflow` source repository; they are not installed-project guidance. Never add this root `AGENTS.md` to bootstrap or `update-workflow` managed-copy lists. Installed projects use the configured `ai_rules_1c` release plus `USER-RULES.md`.

Within this Git root, `1c-workflow` and `1c-workflow-fast` are package source. Do not activate them for source-repository maintenance. Use them only to operate a separate installed project whose root the user identifies.

## Ownership boundaries

- ITL owns project bootstrap and lifecycle, `/itl*`, MCP client config, verification, export, and the managed repo skills.
- The controlled `ai_rules_1c` fork owns upstream rules, agents, skills, commands, its manifest, and tags. Change it only in that repo on an upgrade/release branch; never patch an installed copy.
- Kilo `itl*.md` comes from `.agents/skills/1c-workflow/kilo-command-templates` and stays ignored. Do not add `.kilocode` or generated `.kilo/commands/itl*.md`.

## Change discipline

- Fix shared package code, templates, docs, and tests rather than patching an example project.
- Optimize for the simplest coherent architecture, not diff size or abstraction count. One invariant has one authoritative owner; converge duplicated policy. Shared stateless contracts, cross-component refactors, and existing-coordinator use are normal within authority. Before widening shared runtime authority, cross-owner state/blocking/recovery, installed migration, elevation, support reduction, or material always-on context, obtain architecture checkpoint in `docs/package-architecture.md`; file count is not a trigger. After two repair cycles without acceptance or owner-narrowing progress, stop layering; compare rollback, owner-local, and shared redesign.
- Preserve unrelated user changes and keep the dirty-state guards strict.
- A normal source change is accumulated for `develop`. On a clean local `develop`, fetch and fast-forward `origin/develop` without asking. For concurrent tasks use an isolated worktree; never mix two tasks in one dirty checkout.
- Finish one coherent local commit, then run `scripts/source-delivery.ps1 -Action RegisterChange`. Registration owns the one `Targeted` run and writes an atomic local base/head queue ref only after it passes. Do not push, open a PR, or run `Smoke`, `Full`, `Develop`, or `Release` for an ordinary change.
- Use `scripts/source-delivery.ps1 -Action Status` to inspect the shared queue and cumulative gate ledger in the common Git directory; never rerun merely to recover timing.
- If executable behavior changed without a test file change, pass the existing owner id through `-CoverageContract`. A missing test change and missing reusable contract blocks registration; do not add a test merely to satisfy a count.
- Prefer script-owned prompts, sequencing, recovery, and state transitions. Do not duplicate helper-owned flows in agent prose.
- Before adding or changing runtime checks, follow the blocking policy in `docs/package-architecture.md`.
- Treat a failing regression or E2E as evidence of a product, workflow, fixture, or environment defect. Fix the owning implementation; never make the gate pass by weakening assertions or changing the reproducer's path, topology, workload, or preconditions so the defect is no longer reached. Change a test contract only after concrete evidence proves the expectation itself is invalid, and retain an equivalent regression for the originally observed failure.
- Treat every user-controlled Windows path as containing whitespace and Cyrillic together. Use shared quoting helpers for native command lines and serialized connection arguments, and establish explicit UTF-8 before decoding native output. Mojibake in surfaced or persisted stdout/stderr is a failed transport boundary, not evidence: reproduce it through the shared child-process helper and retain an exact Unicode round-trip regression using one whitespace-and-non-ASCII path.
- Treat Git path lists as NUL-delimited data: use `git -c core.quotepath=false ... -z` through the shared path-list helper, never parse newline-delimited or C-quoted Git path output.
- Treat `src/cf/**` and `src/cfe/**` as byte-preserving 1C transport. The installed-project managed `.gitattributes` block owns `-text` for these trees; do not replace it with LF/CRLF normalization. Introduce or repair the contract only together with an authoritative dump/index rebuild and the one-time branch transition merge.
- Treat cross-process operation names as one contract across validation, dispatch, broker calls, guard classification, and tests. Nested broker operations inherit the signed execution context; a set-completeness regression must prove they cannot reacquire or expand its guard.
- Route workflow-owned 1C launches through the per-infobase guard; direct `Start-Process` bypasses `ONEC_MAX_CONCURRENT_SESSIONS`.
- Run monitored bootstrap in the foreground with `timeout_ms >= 3900000`. On interruption repeat the same bootstrap command; never delete `index.lock`, finish lifecycle manually, or edit `status.json`.
- Keep secrets/runtime out of Git: `.dev.env`, infobases, tools, state, logs, and client MCP config stay ignored.
- Keep entrypoints compact and route detail to one relevant reference; do not load or duplicate the full lifecycle.
- Normal installed operation runs without elevation in local and terminal sessions on Windows 10, Windows 11, and Windows Server 2019+. Admin provisioning is optional; never auto-elevate or weaken isolation. Keep always-on instructions, tool schemas, and routine output bounded and on demand; minimize tokens without weakening goals, safety, diagnostics, or evidence.

## Context budget

- Start from Routing and targeted `rg`; open one matching contract or reference and needed ranges. Widen one layer only for a concrete gap; stop when evidence suffices. Do not bulk-read skills, docs, tests, or outputs.
- Browse or use MCP only when external or current state is required; read ignored runtime only for a named run or artifact. Documentation budgets protect routing and readability. Never delete, weaken, or telegraphically compress safety, verification, or behavioral contracts merely to pass a budget. Remove duplication or route detail first; if necessary meaning exceeds a hard limit, propose an explicit limit change with a short rationale.

## Verification

- Read-only source maintenance does not run `Targeted`, `Smoke`, `Full`, `Develop`, or `Release`; use focused non-mutating evidence only.
- Batch directly owned tests following `docs/local-quality-gate.md`; avoid unchanged reruns. Do not run a broad gate merely because a chat is ending. `Fast` is a deprecated alias for `Smoke` and is never the normal source-development step.
- Publish accumulated `develop` with `scripts/source-delivery.ps1 -Action PublishDevelop` and the exact fork/E2E stand. It integrates the queue, qualifies and finalizes an installable candidate; add `-RequireRelease` when master must remain unchanged. "Publish" never implies master; see `docs/local-quality-gate.md`.
- Passed `Develop` already contains exact-tree Full/static proof. Never run separate `Full` for that tree.
- Reuse a passed Targeted/Full Pester shard only when owner inputs, inventory, locks, checker/runtime versions, controlled-fork identity, and Vanessa build identity match; unknown ownership disables reuse.
- Follow delivery timeout/recovery and UTF-8 rules in `docs/local-quality-gate.md`; never bypass locks.
- For a non-empty queue going to both channels, use `scripts/source-delivery.ps1 -Action PromoteRelease`; it reuses one candidate's Develop/Release proof. Use `scripts/source-delivery.ps1 -Action ReleaseMaster` only when the queue is empty and local `develop` equals `origin/develop`. Retain server support. Absent stand/`server-reset` evidence is unverified, never blocks publication, and permits no direct push. If code blocks, fix workflow/tests/docs.
- Do not tag or publish an `itl-ondemand-mcp` component build from Targeted proof. Its exact source commit and executable SHA must pass the real `ondemand-mcp` Release E2E stage for both backend families; fixture evidence and unrelated prior runs are not release qualification.
- Do not ask which gate to run unless the user overrides this model. Failure, conflict, remote movement, timeout, or no-progress preserves the queue/checkpoint and forbids publication. The same stage failure twice requires diagnosis before an explicit `-RetryBlockedStage`.
- Do not weaken the Vanessa completion gate, fresh passed `/itl-check`, snapshot rollback, or artifact SHA checks.
- Tests must leave tracked state unchanged. A passing gate with a dirty worktree is not a release qualification.

## Routing

- Installed-project lifecycle: `.agents/skills/1c-workflow/SKILL.md` and its matching reference only.
- Package bootstrap contract: `AGENT-INSTALL.md` and `install-agent-1c-workflow.ps1`.
- Controlled fork intake and migration: `docs/ai-rules-fork-upgrades.md`.
- Source package layout and ownership: `docs/package-architecture.md`.
- Local and release gates: `docs/local-quality-gate.md` and `docs/release-checklist.md`.
