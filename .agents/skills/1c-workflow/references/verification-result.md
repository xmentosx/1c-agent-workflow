# Verification And Result Reference

Use this reference for `/itl-check`, `verify-dev-branch`, Vanessa Automation, event-log checks, CF/CFE export, and verification policy.

## Normal Gate

Use targeted/static checks while implementing. Use `/itl-check` or helper action `check-dev-branch` as the only executable gate: before completion after the last verification-relevant edit, and earlier only at a milestone whose runtime result decides whether implementation can continue. The final run must be unfiltered. It ensures the copied branch infobase matches current configuration/extension sources, skips Designer/Enterprise when the fingerprint is already current, evaluates `ITL_VANESSA_TESTING` and `ITL_CHECK_EVENT_LOG`, and runs permitted components. Vanessa uses packet `StartFeaturePlayer` in a real `TESTMANAGER -> TESTCLIENT` topology.

Invoke `check-dev-branch` through `.agents/skills/1c-workflow/scripts/run-itl-command.ps1`, as the generated `/itl-check` command does. That parent runner owns abrupt helper-exit detection, exact Vanessa-run cleanup, and terminal lifecycle/status recovery. Direct `agent-1c.ps1` invocation is an internal debugging path and cannot recover from termination of its own PowerShell process.

`/itl-check` remains a single mechanical helper run: it does not author tests or start an agent repair loop. Its cheap preflight checks the suite and reports bounded source-only feature warnings without executing a second authoring run. Missing suites and failed unfiltered verification route to `/itl-verify-fix`. A filtered diagnostic failure instead routes to fixing the cause and repeating the same filtered check; it never starts a repair session. Recovery reuses sufficient coverage, otherwise creates the smallest focused scenario and uses one helper-owned repair session bounded by `ITL_VERIFICATION_REPAIR_MAX_ATTEMPTS` (default `5`).

The compact result exposes `errorCategory` and `requiredAction`. Categories are `missing-suite`, `test-fixture`, `unsupported-step`, `scenario-context`, `product-assertion`, `runner`, and `event-log`. They are routing hints, not automatic proof that the test or product is wrong. Follow the structured action; read the last 80 log lines only for an unclassified runner failure.

Long Designer work publishes a 30-second stderr heartbeat plus structured status evidence: current stage, elapsed time, liveness, seconds without CPU/log/process progress, timeout remaining, exact owned PIDs, CPU/log deltas, and working set. `stalled-suspected` begins after `DESIGNER_STALL_WARNING_SECONDS` (default 300). At `DESIGNER_STALL_TIMEOUT_SECONDS` (default 600) the helper fails and stops only exact owned Designer PIDs. The independent memory guard and overall hard operation timeout remain fail-closed. Never kill 1C manually from a stale-looking heartbeat.

Do not run a separate base update first. `/deploy-and-test` and `verify-dev-branch` are compatibility aliases to the same canonical `check-dev-branch` path, not independent loaders. `Run-DevBranchTests` is its private Vanessa phase. A canonical check may select one feature or tag filter for repeated performance profiling, but any `VanessaFeaturePath` or `VanessaFilterTags` keeps that run diagnostic-only. The helper rejects those filters with `VerificationTrigger=repair` before launching 1C. Only an unfiltered full canonical check after its owned update-base may authorize export or complete a repair session. A passed repair id means resume the original task; an exhausted id means report the blocker. Neither state starts another repair. Do not replace executable evidence with MCP or a headless EPF.

## ITL Modes

Both ITL keys accept `auto|manual|off`; missing/invalid uses safe effective `auto`. `auto` runs for implicit completion, command, repair, and direct requests. `manual` runs for command, repair, and direct requests. `off` runs only for an explicit request naming that component; generic `/itl-check` and `/itl-verify-fix` do not override it. `/itl-litemode` maps `lite/on` to `off/off`, `standard` to `auto/manual`, and `full/off` to `auto/auto`. Upstream `/litemode`, `VERIFICATION_DEPTH`, and `UI_TESTING` remain independent.

When Vanessa is off, do not automatically author tests or add them to a new plan. A skipped component sets `lastVerificationStatus=partial`, clears fresh evidence, and records skipped components. `verificationPolicy=block` still requires full evidence. For result export, `warn` proceeds after a visible warning; advanced close still requires its separate explicit confirmation.

`VANESSA_TEST_FOREIGN_WAIT_MODE=warn` is the default: foreign branch 1C test processes are diagnostic warnings, not a reason to wait, unless there is a real TestClient port/infobase conflict or the mode is set to `wait`.

## Vanessa Automation

