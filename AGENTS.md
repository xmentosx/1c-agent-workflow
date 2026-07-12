# ITL Workflow Repository Instructions

## Scope

These instructions govern development of the `1c-agent-workflow` source repository. They are not installed-project guidance. Never add this root `AGENTS.md` to bootstrap or `update-workflow` managed-copy lists. Installed projects receive their root agent instructions from the configured `ai_rules_1c` release and the ITL overlay in `USER-RULES.md`.

## Ownership boundaries

- ITL owns project bootstrap and lifecycle, `/itl*`, local MCP client configuration, verification, result export, and the five `.agents/skills` directories in this repository.
- The controlled `ai_rules_1c` fork owns its rules, agents, general/OpenSpec skills, OpenSpec commands, installer manifest, and immutable release tags. Change that repository through a separate upgrade/release branch; never patch an installed copy here.
- Kilo `itl*.md` files are generated from `.agents/skills/1c-workflow/kilo-command-templates` and remain ignored. Do not add `.kilocode` or tracked generated `.kilo/commands/itl*.md` files.

## Change discipline

- Fix shared package code, templates, docs, and tests rather than patching an example project.
- Preserve unrelated user changes and keep the dirty-state guards strict.
- Prefer script-owned prompts, sequencing, recovery, and state transitions. Do not duplicate helper-owned flows in agent prose.
- Keep secrets and runtime state out of Git: `.dev.env`, local infobases, downloaded tools, run state, logs, and client MCP config stay ignored.
- Keep entrypoint instructions compact and route detail to the relevant reference. Do not load or duplicate the full lifecycle when a targeted helper or reference is sufficient.

## Verification

- During development run `scripts/check.ps1 -Mode Fast` for the short loop.
- Before a PR run `scripts/check.ps1 -Mode Full`; pass `-AiRulesSource <controlled-fork-checkout>` when changing the integration boundary. Follow `docs/local-quality-gate.md` for release-only checks.
- Do not weaken the Vanessa completion gate, fresh passed `/itl-check`, snapshot rollback, or artifact SHA checks.
- Tests must leave tracked state unchanged. A passing gate with a dirty worktree is not a release qualification.

## Routing

- Installed-project lifecycle: `.agents/skills/1c-workflow/SKILL.md` and its matching reference only.
- Package bootstrap contract: `AGENT-INSTALL.md` and `install-agent-1c-workflow.ps1`.
- Controlled fork intake and migration: `docs/ai-rules-fork-upgrades.md`.
- Local and release gates: `docs/local-quality-gate.md` and `docs/release-checklist.md`.
