# Workflow incidents and task continuation

Use this reference for a suspected ITL defect, contradictory instructions, or a
loaded-skill/installed-file mismatch. Keep the original project task active.
Classify runner, environment, fixture and product evidence before editing. An
error category or failed validator alone does not prove defective product data.
For a loaded/installed mismatch, pause dependent lifecycle commands, resolve the
reported version/cache mismatch or reload, then resume; independent work can
continue. Use the existing operation's recovery first. Do not repeat an unchanged
failed run without new evidence. Repair exhaustion remains recorded; never reset
counters, locks, lifecycle state or verification evidence by hand.

For Kilo behavior that disagrees with the Intent Map, run `status`, compare the
reported expected skill contract/SHA, and ask for `/reload` before treating it as
a source defect. ITL cannot inspect or clear Kilo's internal cache/worktrees.

## Choose a concrete continuation

Diagnose enough to propose a bounded repair; do not turn the project task into an
open-ended workflow redesign. Prepare the exact change, affected runtime, expected
effect, validation and rollback before requesting any missing authorization.
Reuse an existing authorization within its stated project, operation and scope.
If authoritative evidence leaves a business choice or missing external input,
ask for that specific decision while preserving work and continuing independent
steps. A new workflow barrier is incomplete until its owner supplies an
agent-usable route back to the original task.

- An erroneous ITL instruction can be set aside for the user-authorized case
  without editing rule files. Record the instruction and permission in the report.
- For a code check, use the owner's existing supported option or propose a local
  ITL patch. Permission in prose does not disable executable code. There is no
  universal ignore-checks option or permission registry.
- Do not fabricate a pass. Preserve failed, partial or skipped evidence. A local
  workaround does not qualify a release. With `verificationPolicy=warn`, ordinary
  result export warns and proceeds; advanced close retains its separate explicit
  confirmation. `block` requires fresh passed evidence in the normal route.
- Continue to use the normal wrappers and operation owners. Do not substitute
  direct 1C launches, modify valid product files to appease a broken validator,
  erase recovery state, or edit the controlled ai_rules_1c installation.

## Temporary ITL file patch

Determine the executing copy first. Refresh starts with the clean tracked runtime
in the main worktree, then hands the same operation to the branch runtime. A
branch-only patch cannot fix an earlier main-runtime failure. A main-runtime
repair requires explicit scope covering other branches that use it; commit its
sealed patch before refresh so the existing clean-runtime guard remains intact.
Do not introduce a different launcher or arbitrary runtime-source override.

Write a report outside managed workflow files, for example in `handoffs/`.
Finish or cancel the owned operation before editing files it may still load.
After authorization, capture the original files **before editing**:

```powershell
& .\.agents\skills\1c-workflow\scripts\workflow-local-patch.ps1 `
  -Action Capture -ProjectRoot (Get-Location).Path `
  -Paths @('.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1') `
  -ReportPath .\handoffs\workflow-incident.md
```

This file-only helper saves one batch of existing, clean tracked ITL text files,
their byte snapshots and a copy of the report under the already ignored
`.agent-1c/snapshots/workflow-incidents/`. It never launches 1C or changes product
files. Keep the report updated at the returned path. The receipt is data, not
authorization. For an already edited file, preserve its diff and establish the
original baseline before capture; never overwrite an unknown edit to satisfy it.

Apply the agreed patch, then seal it before staging/committing:

```powershell
& .\.agents\skills\1c-workflow\scripts\workflow-local-patch.ps1 -Action Seal
```

Repeat the original operation, record the result, and resume the project task.
Keep the saved before/after bytes available for an exact reverse edit if needed.
Further edits to a sealed file require reconciliation with that recorded patch;
they are not automatically disposable. Before another authorized edit, repeat
Capture with the additional paths and updated report, then Seal again. The same
batch retains each file's original baseline, including already committed patch
files. If edits were made before Capture, preserve their diff, restore only the
recorded patch bytes, Capture, and reapply the reviewed diff before Seal.

## Replacement and recovery

Update/refresh retire the recorded patch before their normal clean check or
checkpoint. A previously committed patch is removed by a corrective commit;
history and unrelated staging remain intact. Extra edits, another branch,
unmerged state or changed snapshots are preserved with a specific diagnostic:
inspect the recorded before/after and actual diff, preserve the extra change,
and reconcile only the incident's files. Never discard unrelated work to unblock
an update. Ordinary commands do not consult patch history.

Before package copying succeeds, a caught failure restores the working patch.
Before refresh starts its merge, a caught preparation failure also restores it.
An interrupted retirement resumes from the recorded before/after bytes. Once
package copying succeeds or refresh starts its owned merge, the existing owner
controls recovery; an old patch is not reapplied over incoming code or a pending
merge. Reports and snapshots survive in the incident directory.

Retired means replaced, **not fixed**. Reproduce the original scenario with the
new workflow. If it still fails, update the report and propose a fresh scoped
workaround; never silently reapply the old patch. Send no external messages merely
because a report exists.

## Report template

The agent writes one Markdown report; no generator is required. Include:

1. Original project task, project/branch, workflow revision and executing runtime.
2. Reproduction command and prerequisites; expected and actual result.
3. Exact error and selected log/artifact paths; omit secrets and irrelevant logs.
4. Proven cause separately from hypotheses; runner/environment/fixture/product.
5. Proposed/applied workaround, affected files/rule, exact authorization scope.
6. Patch or saved before/after location, rollback, original-scenario result and
   remaining verification gaps; whether the project task resumed.
7. Replacement version and original-scenario result after update, when available.

Keep the original report and append outcomes. A report-writing tool failure does
not block independent project work: write the available evidence directly and
identify missing artifacts. Refer the general fix to the workflow source owner.