Use scenarios from `tests/features` for quick-fix, direct full-cycle, and OpenSpec verification. Before creating or editing feature files, read `references/vanessa-tests.md`; do not load it for routine lifecycle commands.

Named or multi-client suites declare a project-owned TestClient manifest through `vanessaAutomation.testClientManifestPath` or ignored `VANESSA_TESTCLIENT_MANIFEST`. Schema 1 contains `maxConcurrency` and `profiles`; the legacy field name `maxConcurrency` is the maximum TestClient concurrency permitted by the manifest, not a license limit or the number reserved for every run. The runner statically derives the actual requirement from the selected feature scenarios and atomically reserves `1 x TESTMANAGER` in its empty service infobase plus the required TestClients in the development infobase against each exact infobase's `ONEC_MAX_CONCURRENT_SESSIONS` ceiling. Each profile has a literal unique `name`, optional `user` or `userEnv`, optional `passwordEnv`, `synonym`, and `clientType=Thin|Thick`. Never put a password, secret, or raw `/P` argument in the manifest. `passwordEnv` is resolved only from ignored `.dev.env` or the process environment. A project without a manifest keeps the one-profile legacy behavior for unnamed serial suites.

Before TestManager starts, the helper expands profile placeholders from scenario-outline `Examples`, treats any selected `(Расширение)` arbitrary-code step as requiring the current TestClient, reports a genuinely unresolved `<Профиль>` as `test-fixture`, reports the complete set of concrete missing profile names as `runner`, checks that the selected scenarios' static per-scenario TestClient requirement does not exceed the manifest ceiling, and allocates one bounded unique port per profile. The multi-infobase admission is atomic, so ROCTUP, Vanessa UI, Designer, and project-owned guarded launches cannot consume a promised target TestClient slot during manager startup. Static analysis resets client state between scenarios. Because VA `1.2.043.28` only distinguishes one client from multiple clients, that one-versus-many mode follows the selected scenarios' actual requirement; a configured non-zero topology stops on the first scenario error and asks VA to close configured TestClients after the run. `-VanessaFilterTags` is normalized from feature syntax such as `@V28` to VA values such as `V28`; VA receives only the official `filtertags` array. A filtered run is accepted only when JUnit `tests` equals the selected scenario count calculated from the feature set. The final completion run remains unfiltered.

For a quick-fix, reuse sufficient existing coverage; otherwise create or update one focused regression scenario and add a second only for a separate meaningful boundary or negative case. For direct full-cycle, choose coverage from the actual behavior and risk rather than OpenSpec artifact count. For OpenSpec, plan 2-3 scenarios by default and require an explicit short justification for a fourth. Choose the cheapest reliable check type:

- `unit-like`: local calculation, condition, filling, or applied logic.
- `integration`: object/register/document/exchange interaction.
- `UI`: forms, commands, or visible user behavior.

If Vanessa fails, analyze JUnit/report/status/log/event-log paths and active 1C process diagnostics before editing. Syntax/undefined-step failures normally point to the test; a new event-log error in changed BSL or failure of unchanged coverage strongly points to the product; UI-element and assertion mismatches remain ambiguous until checked against the requirement and actual runtime state. Fix the cause and rerun `/itl-check`. Never delete, skip, filter, or weaken a core assertion merely to make verification green. On timeout, stop only current-branch `TESTMANAGER`/`TESTCLIENT` processes; never kill another worktree's test manager/client.

## Event Log Baseline

The verification gate checks the branch-local file infobase event log against `.agent-1c/event-log-baselines/<branch>.json`. Fresh non-baseline `Error` signatures fail verification; known historical signatures remain diagnostics. Schema 1 baselines stay readable.

The preferred 8.3.22 sequential `.lgp` reader decodes severity and identifiers from their fixed fields and resolves event and metadata names through `1Cv8.lgf`. `SOURCE_EVENT_LOG_BASELINE_ENABLED` enables this auxiliary baseline for both source kinds and defaults to `true`. A file-source seed baseline inspects only the latest `.lgp`: an unchanged segment parses no event range after small identity probes, append-only growth parses only the byte delta, and cold start, rotation, truncation, replacement, or damaged cache parses at most `SOURCE_EVENT_LOG_BOOTSTRAP_TAIL_BYTES` (default `1048576`; `0` starts at EOF). It never falls back to a full large segment or opens an older segment. `SOURCE_SERVER_EVENT_LOG_LOOKBACK_DAYS` is the positive server-provider lookback and defaults to `7`. The old `SOURCE_EVENT_LOG_LOOKBACK_DAYS` is only a deprecated compatibility fallback. The latest-segment cursor and signatures live under `.agent-1c/event-log-signature-cache/<source-key>.json`; degraded tail coverage is recorded rather than presented as complete history. Canonical `check-dev-branch` preserves the oldest branch-persistent cursor before its owned base update, reuses a cursor left by a separate `update-dev-branch-base`, and copies that boundary into the Vanessa run evidence. The gate therefore covers config load/Enterprise normalization, delayed errors before the next check, and the current TestManager/TestClient cycle. Direct Vanessa-only runs keep a local cursor immediately before TestManager and do not consume the lifecycle cursor.

