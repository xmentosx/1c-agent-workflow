---
name: 1c-workflow-fast
description: Run routine 1C Agent Workflow lifecycle commands through the PowerShell helper with minimal context loading. Use for status, configuration or extension development branch creation, branch base update, verification, refresh, CF/CFE result export, close, and branch switching when the project is already installed.
---

# 1C Workflow Fast

## Purpose

Use this skill for routine lifecycle commands when the project already contains the standard `1c-workflow` files. The fast path keeps agent work small: map the user request to one helper action, run the helper, and report the result.

Do not open the full workflow references before normal lifecycle execution. Open detailed references only when the helper fails, reports missing setup values, or the user asks for an explanation.

## Intent Map

- show ITL status: `status`
- create new configuration development branch: `new-dev-branch`
- create new extension development branch: `new-extension-dev-branch`
- update current development branch infobase from branch files: `update-dev-branch-base`
- verify current branch through update plus Vanessa tests: `verify-dev-branch`
- refresh current development branch from master/source: `refresh-dev-branch`
- export CF or CFE result from current development branch: `export-dev-branch-result`
- close current development branch: `close-dev-branch`
- switch to master: `switch-master`
- switch to development branch: `switch-dev-branch`

## Command Template

Run commands from the project root:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action <action>
```

For actions that require a branch name:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-dev-branch -DevBranchName "<dev-branch-name>"
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action new-extension-dev-branch -DevBranchName "<dev-branch-name>"
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action switch-dev-branch -DevBranchName "<dev-branch-name>"
```

For `update-dev-branch-base`, `verify-dev-branch`, `refresh-dev-branch`, `export-dev-branch-result`, and `close-dev-branch`, do not ask for a branch name. The helper infers it from the current `itldev/<name>` Git branch.

For branch verification, do not call `/deploy-and-test` in the normal fast path. Run `verify-dev-branch`; it updates the branch base partially and then runs Vanessa Automation.

## Failure Handling

If the helper exits with an error:

1. Report the action that failed.
2. Report the concise error text.
3. Report the latest log path when the helper prints one.
4. Ask for only the missing value when the helper clearly identifies one.
5. Use the full `1c-workflow` skill only for detailed recovery, unusual topology, or init questionnaire work.

For first-time project bootstrap, follow `AGENT-INSTALL.md`. This fast skill is optimized for regular branch operations after installation.
