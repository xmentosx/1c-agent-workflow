# Controlled ai_rules_1c upgrades

## Current state

The workflow template is pinned to the controlled fork release
`itl-main-a421cf44-r1` at commit
`dc9a767f0cb77418bcae3c52521594b183c1b879`. Its upstream provenance is the
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

`update-workflow` automatically migrates only a standard legacy project when:

- its repository is `comol/ai_rules_1c`;
- the legacy commit is recorded;
- `.ai-rules.json` exists and has no `userModified` entries;
- clients are limited to Codex/Kilo;
- the target workflow template contains verified fork provenance;
- the legacy commit is an ancestor of the target upstream baseline;
- the candidate has project-local shared skills and no user-scope Codex paths.

The candidate is installed in a temporary project first. Before applying it,
ITL snapshots config, lock, manifest, root guidance and Codex/Kilo/agent
directories under `.agent-1c/runs/`. Any failure restores those paths. Custom
repositories are preserved; modified or ambiguous projects require manual
review. `-SkipAiRules` leaves an eligible migration explicitly pending.

Legacy global `~/.codex/prompts` are reported by the fork migration but are not
automatically deleted because they are shared user-scope files.
