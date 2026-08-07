## 1C Agent Workflow Bridge

Read `USER-RULES.md` for project-specific workflow notes.

Explicit generated `itl-*` skills run alone; do not preload either workflow router.

For routine natural-language lifecycle requests, use only `.agents/skills/1c-workflow-fast/SKILL.md`.

Use `.agents/skills/1c-workflow/SKILL.md` plus one matching reference only for initialization, unclear development routing, unusual topology, helper-directed recovery without an explicit wrapper, or detailed explanation.

Keep `.dev.env`, `.agent-1c/dev-branches/*.json`, `.agent-1c/event-log-baselines/*.json`, downloaded tools, logs, local infobases, and result artifacts out of Git.
