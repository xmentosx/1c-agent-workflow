# Verification And Result Reference

For missing or stale tooling extensions, use [tooling recovery](tooling-recovery.md).

Use this reference for `/itl-check`, `verify-dev-branch`, Vanessa Automation, event-log checks, CF/CFE export, and verification policy.

## Normal Gate

Use targeted/static checks while implementing. Use `/itl-check` or helper action `check-dev-branch` as the only executable gate: before completion after the last verification-relevant edit, and earlier only at a milestone whose runtime result decides whether implementation can continue. The final run must be unfiltered. It ensures the copied branch infobase matches current configuration/extension sources, skips Designer/Enterprise when the fingerprint is already current, evaluates `ITL_YAXUNIT_TESTING`, `ITL_VANESSA_TESTING`, and `ITL_CHECK_EVENT_LOG`, and runs permitted components. YAxUnit runs the hierarchical test extension first; Vanessa then uses packet `StartFeaturePlayer` in a real `TESTMANAGER -> TESTCLIENT` topology.

Invoke `check-dev-branch` through `.agents/skills/1c-workflow/scripts/run-itl-command.ps1`, as the generated `/itl-check` command does. That parent runner owns the helper Job Object (`KILL_ON_JOB_CLOSE`), abrupt helper-exit detection, stale-status watchdog even when `liveness` is empty, and the `ITL_RUNNER_OPERATION_TIMEOUT_SECONDS` ceiling (default 3600). Long native waits publish a generic helper heartbeat; Designer and Vanessa add operation-specific progress/stall evidence, so the generic stale watchdog does not preempt a live operation that is still within its published stall budget. After an abrupt helper exit, the runner first uses the exact persisted database/native recovery ticket and retained `ownedProcessScopes`; legacy exact Vanessa evidence remains only a fallback. A verified recovery releases the database, reports stopped owned PIDs with `foreignProcessesStopped=[]`, and returns `retry-original-command` rather than asking for manual process cleanup. Direct `agent-1c.ps1` invocation is an internal debugging path and cannot recover from termination of its own PowerShell process.

`/itl-check` remains a single mechanical helper run: it does not author tests or start an agent repair loop. Its cheap preflight checks the suite and reports bounded source-only feature warnings without executing a second authoring run. Missing classification or failed unfiltered verification routes to `/itl-verify-fix`. An ordinary filtered diagnostic failure routes to fixing the cause and repeating that scope without a repair session. An explicitly requested `/test-fix-loop` instead starts one `scenario-loop` repair session pinned to the named Vanessa feature/tag scope. If no retained feature covers the requested behavior, the agent may author a minimal transient `.feature` under ignored `.agent-1c/verification/scenario-loop/`, with explicit expected outcomes and the normal Vanessa authoring checks, then pass that exact path to the same helper. Preserve the file through the session and any evidence/diagnosis that references it; do not count it as retained regression coverage or silently change an expectation to pass. If the requested behavior cannot be made into a reliable executable scenario, report the missing prerequisite before starting the loop. Its default limit is three rounds; `-VerificationRepairMaxAttempts N` sets the limit only when creating a new session, while repeat `begin-verification-repair` resumes the existing budget. Canonical repair keeps `ITL_VERIFICATION_REPAIR_MAX_ATTEMPTS` (default `5`). Recovery first separates runner, fixture, and product causes; a proven product defect then uses sufficient existing YAxUnit/Vanessa coverage or the smallest missing regression. The agent resolves classification and repair without asking the user to choose tests or catalogs.

The compact result exposes `errorCategory` and `requiredAction`. Categories are `missing-suite`, `test-fixture`, `unsupported-step`, `scenario-context`, `product-assertion`, `runner`, and `event-log`. They are routing hints, not automatic proof that the test or product is wrong. Follow the structured action; read the last 80 log lines only for an unclassified runner failure.

Long Designer work publishes structured liveness from its own bounded completion probe: current stage, elapsed time, seconds without CPU/log/process progress, timeout remaining, exact owned PIDs, CPU/log deltas, and working set. `stalled-suspected` begins after `DESIGNER_STALL_WARNING_SECONDS` (default 300); `DESIGNER_STALL_TIMEOUT_SECONDS` (default 600) fails the operation. Vanessa uses the same principle against the exact current run: `vanessa.log` growth, owned TestManager/TestClient process-set changes and CPU activity reset its no-progress budget; a normal 1800-second run gets a 300-second warning and 600-second stall bound while still emitting a helper heartbeat well inside the generic 120-second stale threshold. YAxUnit and other native waits also emit the generic heartbeat even when they have no richer progress probe. The independent hard operation/native timeout remains fail-closed. Never kill 1C manually from a stale-looking heartbeat.

