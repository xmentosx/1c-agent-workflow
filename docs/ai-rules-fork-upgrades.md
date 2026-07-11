# Controlled ai_rules_1c upgrades

## Current state

Until upstream publishes a release tag, the workflow template remains on the
legacy upstream repository and `aiRules.ref` is empty. Migration code is dormant
in this state. `upstream/main` is not accepted as a fork release base.

## Fork release intake

In `D:\Git\itl_ai_rules_1c`, create the upgrade branch only from a real tag:

```powershell
.\scripts\new-upstream-upgrade.ps1 -UpstreamTag <upstream-tag>
```

Review the generated intake report, classify every downstream patch as `keep`,
`drop`, or `rewrite`, adapt the official installer, and run the fork Full gate.
After review, publish an immutable tag with `publish-fork-release.ps1`.

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

