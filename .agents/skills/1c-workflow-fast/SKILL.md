---
name: 1c-workflow-fast
description: Run routine 1C Agent Workflow lifecycle commands through the PowerShell helper with minimal context loading. Use for fast master sync, configuration or extension development branch creation, extension setup/dump, branch base update, refresh, CF/CFE result export, close, branch switching, and listing when the project is already installed.
---

# 1C Workflow Fast

## Purpose

Use this skill for routine lifecycle commands when the project already contains the standard `1c-workflow` files. The fast path keeps agent work small: map the user request to one helper action, run the helper, and report the result.

Do not open the full workflow references before normal lifecycle execution. Open detailed references only when the helper fails, reports missing setup values, or the user asks for an explanation.

## Intent Map

- initialize project quickly: `init-project`
- create new configuration development branch: `new-dev-branch`
- create new extension development branch: `new-extension-dev-branch`
- set extension name for current extension branch: `set-dev-branch-extension`
- dump current extension branch files: `dump-dev-branch-extension`
- activate current development branch context for ai_rules_1c commands: `activate-dev-branch-context`
- update current development branch infobase from branch files: `update-dev-branch-base`
- refresh current development branch from master/source: `refresh-dev-branch`
- export CF or CFE result from current development branch: `export-dev-branch-result`
- sync master from source infobase: `sync-master`
- close current development branch: `close-dev-branch`
- list development branches: `list-dev-branches`
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

For `set-dev-branch-extension`, pass `-ExtensionName "<extension-name>"`. For `activate-dev-branch-context`, `update-dev-branch-base`, `dump-dev-branch-extension`, `refresh-dev-branch`, `export-dev-branch-result`, and `close-dev-branch`, do not ask for a branch name. The helper infers it from the current `itldev/<name>` Git branch.

## Failure Handling

If the helper exits with an error:

1. Report the action that failed.
2. Report the concise error text.
3. Report the latest log path when the helper prints one.
4. Ask for only the missing value when the helper clearly identifies one.
5. Use the full `1c-workflow` skill only for detailed recovery, unusual topology, or init questionnaire work.

For first-time project bootstrap, run `init-project -InitMode wizard`; use `-InitMode json -InitAnswersPath <file>` for non-interactive automation. This fast skill is optimized for regular branch operations after installation.