Do not run a separate base update first. `/deploy-and-test` and `verify-dev-branch` are compatibility aliases to the same canonical `check-dev-branch` path, not independent loaders. `Run-DevBranchTests` is its private Vanessa phase. A canonical check may select one feature or tag filter for repeated performance profiling, but any `VanessaFeaturePath` or `VanessaFilterTags` keeps that run diagnostic-only. `canonical-repair` rejects filters. `scenario-loop` admits only the scope recorded when its session began; a changed feature/tag scope stops before 1C. A named component override may run Vanessa for that session even when its persistent execution switch is `off`, but does not change the switch or lift a broader user no-UI instruction. One `check-dev-branch` scenario-loop call consumes one outer attempt: it checks the filtered scenario, then checks due YAxUnit/Vanessa/event-log obligations unfiltered without a second base update or attempt. The filtered phase alone cannot produce full proof. Only the unfiltered phase supplies fresh passed evidence or completes either repair kind; unverified export follows the policy below. A passed repair id means resume the original task; an exhausted id preserves the blocker and routes suspected workflow defects to `workflow-incidents.md`. Neither state starts another repair. Do not replace executable evidence with MCP or a headless EPF.

## ITL Modes

Both ITL keys accept `auto|manual|off`; missing uses `auto`; invalid values skip execution with a correction diagnostic. `auto` runs for implicit completion, command, repair, and direct requests. `manual` runs for command, repair, and direct requests. `off` runs only for an explicit request naming that component; generic `/itl-check` and `/itl-verify-fix` do not override it. `/itl-litemode` maps `lite/on` to `off/off`, `standard` to `auto/manual`, and `full/off` to `auto/auto`. Upstream `/litemode`, `VERIFICATION_DEPTH`, and `UI_TESTING` remain independent.

Execution off does not prohibit authoring needed current evidence or retaining an independently justified regression; it does not itself require new tests. Preserve approved plans and decide current proof separately from future regression coverage. A skipped component records partial evidence only when no fresh complete proof already covers the current inputs; a later ordinary check reuses a fresh explicit result without resetting the persistent switch. One-off obligations need a matching passed receipt in the same readiness assessment as retained runners and event log. Classification may be ready while that receipt is pending, so retained tests can still run. `verificationPolicy=block` requires the complete result; `warn` proceeds after a visible warning, and advanced close still requires its separate explicit confirmation. The receipt format and compact helper actions are in [verification suite selection](verification-suite-selection.md).

Saved Vanessa also obeys `TOOL_BROWSER=auto|off|required`; empty means `auto`, invalid blocks that runner with a correction, and `off` cannot be bypassed through another launcher. A named Vanessa invocation may override its execution and provider off switches for that invocation only; it does not authorize unrelated UI or lift a current broader no-UI instruction. `UI_TESTING` selects the separate interactive UI workflow and does not disable saved Vanessa by itself. YAxUnit and event-log checks are independent of browser policy. A required runtime still needs the existing runner's actual capability and readiness checks; configuration alone is not proof.

`VANESSA_TEST_FOREIGN_WAIT_MODE=warn` is the default: foreign branch 1C test processes are diagnostic warnings, not a reason to wait, unless there is a real TestClient port/infobase conflict or the mode is set to `wait`.

## Vanessa Automation

Use scenarios from `tests/features` for quick-fix, direct full-cycle, and OpenSpec verification. Before creating or editing feature files, read `references/vanessa-tests.md`; do not load it for routine lifecycle commands.

