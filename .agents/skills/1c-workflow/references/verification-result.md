# Verification And Result Reference

Use this reference for `/itl-check`, `verify-dev-branch`, Vanessa Automation, event-log checks, CF/CFE export, and verification policy.

## Normal Gate

Use `/itl-check` or helper action `check-dev-branch` for the normal post-change executable gate. It updates the copied branch infobase and then runs Vanessa Automation through packet `StartFeaturePlayer` in a real `TESTMANAGER -> TESTCLIENT` topology with a branch-local `VANESSA_TEST_PORT` used as the TestClient launch/connect port in VAParams.

Do not run a separate base update first for normal verification. Do not use `/deploy-and-test` as the normal gate because it reloads all files. Do not replace the final gate with MCP or a headless EPF. `verify-dev-branch` remains a compatibility alias.

`VANESSA_TEST_FOREIGN_WAIT_MODE=warn` is the default: foreign branch 1C test processes are diagnostic warnings, not a reason to wait, unless there is a real TestClient port/infobase conflict or the mode is set to `wait`.

## Vanessa Automation

Use scenarios from `tests/features` for OpenSpec and quick-fix verification. Before creating or editing feature files, read `VANESSA-TESTS-GUIDE.md`; do not load it for routine lifecycle commands.

For behavior changes, create or update a small check set: at least 2 checks, usually 2-3, and no more than 4 unless explicitly justified. Include the main successful scenario and one meaningful boundary or negative case. Choose the cheapest reliable check type:

- `unit-like`: local calculation, condition, filling, or applied logic.
- `integration`: object/register/document/exchange interaction.
- `UI`: forms, commands, or visible user behavior.

If Vanessa fails, analyze JUnit/report/status/log/event-log paths and active 1C process diagnostics, fix the cause, and rerun `/itl-check`. On timeout, stop only current-branch `TESTMANAGER`/`TESTCLIENT` processes; never kill another worktree's test manager/client.

## Event Log Baseline

The verification gate checks the branch-local file infobase event log against `.agent-1c/event-log-baselines/<branch>.json`. Fresh non-baseline `Error` signatures fail verification. Legacy baseline errors remain diagnostics. The direct 8.3.22 sequential event-log reader is preferred when available; fallback exporter sources are bundled in the workflow package.

## EXPORT_DEV_BRANCH_RESULT

Goal: export a CF or CFE artifact from the current development branch.

1. Require the current `itldev/*` worktree and clean tracked Git state.
2. Check verification freshness before export.
3. Apply `verificationPolicy`: default `warn` requires explicit unverified confirmation or `-AllowUnverifiedResult` when verification is missing, failed, stale, or unknown; `block` stops without an override path.
4. Export CF for configuration branches and CFE for extension branches.
5. Create `<artifact>.manifest.json` next to the exported artifact.
6. Report artifact path, manifest path, SHA256, verification status, latest 1C log path, and manual import note.

The result manifest records artifact SHA256, operation, branch metadata, master/development commits, verification status/report/log, latest 1C log path, publication URL, manual import note, and whether an unverified override was used.

## Verification Policy

`verificationPolicy=warn` is the default and requires explicit unverified confirmation before result export or advanced close when verification is not fresh passed. `verificationPolicy=block` forbids result export and advanced close until `/itl-check` or `verify-dev-branch` is fresh passed.

Parallel independent development lines should use separate `itldev/*` worktrees. One development branch may remain long-lived and contain several sequential tasks, but verification freshness is still evaluated before result export.

## Troubleshooting

- If verification is missing, failed, stale, or unknown, run `/itl-check`.
- If 1C Designer reports an infobase configuration lock, close the manual Configurator or wait for the helper's previous Designer process to exit.
- If `1cv8.exe` exits with code 1 or hangs behind `-WindowStyle Hidden`, check native quoting. `Start-Process -ArgumentList` must receive one joined and correctly quoted command-line string; otherwise paths with spaces are split incorrectly.