After a completed scan the persistent cursor advances even when new errors fail the gate, so fixed errors are not replayed forever. The failed fingerprint remains an event-log debt: an unchanged command retry cannot turn green; a changed verification fingerprint or a clean `/itl-verify-fix` repair run clears it. Existing branches without a persistent cursor perform one bounded migration scan from their baseline boundary. Cursor-mode uses byte position plus clock-skew tolerance, while rotation, truncation, source change, damaged cursor, or migration falls back to boundary-period segments. Evidence records cursor source key, capture time, scope, scan mode, scanned bytes, and the actual checked window; a clean message is limited to that stated scope. No fixed post-test sleep is allowed; managed process completion and the 10-second completion grace remain authoritative. `.lgd` stays unsupported.

## EXPORT_DEV_BRANCH_RESULT

Goal: export a CF or CFE artifact from the current development branch.

1. Require the current `itldev/*` worktree. Do not require or create a Git commit.
2. Check that the canonical effective-tree fingerprint still matches the successful verification before loading, before export, and after export.
3. Apply `verificationPolicy`: default `warn` prints a prominent warning and continues without confirmation or `-AllowUnverifiedResult` when verification is not fresh passed; `block` stops without an override path.
4. Export CF for configuration branches and CFE for extension branches.
5. Create `<artifact>.manifest.json` next to the exported artifact.
6. Normalize the artifact and manifest to absolute paths, publish them as `resultPath` and `resultManifestPath` in run status/compact JSON, include both in `artifacts`, and return a short Russian `userReport` with the full paths.
7. In the same report, list configuration-repository transfer objects from `merge-base(master, HEAD)` through the effective working tree. Include committed, staged, unstaged, and untracked files under the active CF/CFE export path. A changed metadata descriptor is reported as a full object; external-only changes are reported as partial with their affected parts. Exclude `ConfigDumpInfo.xml` and the membership-only root `Configuration.xml`; surface every unmapped source path for manual review instead of dropping it.

The manifest also retains SHA256, verification status, latest 1C log path, and the manual import note.

Result manifest schema 3 records artifact SHA256, operation, branch metadata, master/development base commits, working-tree provenance, configuration and verification fingerprints, verification status/report/log, `verification.policy`, `verification.decision` (`fresh-passed` or `warn-unverified`), latest 1C log path, publication URL, and manual import note. The legacy `unverifiedOverride` key remains false unless the legacy flag was actually passed. A development commit in a dirty-tree manifest is the base commit, not a claim that the exported content was committed.

Verification freshness uses a versioned canonical Git tree fingerprint of configured configuration, extension, and feature paths. A temporary index materializes the effective scoped working tree without changing the user's index. Committing exactly that checked content preserves the fingerprint; staging, unstaging, or committing files outside the scope also preserves it. Any effective scoped content change makes previous evidence stale.

Configuration and extension loads use a separate versioned Git-tree source fingerprint. It hashes canonical Git tree records instead of reopening every source file, includes effective staged, unstaged, untracked, and ignored source files, and excludes `ConfigDumpInfo.xml`. An existing legacy SHA256 source fingerprint is recalculated once and migrates without Designer only on an exact match; a mismatch still follows the normal partial/full load safety path.
The `v3` rollout intentionally treats stored legacy `v2` evidence as stale once; run one fresh `/itl-check` after updating the workflow.

## Verification Policy

`verificationPolicy=warn` is the default: result export warns and continues, while advanced close retains its explicit unverified confirmation. `verificationPolicy=block` forbids both until `/itl-check` or `verify-dev-branch` is fresh passed. Fingerprint changes during export always stop the operation.

Parallel independent development lines should use separate `itldev/*` worktrees. One development branch may remain long-lived and contain several sequential tasks, but verification freshness is still evaluated before result export.

## Troubleshooting

- If verification is missing, failed, stale, or unknown, run `/itl-check`.
- If 1C Designer reports an infobase configuration lock, close the manual Configurator or wait for the helper's previous Designer process to exit.
- If `1cv8.exe` exits with code 1 or hangs behind `-WindowStyle Hidden`, check native quoting. `Start-Process -ArgumentList` must receive one joined and correctly quoted command-line string; otherwise paths with spaces are split incorrectly.
