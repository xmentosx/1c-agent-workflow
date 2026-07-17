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
- Prefer script-owned prompts, sequencing, recovery, and state transitions. Do not duplicate helper-owned flows in agent prose.
- Run monitored bootstrap in the foreground with `timeout_ms >= 3900000`. On interruption repeat the same bootstrap command; never delete `index.lock`, finish lifecycle manually, or edit `status.json`.
- Keep secrets/runtime out of Git: `.dev.env`, infobases, tools, state, logs, and client MCP config stay ignored.
- Keep entrypoints compact and route detail to one relevant reference; do not load or duplicate the full lifecycle.

## Context budget

- Start from Routing and targeted `rg` in likely owner paths. Open one matching contract or reference; read only matches or needed line ranges.
- Widen one layer only for a concrete gap; stop when evidence suffices. Do not bulk-read skills, docs, tests, build/runtime output, or an upstream checkout.
- Browse or use MCP only when external or current state is required. Read ignored runtime only for a named run or artifact.

## Verification

- Read-only source maintenance does not run `Fast`, `Full`, or `Release`; use targeted non-mutating evidence commands only.
- During edits run only tests that directly cover the change. After a coherent change, run `scripts/check.ps1 -Mode Fast` once unless `Full` is next. Final delivery does not justify a gate; reuse fresh proof and never run `Fast` immediately before `Full`.
- Run `scripts/check.ps1 -Mode Full` once on the final tree only before a PR; add `-AiRulesSource <controlled-fork-checkout>` for integration-boundary changes. Run `Release` only for an explicit release; follow `docs/local-quality-gate.md`.
- Do not weaken the Vanessa completion gate, fresh passed `/itl-check`, snapshot rollback, or artifact SHA checks.
- Tests must leave tracked state unchanged. A passing gate with a dirty worktree is not a release qualification.

## Routing

- Installed-project lifecycle: `.agents/skills/1c-workflow/SKILL.md` and its matching reference only.
- Package bootstrap contract: `AGENT-INSTALL.md` and `install-agent-1c-workflow.ps1`.
- Controlled fork intake and migration: `docs/ai-rules-fork-upgrades.md`.
- Source package layout and ownership: `docs/package-architecture.md`.
- Local and release gates: `docs/local-quality-gate.md` and `docs/release-checklist.md`.
