# Manual release gate

## One-time dedicated stand setup

1. Create `D:\Git\itl-workflow-e2e` from a safe non-production source infobase.
2. Initialize it with the normal ITL wizard; never point it at a production or
   source infobase that cannot be discarded.
3. Create a dedicated `itldev/workflow-release-e2e` worktree and database copy.
4. Add and commit a deterministic fixture change plus its Vanessa scenario.
5. Copy `templates/release-e2e.example.json` to the ignored local file
   `.agent-1c/release-e2e.json` and record the actual worktree path.
6. Run `/itl-check` once manually to prove the stand itself is healthy.

The fixture branch remains dedicated to workflow releases. Reset its disposable
database from the safe source whenever state may have leaked between runs.

## Each fork/workflow release

From a clean workflow checkout and a clean fork checkout at the annotated
`itl-*` tag, run:

```powershell
.\scripts\check.ps1 -Mode Release `
  -AiRulesSource D:\Git\itl_ai_rules_1c `
  -E2EProjectRoot D:\Git\itl-workflow-e2e
```

The command runs the complete static gate, fork gate and compatibility check,
then executes the E2E branch check and export. Success requires a verification
timestamp from the current run, `Verification fresh passed: True`, a CF/CFE
manifest without override, matching artifact SHA256, and successful Vanessa UI
MCP/ROCTUP MCP cleanup.

Keep `build/test-results/local/check-summary.json` and the nested E2E summary as
release evidence. A failed cleanup, stale Vanessa result, unverified override,
missing manifest, hash mismatch, dirty worktree, dynamic fork branch or
unpinned template is a release failure.

## Reset and rollback

- A failed E2E run does not qualify a release tag or workflow baseline.
- Stop remaining branch-local processes, discard the disposable database and
  recreate it before retrying when the cause is uncertain.
- Never repair an already published fork tag. Publish the next `rN` revision.
- Roll back a workflow baseline by restoring the previous fork tag and exact
  commit in both templates, then rerun the entire Release gate.

