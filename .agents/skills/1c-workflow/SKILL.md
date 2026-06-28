---
name: 1c-workflow
description: Initialize and operate 1C configuration development projects with Git, a source infobase connected to a 1C configuration repository, feature infobase copies, optional Apache web publication, config dump/load, intermediate and final CF export, feature refresh from storage, and branch switching. Use when the user asks to init a 1C project, check required tools, start or finish a 1C feature, refresh a feature from master/storage, sync master from 1C storage, load changed config files into a feature base, prepare a CF, switch to master or a feature branch, or asks what 1C workflow commands are available.
---

# 1C Workflow

## Overview

Use this skill to run the standard lifecycle for agent-assisted 1C configuration development. The workflow is cross-agent: the same `.agents/skills/1c-workflow` directory works in Codex and Kilo Code, while Kilo-specific slash command wrappers can live in `.kilo/commands`.

## Intent Routing

Map user intent to one workflow:

- `HELP`: user asks what actions are available, asks for commands, asks for help, or runs `/1c`.
- `INIT_PROJECT`: user asks to initialize/bootstrap/create a 1C agent project.
- `CHECK_TOOLS`: user asks to check required software, setup, Git, 1C platform, Apache, or webinst.
- `START_FEATURE`: user asks to start or begin a feature, task, branch, customization, or subproject.
- `SYNC_MASTER`: user asks to refresh/sync master from 1C repository storage.
- `LOAD_FEATURE`: user asks to load current branch files into the feature infobase.
- `REFRESH_FEATURE`: user asks to update a feature branch from storage, refresh a feature with the latest master, or merge fresh storage changes into a feature.
- `EXPORT_FEATURE_CF`: user asks to make/export a CF for the current feature before full completion.
- `FINISH_FEATURE`: user asks to finish/complete a feature and prepare/export a CF.
- `SWITCH_MASTER`: user asks to switch to master.
- `SWITCH_FEATURE`: user asks to switch to a feature/subproject branch.
- `LIST_FEATURES`: user asks to list/show active features, features in development, or the current feature.

If intent is unclear, do not guess. Show the short menu from `references/workflow.md`.

## Required Reading

Before executing any lifecycle workflow, read `references/workflow.md`.

Use `scripts/agent-1c.ps1` when PowerShell is available. Prefer the script over retyping command-line calls because 1C Designer operations are fragile and benefit from deterministic logging and path checks.

## Operating Rules

Ask for missing required parameters at the start of the selected workflow. Do not ask for parameters that are already present in `.agent-1c/project.json` or `.dev.env`.

Use fixed project defaults: `master` is the main branch and `src/cf` is the configuration dump path. Do not ask the developer for these values during initialization.

Use the current working directory as the project root. During initialization, show its absolute path and ask the developer to confirm before continuing; do not ask them to enter a project path.

Do not ask whether to configure Codex or Kilo Code. Use the agent surface currently running the workflow; if it cannot be detected, use Codex as the fallback.

For `LOAD_FEATURE`, `REFRESH_FEATURE`, `EXPORT_FEATURE_CF`, and `FINISH_FEATURE`, infer the feature from the current `feature/<name>` branch. Only ask for or pass `FeatureName` when the current branch is not a feature branch and the action cannot be inferred.

Load feature files into 1C with a generated `-listFile` of changed files under `src/cf`; do not full-load the entire dump unless the user explicitly asks for a manual recovery path.

Never store passwords in Git, `AGENTS.md`, `USER-RULES.md`, or committed JSON. Store secrets only in local `.dev.env` or process environment variables.

Do not edit installer-managed `AGENTS.md` directly. Put project-specific workflow notes in `USER-RULES.md` or `.agent-1c/`.

Before switching branches, copying bases, dumping configuration files, or running 1C Designer, check the working tree and stop on unexpected uncommitted changes.

All feature changes load into the copied feature infobase. Never load feature changes directly into the source infobase connected to the 1C configuration repository.

When unlinking the feature copy from the 1C configuration repository, do not pass repository credentials or repository address. The unbind operation is local to the copy.

If any 1C command, Git command, or publication command fails, stop the workflow and report the log path.

## Script Usage

From the project root:

```powershell
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action help
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action init-project
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action start-feature -FeatureName "order-discounts"
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action load-feature
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action refresh-feature
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action export-feature-cf
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action finish-feature
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action switch-master
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action switch-feature -FeatureName "order-discounts"
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\agent-1c.ps1 -Action list-features
```

The script is a helper, not a substitute for judgment. If project topology is unusual, adapt conservatively and document the deviation in the final report.
