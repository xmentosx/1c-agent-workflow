# Verification And Result Reference

Use this reference for `/itl-check`, `verify-dev-branch`, Vanessa Automation, event-log checks, CF/CFE export, and verification policy.

## Normal Gate

Use `/itl-check` or helper action `check-dev-branch` for the only post-change executable gate. It ensures the copied branch infobase matches current configuration/extension sources, skips Designer/Enterprise when the fingerprint is already current, evaluates `ITL_VANESSA_TESTING` and `ITL_CHECK_EVENT_LOG`, and runs permitted components. Vanessa uses packet `StartFeaturePlayer` in a real `TESTMANAGER -> TESTCLIENT` topology.

`/itl-check` remains a single mechanical helper run: it does not author tests or start an agent repair loop. Its cheap preflight checks the suite and reports bounded source-only feature warnings without executing a second authoring run. Missing suites and failed verification route to `/itl-verify-fix`. Recovery reuses sufficient coverage, otherwise creates the smallest focused scenario and uses one helper-owned three-run repair session.

The compact result exposes `errorCategory` and `requiredAction`. Categories are `missing-suite`, `unsupported-step`, `scenario-context`, `product-assertion`, `runner`, and `event-log`. They are routing hints, not automatic proof that the test or product is wrong. Follow the structured action; read the last 80 log lines only for an unclassified runner failure.

Long Designer work publishes a 30-second stderr heartbeat plus structured status evidence: current stage, elapsed time, liveness, seconds without CPU/log/process progress, timeout remaining, exact owned PIDs, CPU/log deltas, and working set. `stalled-suspected` begins after `DESIGNER_STALL_WARNING_SECONDS` (default 300). At `DESIGNER_STALL_TIMEOUT_SECONDS` (default 600) the helper fails and stops only exact owned Designer PIDs. The independent memory guard and overall hard operation timeout remain fail-closed. Never kill 1C manually from a stale-looking heartbeat.

Do not run a separate base update first. `/deploy-and-test` is a published compatibility bridge to `check-dev-branch`, not an independent loader. Do not replace executable evidence with MCP or a headless EPF. `verify-dev-branch` is the repair-trigger compatibility alias.

## ITL Modes

Both ITL keys accept `auto|manual|off`; missing/invalid uses safe effective `auto`. `auto` runs for implicit completion, command, repair, and direct requests. `manual` runs for command, repair, and direct requests. `off` runs only for an explicit request naming that component; generic `/itl-check` and `/itl-verify-fix` do not override it. `/itl-litemode` maps `lite/on` to `off/off`, `standard` to `auto/manual`, and `full/off` to `auto/auto`. Upstream `/litemode`, `VERIFICATION_DEPTH`, and `UI_TESTING` remain independent.

When Vanessa is off, do not automatically author tests or add them to a new plan. A skipped component sets `lastVerificationStatus=partial`, clears fresh evidence, and records skipped components. `verificationPolicy=block` still requires full evidence. `warn` accepts partial result/close only with explicit confirmation and wording `implemented; executable verification skipped`.

`VANESSA_TEST_FOREIGN_WAIT_MODE=warn` is the default: foreign branch 1C test processes are diagnostic warnings, not a reason to wait, unless there is a real TestClient port/infobase conflict or the mode is set to `wait`.

## Vanessa Automation

Use scenarios from `tests/features` for quick-fix, direct full-cycle, and OpenSpec verification. Before creating or editing feature files, read `references/vanessa-tests.md`; do not load it for routine lifecycle commands.

For a quick-fix, reuse sufficient existing coverage; otherwise create or update one focused regression scenario and add a second only for a separate meaningful boundary or negative case. For direct full-cycle, choose coverage from the actual behavior and risk rather than OpenSpec artifact count. For OpenSpec, plan 2-3 scenarios by default and require an explicit short justification for a fourth. Choose the cheapest reliable check type:

