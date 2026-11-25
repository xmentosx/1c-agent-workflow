# Direct full-cycle in a development branch

Use this reference after upstream `AGENTS.md` and `verification-policy.md` have set `executionPath=full-cycle` and the boundaries, solution and acceptance criteria are clear enough for `planningMode=direct`. A promotion trigger or a high verification risk strengthens the checks, but by itself it does not require OpenSpec.

## Readiness rule

Here `itldev/*` means the current Git branch name (`git branch --show-current`), not a directory or a file glob. In such a branch a change under `exportPath`/`extensionsPath` passes the assessment of applicable obligations and a fresh passed `/itl-check`; `testsPath` stores retained tests, and sufficient one-off proof needs no placeholder test file. A started runner with zero tests, invalid JUnit or a failure remains an error. On `master` a source edit remains a branch-safety blocker.

Before algorithm tests read `references/yaxunit-tests.md`; before Vanessa tests read `references/vanessa-tests.md`. Mode `off` forbids the automatic run, not authoring a test or reusing already fresh sufficient proof. Without such proof the skip stays partial: `verificationPolicy=block` blocks result/close, `warn` permits a warned export; closing the branch needs a separate confirmation.

## Process

Direct full-cycle uses the full upstream process of analysis, targeted change and applicable checks, but creates no OpenSpec artifacts.

Before the change record:

```text
executionPath=full-cycle
planningMode=direct
Reason: <promotion trigger or why quick-fix was exceeded>; scope and solution are clear.
```

After implementation obtain sufficient proof under `verification-change.md`: applicable existing or new checks, including an admissible one-off observation. The final fresh passed `/itl-check` assesses overall readiness. A high verification risk strengthens the necessary checks; it does not create a proposal or a duplicate suite automatically.

The final `/itl-check` runs after the last relevant edit and belongs to the helper: it decides the needed branch infobase update, runs the selected YAxUnit and Vanessa Automation through `TESTMANAGER -> TESTCLIENT`, checks JUnit and the event-log baseline, and accounts for applicable retained proof. An interactive MCP confirmation needs no duplicate test file but does not replace the final helper assessment. Do not replace it with a headless EPF or `/deploy-and-test`.

If the check fails, analyze the selected runner report, the 1C log, event-log evidence and the changed code; fix the cause and repeat the full helper-owned cycle. The helper decides repeated runs and proof applicability; do not manually repeat unaffected observations. After three failed repairs without progress on the same obstacle perform systemic diagnosis before another full run (`verification-result.md`); a blocked repair returns blocker diagnostics and never claims completion.

Claim verified readiness only after a fresh passed `/itl-check`. For `/itl-result` with partial/skipped evidence apply `verificationPolicy`; such a result never becomes a normal fresh pass.
