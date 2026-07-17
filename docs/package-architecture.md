# Workflow package architecture

This source-only document describes the package layout for maintainers. It is not copied into initialized projects.

- `.agents/skills/1c-workflow` owns the full lifecycle router, references, helper scripts, and generated client templates.
- `.agents/skills/1c-workflow-fast` owns the compact routine-operation surface.
- `.agents/skills/product-docs`, `itl-roctup-1c-data`, and `itl-vanessa-ui-mcp` own optional product/runtime integrations.
- `docs/itl-workflow` contains the human-facing documentation installed into projects.
- `templates` contains tracked project defaults, ignored-file additions, dependency locks, and project guidance overlays.
- `install-agent-1c-workflow.ps1` installs the managed package and starts monitored initialization.
- `scripts/check.ps1` and `scripts/test-ai-rules-compatibility.ps1` own source-repository qualification.

Client command files are generated from `.agents/skills/1c-workflow/kilo-command-templates`; generated `.kilo/commands/itl*.md`, `.claude/commands`, `.cursor/commands`, and `.opencode/command` assets are installed-project runtime state, not source files.

The controlled `ai_rules_1c` fork owns general rules, OpenSpec commands, agents, and its installer manifest. ITL owns bootstrap, lifecycle, local MCP configuration, executable verification, result export, and the five ITL skills. See `ai-rules-fork-upgrades.md` for the release boundary.

Managed source-only maintenance references:

- `local-quality-gate.md` — local Fast/Full checks;
- `ai-rules-fork-upgrades.md` — controlled-fork intake and migration;
- `release-checklist.md` — release-only 1C validation.
