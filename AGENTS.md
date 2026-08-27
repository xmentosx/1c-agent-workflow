# ITL Workflow Repository Instructions

## Scope

These rules govern the `1c-agent-workflow` source repository; they are not installed-project guidance. Never add this root `AGENTS.md` to bootstrap or `update-workflow` managed-copy lists. Installed projects use the configured `ai_rules_1c` release plus `USER-RULES.md`.

Within this Git root, `1c-workflow` and `1c-workflow-fast` are package source. Do not activate them for source-repository maintenance. Use them only to operate a separate installed project whose root the user identifies.

## Ownership boundaries

- ITL owns project bootstrap and lifecycle, `/itl*`, MCP client config, verification, export, and the five repo skills.
- The controlled `ai_rules_1c` fork owns upstream rules, agents, skills, commands, its manifest, and tags. Change it only in that repo on an upgrade/release branch; never patch an installed copy.
- Kilo `itl*.md` comes from `.agents/skills/1c-workflow/kilo-command-templates` and stays ignored. Do not add `.kilocode` or generated `.kilo/commands/itl*.md`.

## Change discipline

- Fix shared package code, templates, docs, and tests rather than patching an example project.
- Preserve unrelated user changes and keep the dirty-state guards strict.
- A normal source change is accumulated for `develop`. On a clean local `develop`, fetch and fast-forward `origin/develop` without asking. For concurrent tasks use an isolated worktree; never mix two tasks in one dirty checkout.
- Finish one coherent local commit, then run `scripts/source-delivery.ps1 -Action RegisterChange`. Registration owns the one `Targeted` run and writes an atomic local base/head queue ref only after it passes. Do not push, open a PR, or run `Smoke`, `Full`, `Develop`, or `Release` for an ordinary change.
- Use `scripts/source-delivery.ps1 -Action Status` to inspect the shared queue and cumulative gate ledger in the common Git directory; never rerun merely to recover timing.
- If executable behavior changed without a test file change, pass the existing owner id through `-CoverageContract`. A missing test change and missing reusable contract blocks registration; do not add a test merely to satisfy a count.
- Prefer script-owned prompts, sequencing, recovery, and state transitions. Do not duplicate helper-owned flows in agent prose.
- Before adding or changing runtime checks, follow the blocking policy in `docs/package-architecture.md`.
- Treat a failing regression or E2E as evidence of a product, workflow, fixture, or environment defect. Fix the owning implementation; never make the gate pass by weakening assertions or changing the reproducer's path, topology, workload, or preconditions so the defect is no longer reached. Change a test contract only after concrete evidence proves the expectation itself is invalid, and retain an equivalent regression for the originally observed failure.
- Treat every user-controlled Windows path as potentially containing whitespace and Cyrillic at the same time. Build native command lines and serialized connection arguments only through the shared quoting helpers, and set an explicit UTF-8 boundary before decoding native tool output. A focused path regression must exercise whitespace and non-ASCII text together in the same exact path; separate ASCII-space and Cyrillic-only cases are not sufficient.
- Treat Git path lists as NUL-delimited data: use `git -c core.quotepath=false ... -z` through the shared path-list helper, never parse newline-delimited or C-quoted Git path output.
- Treat `src/cf/**` and `src/cfe/**` as byte-preserving 1C transport. The installed-project managed `.gitattributes` block owns `-text` for these trees; do not replace it with LF/CRLF normalization. Introduce or repair the contract only together with an authoritative dump/index rebuild and the one-time branch transition merge.
- Treat cross-process operation names as one contract across entrypoint validation, dispatch, broker calls, lock classification, and tests. A nested broker operation inherits the facade runtime lease and must have a set-completeness regression proving that it cannot reacquire `runtime-mcp.lock`.
- Route workflow-owned 1C launches through the per-infobase guard; direct `Start-Process` bypasses `ONEC_MAX_CONCURRENT_SESSIONS`.
- Run monitored bootstrap in the foreground with `timeout_ms >= 3900000`. On interruption repeat the same bootstrap command; never delete `index.lock`, finish lifecycle manually, or edit `status.json`.
- Keep secrets/runtime out of Git: `.dev.env`, infobases, tools, state, logs, and client MCP config stay ignored.
- Keep entrypoints compact and route detail to one relevant reference; do not load or duplicate the full lifecycle.

## Context budget

- Start from Routing and targeted `rg` in likely owner paths. Open one matching contract or reference; read only matches or needed line ranges.
- Widen one layer only for a concrete gap; stop when evidence suffices. Do not bulk-read skills, docs, tests, build/runtime output, or an upstream checkout.
- Browse or use MCP only when external or current state is required. Read ignored runtime only for a named run or artifact.
- Documentation budgets protect routing and readability; they are not a mandate to minimize text at any cost. Never delete, weaken, or telegraphically compress safety, verification, or behavioral contracts merely to pass a budget. Remove actual duplication or route detail on demand first; if necessary content still exceeds a hard limit, propose an explicit limit change with a short rationale.

## Verification

- Read-only source maintenance does not run `Targeted`, `Smoke`, `Full`, `Develop`, or `Release`; use focused non-mutating evidence only.
- During edits run only the directly owned tests. Do not run a broad gate merely because a chat is ending. `Fast` is a deprecated alias for `Smoke` and is never the normal source-development step.
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
