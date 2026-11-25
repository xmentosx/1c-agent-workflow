# Direct quick-fix in a development branch

Use this reference after upstream `AGENTS.md` and `verification-policy.md` have independently set `executionPath=quick-fix` and `planningMode=direct`. When eligibility limits are exceeded or a promotion trigger appears, switch only the execution path to `full-cycle`; the planning mode stays `direct` until the user's request or the value of formal agreement separately selects OpenSpec.

This leaf covers a direct quick-fix without OpenSpec.

## Readiness rule

Here `itldev/*` means the current Git branch name (`git branch --show-current`), not a directory or a file glob. In such a branch a change under `exportPath`/`extensionsPath` passes the assessment of applicable obligations and a fresh passed `/itl-check`; `testsPath` stores retained tests, and sufficient one-off proof needs no placeholder test file. A started runner with zero tests, invalid JUnit or a failure remains an error. On `master` a source edit remains a branch-safety blocker.

Before tests of a local algorithm read `references/yaxunit-tests.md`; before Vanessa tests read `references/vanessa-tests.md`. Mode `off` forbids the automatic run, not authoring a test or reusing already fresh sufficient proof. Without such proof the skip stays partial: `verificationPolicy=block` blocks result/close, `warn` permits a warned export; closing the branch needs a separate confirmation.

## Steps

1. Find the fault and make the minimal fix. Do not change the architecture or add metadata; when the task outgrows quick-fix, switch the execution path as described above.
2. Use targeted/static checks while implementing (at least the syntax check of every touched module).
3. Choose proof under `verification-change.md`. For a quick-fix reuse sufficient existing proof; on a gap obtain a targeted current result. Choose the layer by the change: YAxUnit for local logic and its boundaries, Vanessa integration for interaction of objects, registers, documents or exchanges, Vanessa UI for forms, commands and visible behavior; overlapping risks need both layers. Retaining a regression test is a separate risk-based decision under `verification-suite-selection.md`: add a retained regression test only when future changes need it, and limit each extra scenario to a distinct material risk.
4. After the last relevant edit run one fresh unfiltered `/itl-check` (skill-based clients such as Codex use `$itl-check`; `/itl` shows the exact command name of the current client). It loads the changed files into the branch infobase and runs the selected checks; do not update the base separately beforehand.
5. If the check fails, analyze the runner report, the 1C log and the changed code, fix the cause and repeat the needed check within one persisted repair session. The helper owns its limit and recovery; an exhausted budget yields honest diagnostics, not another hidden loop.
6. Report the changed files and how the fix was verified.

Before `CF` export and branch close the helper assesses current evidence: `block` requires a sufficient fresh pass, `warn` keeps an explicitly warned export when verification is incomplete. Review does not replace runtime proof.
