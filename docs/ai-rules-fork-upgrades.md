# Controlled ai_rules_1c upgrades

## Current state

The workflow template is pinned to the controlled fork release
`itl-main-a421cf44-r7` at commit
`7f6d4cc68adfb6ada6d8e67ec4327cabbf3d0428`. Its upstream provenance is the
explicit snapshot `refs/heads/main` at
`a421cf44eb1f5859cf2a2b74884f8fbcaefc4826`. The moving `upstream/main` name is
never consumed by projects.

## Fork release intake

Prefer a real upstream tag. If upstream continues to publish only `main`, pass
the full 40-character SHA of its current remote tip explicitly:

```powershell
git ls-remote upstream refs/heads/main
.\scripts\new-upstream-upgrade.ps1 `
  -UpstreamCommit <40-character-sha> -UpstreamBranch main
```

Review the generated intake report, classify every downstream patch as `keep`,
`drop`, or `rewrite`, adapt the official installer, and run the fork Full gate.
After review, preview with `publish-fork-release.ps1 -WhatIf`, then publish once
with `-Push`. A full SHA is resolved only during intake; projects use only the
resulting immutable annotated `itl-*` tag and exact fork commit.

## Workflow activation

Only a reviewed workflow release changes `templates/project.json` to the fork
repo and annotated `itl-*` tag. `templates/dependency-lock.json` must contain the
same tag and exact fork commit plus upstream ref/commit, downstream revision and
`compatibilityStatus: passed`.

Once `aiRules.ref` is present, `dependencyMode=fresh` does not advance aiRules:
`update-ai-rules` reinstalls the configured tag and verifies its commit. Other
dependencies continue to follow the normal fresh/locked policy.

## Existing projects

`update-workflow` supports two automatic transitions:

1. a standard legacy `comol/ai_rules_1c` project to the verified fork baseline;
2. an earlier controlled fork `itl-*` revision to a strictly newer verified
   downstream revision (currently including `r6` to `r7`).

Both transitions require:

- the installed commit and manifest are recorded;
- `.ai-rules.json` exists and has no `userModified` entries;
- clients are limited to Codex/Kilo;
- the target workflow template contains verified fork provenance;
- the installed upstream provenance is an ancestor of the target upstream
  baseline (fork release commits are never compared to one another);
- the candidate has project-local shared skills and no user-scope Codex paths.

The candidate is installed in a temporary project first. Before applying it,
ITL snapshots config, lock, manifest, root guidance and Codex/Kilo/agent
directories under `.agent-1c/runs/`. Any failure restores those paths. Custom
repositories are preserved; modified or ambiguous projects require manual
review. `-SkipAiRules` leaves an eligible migration explicitly pending.

Legacy global `~/.codex/prompts` are reported by the fork migration but are not
automatically deleted because they are shared user-scope files.

For a controlled-fork transition, the project repo and lock repo must both
match the controlled fork, the current ref must be `itl-*`, and the target
`downstreamRevision` must be greater than the installed revision. A custom repo,
missing provenance, or any manifest `userModified` entry produces a recovery
status plus `.agent-1c/runs/.../recovery-report.json` instead of an automatic
migration or regular ai_rules update. Active `itldev/*` branches are not
silently advanced by this mechanism.
