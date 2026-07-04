---
description: Update the installed ITL workflow package in an existing project
agent: code
---

Update managed ITL workflow files, refresh `ai_rules_1c` by default, and report follow-up commands for MCP and active development branches.

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action update-workflow
```

Run this from the project `master` worktree only. The helper refuses to run from `itldev/*` worktrees and prints the main worktree path when it can infer it.

Optional source overrides:

```powershell
$env:ITL_WORKFLOW_SOURCE_PATH = "D:\Git\1c-agent-workflow"
$env:ITL_WORKFLOW_REPO = "https://github.com/xmentosx/1c-agent-workflow.git"
$env:ITL_WORKFLOW_REF = "master"
```

Use `-SkipAiRules` only when the developer explicitly wants to update the workflow package without refreshing upstream `ai_rules_1c`.

After the helper finishes, review and commit the tracked changes. For active `itldev/*` worktrees, merge the updated `master` intentionally or run `/itl-refresh` from each branch worktree. For MCP, rerun `/itl-vibecoding1c-mcp`; when branch-local Vanessa MCP is used, run `/itl-vanessa-mcp` with stop, install, then start in that branch worktree.
