# Verification And Result Reference

Use this reference for `/itl-check`, `verify-dev-branch`, Vanessa Automation, event-log checks, CF/CFE export, and verification policy.

## Normal Gate

Use `/itl-check` or helper action `check-dev-branch` for the post-change executable gate. It updates the copied branch infobase, evaluates `ITL_VANESSA_TESTING` and `ITL_CHECK_EVENT_LOG`, and runs permitted components. Vanessa uses packet `StartFeaturePlayer` in a real `TESTMANAGER -> TESTCLIENT` topology.

`/itl-check` remains a single mechanical helper run: it does not author tests or start an agent repair loop. Use `/itl-verify-fix` explicitly when a previous implementation may have omitted relevant coverage or when the agent must diagnose, fix, and rerun a failing verification cycle. That recovery command first reuses an existing scenario when it already covers the changed behavior and creates a scenario only when coverage is missing.

Do not run a separate base update first. `/deploy-and-test` is a published compatibility bridge to `check-dev-branch`, not an independent loader. Do not replace executable evidence with MCP or a headless EPF. `verify-dev-branch` is the repair-trigger compatibility alias.

## ITL Modes

Both ITL keys accept `auto|manual|off`; missing/invalid uses safe effective `auto`. `auto` runs for implicit completion, command, repair, and direct requests. `manual` runs for command, repair, and direct requests. `off` runs only for an explicit request naming that component; generic `/itl-check` and `/itl-verify-fix` do not override it. `/itl-litemode` maps `lite/on` to `off/off`, `standard` to `auto/manual`, and `full/off` to `auto/auto`. Upstream `/litemode`, `VERIFICATION_DEPTH`, and `UI_TESTING` remain independent.

When Vanessa is off, do not automatically author tests or add them to a new plan. A skipped component sets `lastVerificationStatus=partial`, clears fresh evidence, and records skipped components. `verificationPolicy=block` still requires full evidence. `warn` accepts partial result/close only with explicit confirmation and wording `implemented; executable verification skipped`.

`VANESSA_TEST_FOREIGN_WAIT_MODE=warn` is the default: foreign branch 1C test processes are diagnostic warnings, not a reason to wait, unless there is a real TestClient port/infobase conflict or the mode is set to `wait`.

## Vanessa Automation

Use scenarios from `tests/features` for OpenSpec and quick-fix verification. Before creating or editing feature files, read `references/vanessa-tests.md`; do not load it for routine lifecycle commands.

For a quick-fix, create or update at least one focused regression scenario; add a second only for a separate meaningful boundary or negative case. For OpenSpec, plan 2-3 scenarios by default and require an explicit short justification for a fourth. Choose the cheapest reliable check type:

- `unit-like`: local calculation, condition, filling, or applied logic.
- `integration`: object/register/document/exchange interaction.
- `UI`: forms, commands, or visible user behavior.

If Vanessa fails, analyze JUnit/report/status/log/event-log paths and active 1C process diagnostics, fix the cause, and rerun `/itl-check`. On timeout, stop only current-branch `TESTMANAGER`/`TESTCLIENT` processes; never kill another worktree's test manager/client.

## Event Log Baseline

The verification gate checks the branch-local file infobase event log against `.agent-1c/event-log-baselines/<branch>.json`. Fresh non-baseline `Error` signatures fail verification; known historical signatures remain diagnostics. Schema 1 baselines stay readable.

The preferred 8.3.22 sequential `.lgp` reader streams records and rejects non-`Error`/out-of-window events before full event/signature construction. Baselines cache segments under `.agent-1c/event-log-signature-cache/<source-key>.json`. Each Vanessa run captures `event-log-cursor.json` before TestManager, then reads only the active tail and new/changed segments; rotation, truncation, source change, or damaged cursor falls back to run-period segments. State records runner, cleanup, event-log, post-process duration, scanned bytes, and scan mode. No fixed post-test sleep is allowed; the 10-second completion grace remains. `.lgd` stays unsupported.

## EXPORT_DEV_BRANCH_RESULT

Goal: export a CF or CFE artifact from the current development branch.

1. Require the current `itldev/*` worktree and clean tracked Git state.
2. Check verification freshness before export.
3. Apply `verificationPolicy`: default `warn` requires explicit unverified confirmation or `-AllowUnverifiedResult` when verification is missing, failed, stale, or unknown; `block` stops without an override path.
4. Export CF for configuration branches and CFE for extension branches.
5. Create `<artifact>.manifest.json` next to the exported artifact.
6. Report artifact path, manifest path, SHA256, verification status, latest 1C log path, and manual import note.

The result manifest records artifact SHA256, operation, branch metadata, master/development commits, verification status/report/log, latest 1C log path, publication URL, manual import note, and whether an unverified override was used.

Verification freshness uses a content-aware fingerprint of configured configuration, extension, and feature paths. A second edit of an already dirty file makes a previous passed verification stale even when its porcelain Git status remains `M`.

## Verification Policy

`verificationPolicy=warn` is the default and requires explicit unverified confirmation before result export or advanced close when verification is not fresh passed. `verificationPolicy=block` forbids result export and advanced close until `/itl-check` or `verify-dev-branch` is fresh passed.

Parallel independent development lines should use separate `itldev/*` worktrees. One development branch may remain long-lived and contain several sequential tasks, but verification freshness is still evaluated before result export.

## Troubleshooting

- If verification is missing, failed, stale, or unknown, run `/itl-check`.
- If 1C Designer reports an infobase configuration lock, close the manual Configurator or wait for the helper's previous Designer process to exit.
- If `1cv8.exe` exits with code 1 or hangs behind `-WindowStyle Hidden`, check native quoting. `Start-Process -ArgumentList` must receive one joined and correctly quoted command-line string; otherwise paths with spaces are split incorrectly.