Named or multi-client suites declare a project-owned TestClient manifest through `vanessaAutomation.testClientManifestPath` or ignored `VANESSA_TESTCLIENT_MANIFEST`. Schema 1 contains `maxConcurrency` and `profiles`; the legacy field name `maxConcurrency` is the maximum TestClient concurrency permitted by the manifest, not a license limit or the number reserved for every run. The runner statically derives the actual requirement from the selected feature scenarios and atomically reserves `1 x TESTMANAGER` in its empty service infobase plus the required TestClients in the development infobase against each exact infobase's `ONEC_MAX_CONCURRENT_SESSIONS` ceiling. Each profile has a literal unique `name`, optional `user` or `userEnv`, optional `passwordEnv`, `synonym`, and `clientType=Thin|Thick`. Never put a password, secret, or raw `/P` argument in the manifest. `passwordEnv` is resolved only from ignored `.dev.env` or the process environment. A project without a manifest keeps the one-profile legacy behavior for unnamed serial suites.

Before TestManager starts, the helper expands profile placeholders from scenario-outline `Examples`, treats any selected `(Расширение)` arbitrary-code step as requiring the current TestClient, reports a genuinely unresolved `<Профиль>` as `test-fixture`, reports the complete set of concrete missing profile names as `runner`, checks that the selected scenarios' static per-scenario TestClient requirement does not exceed the manifest ceiling, and allocates one bounded unique port per profile. The multi-infobase admission is atomic, so ROCTUP, Vanessa UI, Designer, and project-owned guarded launches cannot consume a promised target TestClient slot during manager startup. Static analysis resets client state between scenarios. Because VA `1.2.043.42` only distinguishes one client from multiple clients, that one-versus-many mode follows the selected scenarios' actual requirement; a configured non-zero topology stops on the first scenario error and asks VA to close configured TestClients after the run. `-VanessaFilterTags` is normalized from feature syntax such as `@V28` to VA values such as `V28`; VA receives only the official `filtertags` array. A filtered run is accepted only when JUnit `tests` equals the selected scenario count calculated from the feature set. The final completion run remains unfiltered.

For a quick-fix, reuse sufficient existing coverage or obtain a focused current result; retain a new regression when future reuse justifies it. For direct full-cycle and OpenSpec, choose current proof and retained coverage from the actual behavior and risk rather than artifact count. If creating retained OpenSpec tests, prefer representative integration/UI scenarios and put algorithmic boundaries in parameterized YAxUnit tests. A one-off result must be recorded against the exact obligation and checked inputs before it can establish readiness. Choose the cheapest reliable check type:

- local calculation, parsing, condition, filling, or applied logic belongs in YAxUnit; keep a Vanessa `unit-like` block only when the contract itself depends on TestClient/extension runtime context;
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
3. Apply `verificationPolicy`: default `warn` prints a prominent warning and continues without confirmation or `-AllowUnverifiedResult` when verification is not fresh passed; `block` stops in the normal route; a suspected workflow defect follows `workflow-incidents.md`.
4. Export CF for configuration branches and CFE for extension branches.
5. Create `<artifact>.manifest.json` next to the exported artifact.
6. Normalize the artifact and manifest to absolute paths, publish them as `resultPath` and `resultManifestPath` in run status/compact JSON, include both in `artifacts`, and return a short Russian `userReport` with the full paths.
7. In the same report, list configuration-repository transfer objects from `merge-base(master, HEAD)` through the effective working tree. Include committed, staged, unstaged, and untracked files under the active CF/CFE export path. A changed metadata descriptor is reported as a full object; external-only changes are reported as partial with their affected parts. Exclude `ConfigDumpInfo.xml` and the membership-only root `Configuration.xml`; surface every unmapped source path for manual review instead of dropping it.

The manifest also retains SHA256, verification status, latest 1C log path, and the manual import note.

A standalone `/DumpCfg <file>` (including `-Extension <name>`) may finish while
another Enterprise/ROCTUP session keeps the infobase open. The helper still
requires its own Designer processes to finish, valid stable output, and passing
exit/log checks. It does not require exclusive file-base availability for this
read-only step. Configuration loads, updates, snapshots and combined commands
retain their existing release requirements. Never close foreign sessions or
bypass runtime locks to finish an export; a CF/CFE without the official manifest
is not a completed result.

Result manifest schema 3 records artifact SHA256, operation, branch metadata, master/development base commits, working-tree provenance, configuration and verification fingerprints, verification status/report/log, `verification.policy`, `verification.decision` (`fresh-passed` or `warn-unverified`), latest 1C log path, publication URL, and manual import note. The legacy `unverifiedOverride` key remains false unless the legacy flag was actually passed. A development commit in a dirty-tree manifest is the base commit, not a claim that the exported content was committed.