- `unit-like`: local calculation, condition, filling, or applied logic.
- `integration`: object/register/document/exchange interaction.
- `UI`: forms, commands, or visible user behavior.

If Vanessa fails, analyze JUnit/report/status/log/event-log paths and active 1C process diagnostics before editing. Syntax/undefined-step failures normally point to the test; a new event-log error in changed BSL or failure of unchanged coverage strongly points to the product; UI-element and assertion mismatches remain ambiguous until checked against the requirement and actual runtime state. Fix the cause and rerun `/itl-check`. Never delete, skip, filter, or weaken a core assertion merely to make verification green. On timeout, stop only current-branch `TESTMANAGER`/`TESTCLIENT` processes; never kill another worktree's test manager/client.

## Event Log Baseline

The verification gate checks the branch-local file infobase event log against `.agent-1c/event-log-baselines/<branch>.json`. Fresh non-baseline `Error` signatures fail verification; known historical signatures remain diagnostics. Schema 1 baselines stay readable.

The preferred 8.3.22 sequential `.lgp` reader streams records and rejects non-`Error`/out-of-window events before full event/signature construction. Baselines cache segments under `.agent-1c/event-log-signature-cache/<source-key>.json`. Each Vanessa run captures `event-log-cursor.json` before TestManager, then reads only the active tail and new/changed segments; rotation, truncation, source change, or damaged cursor falls back to run-period segments. State records runner, cleanup, event-log, post-process duration, scanned bytes, and scan mode. No fixed post-test sleep is allowed; the 10-second completion grace remains. `.lgd` stays unsupported.

## EXPORT_DEV_BRANCH_RESULT

Goal: export a CF or CFE artifact from the current development branch.

1. Require the current `itldev/*` worktree. Do not require or create a Git commit.
2. Check that the canonical effective-tree fingerprint still matches the successful verification before loading, before export, and after export.
3. Apply `verificationPolicy`: default `warn` requires explicit unverified confirmation or `-AllowUnverifiedResult` when verification is missing, failed, stale, or unknown; `block` stops without an override path.
4. Export CF for configuration branches and CFE for extension branches.
5. Create `<artifact>.manifest.json` next to the exported artifact.
6. Report artifact path, manifest path, SHA256, verification status, latest 1C log path, and manual import note.

The result manifest records artifact SHA256, operation, branch metadata, master/development base commits, whether the source came from a clean commit or the effective working tree, configuration and verification fingerprints, verification status/report/log, latest 1C log path, publication URL, manual import note, and whether an unverified override was used. A development commit in a dirty-tree manifest is the base commit, not a claim that the exported content was committed.

Verification freshness uses a versioned canonical Git tree fingerprint of configured configuration, extension, and feature paths. A temporary index materializes the effective scoped working tree without changing the user's index. Committing exactly that checked content preserves the fingerprint; staging, unstaging, or committing files outside the scope also preserves it. Any effective scoped content change makes previous evidence stale.
The `v3` rollout intentionally treats stored legacy `v2` evidence as stale once; run one fresh `/itl-check` after updating the workflow.

## Verification Policy

`verificationPolicy=warn` is the default and requires explicit unverified confirmation before result export or advanced close when verification is not fresh passed. `verificationPolicy=block` forbids result export and advanced close until `/itl-check` or `verify-dev-branch` is fresh passed.

Parallel independent development lines should use separate `itldev/*` worktrees. One development branch may remain long-lived and contain several sequential tasks, but verification freshness is still evaluated before result export.

## Troubleshooting

- If verification is missing, failed, stale, or unknown, run `/itl-check`.
- If 1C Designer reports an infobase configuration lock, close the manual Configurator or wait for the helper's previous Designer process to exit.
- If `1cv8.exe` exits with code 1 or hangs behind `-WindowStyle Hidden`, check native quoting. `Start-Process -ArgumentList` must receive one joined and correctly quoted command-line string; otherwise paths with spaces are split incorrectly.