Verification freshness uses a versioned canonical Git tree fingerprint of configured configuration, extension, and feature paths. A temporary index materializes the effective scoped working tree without changing the user's index. Committing exactly that checked content preserves the fingerprint; staging, unstaging, or committing files outside the scope also preserves it. Any effective scoped content change makes previous evidence stale.

Configuration and extension loads use a separate versioned Git-tree source fingerprint. It hashes canonical Git tree records instead of reopening every source file, includes effective staged, unstaged, untracked, and ignored source files, and excludes `ConfigDumpInfo.xml`. An existing legacy SHA256 source fingerprint is recalculated once and migrates without Designer only on an exact match; a mismatch still follows the normal partial/full load safety path.
The `v5` fingerprint uses only verification-relevant dependency-lock fields. A
passed result also records the exact target infobase and loaded configuration /
extension identity, including the target and runner infobase generations; older
proof without that identity is stale once. A workflow-only update does not run
tests or automatically invalidate compatible proof; the next ordinary
assessment runs only checks whose relevant source, loaded state, runner, checker
or acceptance inputs changed. The first check or refresh
records a legacy baseline so unchanged old BSL does not require new tests.
Schema-2 obligation `inputPaths` also enter the fingerprint. A changed declared
OpenSpec requirement selects its retained owning suite; an unrelated change
outside those paths does not invalidate proof.

One-off receipts also bind the actual functions that assess their validity.
A changed relevant checker or an old receipt without that identity requires
`begin-one-off-proof` and a new observed result with the current checker;
unknown compatibility is never passed. A checker change between begin and
complete leaves the receipt pending with the same continuation. JUnit parser
changes affect JUnit receipts without invalidating unrelated runtime
observations. Invocation permission and its expiry remain provenance, separate
from proof freshness; a passed sufficient result can be reused after its named
invocation ends while persistent execution stays off. File-only installation
does not run the new proof automatically.

For a checked source or CFE load, the ITL owner creates a native DT rollback
snapshot before changing the editable configuration. When the enclosing
extension-init or Release operation already owns a pending snapshot for this
exact target, the checked load uses it without changing its completion policy.
For an extension source load, the ITL owner loads the editable configuration,
then runs Designer `/CheckModules`, extension applicability and `/CheckConfig`
before `/UpdateDBCfg`. Under the generic policy each check needs a zero process exit, a fresh numeric
`/DumpResult=0`, and a UTF-8 `/Out` log without remaining warnings or errors.
For main configuration loads, changed BSL/XML or an unknown/full-load delta
selects `/CheckModules` and `/CheckConfig` before apply; a known binary-only
delta keeps the existing direct path. A selected small partial quick-fix may
omit the ladder only with complete, current raw MCP proof for every changed
BSL/XML input. Missing, stale or incomplete proof uses the platform fallback.
See [platform validation evidence](platform-validation-evidence.md) for the
existing `VerificationEvidencePath` input and its exact-source contract.
`GATE6_CHECK_FAILED` stops database apply and restores the owned DT snapshot;
correct the named source finding and repeat the original ITL operation.
A failed applicability check does not trigger the partial-load full fallback;
the owner also restores the byte-exact `ConfigDumpInfo.xml` cursor.
`GATE6_SNAPSHOT_FAILED` leaves platform evidence unverified before editable
mutation. If rollback fails, `GATE6_SNAPSHOT_RECOVERY_FAILED` retains the exact
snapshot, its SHA and both diagnostics; recover that target through the existing
snapshot owner before repeating the original operation. A completed apply is
not replayed as rollback after a lost completion acknowledgement.
The proof is recorded under
`lastGate6Evidence` with source, editable-load arguments/log hash, target,
modes, snapshot identity and check artifact hashes.
Every completed ladder also writes an ignored `1c-gate6-evidence-*.json` receipt
beside its result and log files, including tooling installs that do not update
the source-load state. Compilation and extension applicability remain strict under the generic policy; the narrowly scoped internal engine exception below is separate from main-CF legacy assessment.
Managed main-CF structural findings may continue only when the load owner
proves complete unchanged before/after findings outside the change and its
impact scope, with matching source, target, snapshot and native check inputs.
This records `accepted-with-preexisting-findings`, the original nonzero native
result and `nativePassed=false`; it is not a clean platform pass. New, increased,
inside-scope, unclassified or unbound findings stop apply with the existing
rollback and retry route. Agents must not create a baseline by editing State,
suppress warnings or repair unrelated product objects to satisfy this gate.
Empty/CFE extension initialization uses the same ladder inside its existing
infobase snapshot; a failed check restores that snapshot before retrying the
original initialization after a source repair.
The owner also compares the source fingerprint or CFE SHA after editable load;
a changed input stops before any check or database apply.
The same owner checks CFE installs for YAxUnit, Vanessa UI MCP and Data MCP;
their prior tooling readiness and recovery routes remain the continuation.

### Immutable YAxUnit engine diagnostics

The managed USER-RULES override applies only to helper-owned installation of
the official immutable `YAXUNIT` engine. The existing YAxUnit dependency owner
internally selects one canonical version/tag/asset/URL/upstream/SHA baseline
for `YAxUnit-25.12.cfe`, SHA256
`805a2277c997a3c24be0b0d080696479e91e4a15ed7e27aaf3991a7346522d70`.
Another pin cannot inherit it merely by matching the lock. Agents cannot supply
allowed messages, a public skip or an environment override. Product CF/CFE,
the tests extension and other dependencies retain all generic strict checks.

Modules must strictly pass with native exit/DumpResult `0/0`. Applicability may
continue as WARN only with native `0/0` and its four exact canonical annotation
lines (two texts, twice each); configuration may continue only with `101/101`
and its two exact canonical helper-form handler lines (once each).
The owner reads complete strict UTF-8 Out and matches separate bounded ordinal
multisets, preserving message spaces. Only encoding BOM, line separators and an
ordinary terminal newline may normalize for comparison. Filtered diagnostics,
substring matching, line counts or success fragments are insufficient.
Extra/unknown/altered/missing lines, repetition overflow, invalid output/result,
nonzero compilation/applicability or another nonzero code pair retain the
original strict failure. Ordinary clean `0/0` behavior remains unchanged.

The checked-load owner rechecks exact artifact SHA before editable load, after
load and immediately before first apply. It retains raw bytes/hashes/codes,
canonical baseline identity, actual target/platform/modes and explicit WARN;
the vendor steps retain `nativePassed=false` and the assessment
`cleanPassed=false`. Snapshot, guard, timeout, split load/apply, rollback,
`-WarningsAsErrors`, runtime protection reconciliation and exact installed
extension runtime proof remain mandatory. A mismatch stops apply and uses the
same original-operation recovery; do not patch an installed artifact or receipt.

Observed live evidence covers only platform `8.3.27.2130`, file infobase and
thin client. Instrumented callback evidence and failed whole diagnostic drivers
are not official-CFE or Release acceptance. Ordinary/server/other-platform
qualification is not inferred, and missing evidence alone introduces no new
support barrier. The original Release still qualifies the official CFE and
both original ondemand backend families under their existing native/apply/runtime
owners; no vendor, pin, public command or coordinator changes follow from WARN.

When Gates 1–3 validators are unavailable, this same already-authorized
load/check/apply route supplies platform syntax/context and structural evidence
for its exact artifact and target. It does not claim semantic logic or standards
review passed. Read-only work never grants a configuration load. Without an
authorized matching dev/test target, record unverified evidence and the upstream
delivery limitation; there is no new blanket delivery block or bypass of ITL
apply requirements. For EDT-format sources, use EDT validation and its qualified
update owner, or an explicitly selected XML export/import route; never add this
ladder as a second deployment owner in the same run.

## Verification Policy

`verificationPolicy=warn` is the default: result export warns and continues, while advanced close retains its explicit unverified confirmation. `verificationPolicy=block` forbids both until `/itl-check` or `verify-dev-branch` is fresh passed. Fingerprint changes during export always stop the operation.

Parallel independent development lines should use separate `itldev/*` worktrees. One development branch may remain long-lived and contain several sequential tasks, but verification freshness is still evaluated before result export.

## Troubleshooting

- If verification is missing, failed, stale, or unknown, run `/itl-check`.
- If 1C Designer reports an infobase configuration lock, close the manual Configurator or wait for the helper's previous Designer process to exit.
- If `1cv8.exe` exits with code 1 or hangs behind `-WindowStyle Hidden`, check native quoting. `Start-Process -ArgumentList` must receive one joined and correctly quoted command-line string; otherwise paths with spaces are split incorrectly.
