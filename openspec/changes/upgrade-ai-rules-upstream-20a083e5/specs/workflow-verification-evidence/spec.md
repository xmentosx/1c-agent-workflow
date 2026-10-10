## ADDED Requirements

### Requirement: EV1 Upstream depth with preserved ITL validator discipline
Gate selection SHALL follow the target upstream depth/triage matrix. Standalone
syntax evidence, preferred check_1c_logic with check_1c_code fallback, closing
coherent snapshot, bounded unusable-response recovery and honest adjudication
SHALL apply to root rules, operation skills, direct commands and subagents alike.

#### Scenario: Direct validate and delegated implementation
- **WHEN** either entrypoint verifies the same scope and depth
- **THEN** selected gates, preferred checker, retry budget and treatment of disputed findings agree

### Requirement: EV2 Current proof, retained regression and cadence are independent
The agent SHALL choose current proof sufficient for the behavior and risk, decide
whether a retained regression adds future value, and choose its justified cadence.
Existing sufficient coverage SHALL be reused. Dangerous defects alone MUST NOT
force a new user approval or permanent test; the decision and proof remain explicit.
Separate test-plan.md SHALL not be mandatory; existing plans and approved criteria
SHALL be retained and read.

#### Scenario: Reliable one-off proof without a retained test
- **WHEN** current evidence covers every applicable obligation and retaining a new test adds no justified value
- **THEN** the task can be ready, including under block policy, without fake suite success or notApplicable

#### Scenario: Expensive retained coverage
- **WHEN** an expensive functional integration or UI regression has handoff cadence
- **THEN** an intermediate check may use sufficient current proof without running it needlessly, but a due handoff without fresh applicable evidence runs it; its purpose remains functional

### Requirement: EV3 Proof identity and freshness govern all consumers
Evidence SHALL bind obligation, expected outcome, checked inputs, relevant
requirements revision, source/fragment identity, target infobase and loaded state,
actual runner, result and limitations. Readiness, canonical check, repair, export
and close MUST use one assessment. Relevant changes invalidate dependent proof;
unrelated edits and committing identical checked content do not.
Execution authorization SHALL be recorded as provenance separately from proof
sufficiency. Expiry of a permitted one-off invocation alone MUST NOT invalidate
its proof. An unrelated package version or dependency-lock entry change MUST NOT
invalidate proof; changed relevant checker/runner/acceptance inputs SHALL do so.
The existing verification owner SHALL make that assessment without treating an
unknown compatibility result as passed. A file-only workflow update MUST NOT
automatically execute newly required checks.

#### Scenario: External requirements change without source changes
- **WHEN** acceptance relevant to an existing proof changes in the selected store
- **THEN** the dependent proof becomes stale even if the source fingerprint is unchanged

#### Scenario: Incomplete runtime obligation
- **WHEN** only a fragment or filtered subset was checked while integration remains applicable
- **THEN** the result reports partial coverage and cannot pass block export as whole-task verification

#### Scenario: Workflow-only update preserves applicable proof
- **WHEN** package/reporting files or unrelated lock entries change without changing checked inputs or the relevant verification contract
- **THEN** existing proof remains reusable and neither a database reload nor a test run is triggered solely by that update

#### Scenario: Updated checker fixes a false-success defect
- **WHEN** the new checker changes the validity of an earlier successful result
- **THEN** dependent proof becomes stale with a reason for the next ordinary assessment/export/close; unrelated proof remains, and file installation itself does not launch tests

### Requirement: EV4 Execution settings do not prohibit test authoring
Execution off SHALL not prohibit preparing needed test artifacts. An explicit
request for a named one-off component SHALL authorize that invocation without
persistently changing its setting. A broader current no-UI instruction, target
authorization and missing required capabilities still apply.

#### Scenario: Named Vanessa run with its persistent mode off
- **WHEN** the user explicitly requests that scenario and no broader no-UI instruction forbids it
- **THEN** that run is allowed in the authorized scope, the persistent mode remains off, and unrelated components do not start

#### Scenario: One-off permission expires before ordinary check and export
- **WHEN** a named run produced sufficient complete proof, its invocation ended, and persistent execution remains off
- **THEN** canonical check and block export reuse that fresh proof without a second UI run or persistent setting change; genuinely changed inputs or obligations still invalidate it

### Requirement: EV5 Capability policy is provider-aware and non-bypassable
Effective policy SHALL distinguish authoring, saved Vanessa, interactive UI,
YAxUnit, data queries and each provider. required without an available provider
blocks the dependent step; invalid settings report correction; off cannot be
bypassed via an alias, CLI or HTTP. A one-off authorization SHALL be explicit in
the effective invocation policy, not a hidden fallback around a disabled provider.

#### Scenario: ROCTUP equivalent data provider
- **WHEN** a read-only data obligation uses qualified ROCTUP instead of 1c-data-mcp
- **THEN** TOOL_DATA applies, the same exact target/read-only boundary is enforced, and equivalence is recorded

#### Scenario: Read-only call finds the base not ready
- **WHEN** the base requires configuration loading and that mutation was not authorized
- **THEN** the call remains unverified with a supported continuation; read authorization does not silently authorize a base update

### Requirement: EV6 One repair session and remaining budget
test-fix-loop SHALL use the ITL repair-session owner, exact requested scenarios
and one remaining attempt budget. Scenario selection, deploy recovery and native
process retry MUST NOT create nested product-fix budgets. Resume preserves counts
and scope. Fixed expectations require evidence that the old expectation was wrong.
Changing an agreed expected business result SHALL additionally require user
confirmation, as upstream requires; correcting a faulty fixture or step to reach
the existing agreed outcome does not change that outcome.

#### Scenario: Three requested iterations invoke ITL repair
- **WHEN** the caller requests three iterations
- **THEN** one session has three outer attempts, not three sessions of five; resume cannot reset the budget

#### Scenario: Fix invalidates a previously passed scenario
- **WHEN** a later fix affects a previously passed obligation
- **THEN** it is rechecked before completion; passing only the last failed scenario is insufficient

#### Scenario: Actual behavior contradicts the agreed expectation
- **WHEN** the loop observes a different business result and believes the expectation is wrong
- **THEN** it explains the evidence and retains the agreed expectation until the user confirms its change; it cannot rewrite the requirement merely to obtain a pass

### Requirement: EV7 Canonical completion preserves actual failures
Canonical unfiltered itl-check SHALL assess every current applicable obligation
after the last relevant edit, consuming fresh evidence where valid. An intentional
absent suite with sufficient alternative proof SHALL be distinguishable from a
selected suite producing zero tests, invalid JUnit or failures. The latter remain
failures. Event-log, load state, snapshot and artifact SHA obligations remain.

#### Scenario: Broken selected test runner
- **WHEN** a selected runner returns zero tests or invalid results
- **THEN** alternative-proof support cannot relabel the failed execution as skipped or successful

### Requirement: EV8 Conditional platform Gate 6 belongs to the ITL apply owner
The existing load/check/apply owner SHALL verify applicability before extension
application, or main configuration load/apply with relevant metadata/modules not
covered by MCP validation. It SHALL bind the artifact to the editable configuration and
run the upstream platform ladder before UpdateDBCfg. CheckModules SHALL include
applicable runtime modes; extension applicability SHALL be checked for extensions;
CheckConfig SHALL follow when selected. The same owner SHALL provide authorized dev/test
platform fallback for unavailable Gates 1–3 validators where applicable.
Snapshot, per-infobase guard, native process ownership, timeout and scoped recovery
SHALL remain authoritative; no separate raw launcher or second EDT deployment
owner is introduced. Failure SHALL stop apply and provide the original operation's
recovery/continuation. Pass SHALL require process exit, a fresh numeric DumpResult
and Out diagnostics to agree for a clean pass; module compilation and extension
applicability warnings fail. Main-configuration structural findings SHALL follow
the legacy compatibility requirement below. Success phrases SHALL neutralize
only their own fragments, never other findings on the same line.
Evidence SHALL record artifact/loaded-state identity, target/extension, platform,
modes and all three result signals. Reuse SHALL require matching relevant inputs.
When no authorized platform/test base is available, the owner SHALL report
unverified evidence and the upstream delivery limitation, not a new blanket
delivery block or permission to bypass existing ITL apply requirements.
File-only workflow update has no Gate 6 trigger.

#### Scenario: Extension interceptor points to a removed method
- **WHEN** static validators pass but the platform applicability check reports the missing method
- **THEN** the owner stops before applying to the database, preserves diagnostics and offers scoped recovery through the original command

#### Scenario: Process exit is zero but another signal fails
- **WHEN** DumpResult is nonzero/missing or Out contains a warning/error even alongside a success phrase
- **THEN** the gate fails without treating exit code zero or a clean fragment as a pass

#### Scenario: Evidence belongs to a different loaded artifact or runtime mode
- **WHEN** a prior platform result does not match the current artifact, relevant target state or required modes
- **THEN** it is not reused as current applicability proof and the owner performs the required authorized checks before apply

#### Scenario: No suitable platform target or EDT owns deployment
- **WHEN** no authorized matching dev/test base is available or the project uses the qualified EDT validation/update path
- **THEN** the former remains explicitly unverified under delivery policy and the latter uses its equivalent evidence without a second deployment owner

### Requirement: EV8a Small validated CF changes retain the conditional Gate 6 trigger
The existing load owner SHALL distinguish a small partial main-configuration
change covered by current MCP validation from a full/unknown/uncovered load.
Verified coverage SHALL bind saved BSL/XML inputs and raw validator results to
the exact artifact and target; a setting, declared success or stale receipt is
not coverage. A covered small partial change SHALL NOT automatically select the
full platform ladder. Missing or invalid coverage SHALL retain the applicable
platform fallback and its original-command continuation. Full loads and extension
applicability SHALL NOT be skipped through partial-change evidence.
The covered load SHALL retain snapshot-backed editable-load/apply boundaries
and revalidate source and captured evidence bytes after load, before apply.
The upstream full-text syntax fallback SHALL qualify only when the complete
strict UTF-8 saved module matches the actual request and both provider input
descriptors. Removing an encoding BOM SHALL preserve every subsequent character
and line ending. A matching path alone SHALL NOT establish the remote input.

#### Scenario: Covered partial change
- **WHEN** a small partial CF delta has matching successful validation for every relevant saved input
- **THEN** loading it does not automatically run the full configuration check
- **AND** editing an input or invalidating its proof removes that exemption

#### Scenario: Validation evidence changes during editable load
- **WHEN** the saved input, captured receipt or its raw validator artifacts change during the covered editable load
- **THEN** the owner stops before database apply and restores its confirmed snapshot and cursor
- **AND** repeating the original command requires current proof or the original platform fallback

#### Scenario: Remote syntax provider exposes only the full-text tool
- **WHEN** the actual provider lacks the file tool but validates the complete saved module through syntaxcheck
- **THEN** matching raw request, response, analyzer and input descriptors can qualify that same saved input
- **AND** snippets, rewritten input, ordinal text mismatches and unbound remote paths retain the platform fallback

### Requirement: EV8b Legacy structural findings do not create unrelated product work
For a main configuration, the load owner SHALL preserve complete native results
and distinguish introduced or worsened structural findings from proven existing
findings outside the change scope. A previous result SHALL be usable only when
its source corpus, target/layer, platform, runtime modes and relevant extension
state are established; an empty unrelated base or the first failed log is not
an approved baseline. Unknown diagnostics, incomplete evidence and inside-scope
findings SHALL remain unresolved and stop the dependent apply until adjudicated.
Confirmed unchanged outside-scope findings MAY permit the original operation
to continue with an explicit legacy-diagnostics assessment. That assessment
SHALL NOT relabel native nonzero results or warnings as a clean Gate 6 pass.
Compilation, exact-target/source identity, snapshot, guard, timeout, rollback
and fresh executable verification remain strict. Extension applicability remains
strict apart from the explicitly artifact-bound YAxUnit vendor Out diagnostics
below; its native exit/DumpResult `0/0` remain mandatory.
The owner SHALL use operation-local evidence and the existing recovery flow;
no global whitelist, baseline coordinator or blanket warning suppression is added.
After a confirmed exact owned snapshot rollback and cursor restoration, the
existing load owner SHALL retain the previous loaded-corpus proof for retry;
it SHALL NOT mark the failed candidate passed or infer restored proof from an
unconfirmed, borrowed or ambiguous apply result.

The decision accepted on 2026-10-07 adds one subordinate exception to EV8/EV8b:
the existing YAxUnit dependency owner MAY internally select its canonical
artifact-diagnostic baseline only for engine `YAXUNIT`, version/releaseTag `25.12`,
asset `YAxUnit-25.12.cfe`, upstream commit
`15f7ae557d17b59bd80daad503efd8a3114690e5`, the official release URL
`https://github.com/bia-technologies/yaxunit/releases/download/25.12/YAxUnit-25.12.cfe`
and SHA256 `805a2277c997a3c24be0b0d080696479e91e4a15ed7e27aaf3991a7346522d70`.
This canonical record SHALL NOT be supplied by a public skip/override, inferred
from any new lock pin, or applied to product CF/CFE, the tests extension or other
dependencies. Compilation SHALL still strictly pass with native exit/DumpResult
`0/0`. Applicability SHALL require native `0/0`; configuration admission SHALL
require the exact native `101/101` pair and complete per-step raw multiset below.

| Step | Exact raw diagnostic line | Required count |
|---|---|---|
| Applicability | `YAXUNIT: Не найден метод "ОбработкаОтображенияОшибки", указанный в аннотации метода "ЮТОбработкаОтображенияОшибки".` | 2 |
| Applicability | `YAXUNIT: Не найден метод "ErrorDisplayProcessing", указанный в аннотации метода "ЮТErrorDisplayProcessing".` | 2 |
| Configuration | `YAXUNIT Обработка.ЮТПомощникДляСозданияТестовыхДанных.Форма.Форма.Форма Отсутствует обработчик:  СнятьВсеФлажки "СнятьВсеФлажки"` | 1 |
| Configuration | `YAXUNIT Обработка.ЮТПомощникДляСозданияТестовыхДанных.Форма.Форма.Форма Отсутствует обработчик:  УстановитьВсеФлажки "УстановитьВсеФлажки"` | 1 |

The owner SHALL compare the entire strict UTF-8 Out ordinally, preserving all
message characters and spaces. Only the encoding BOM, line separators and an
ordinary terminal newline MAY be normalized for comparison; original raw bytes
and SHA SHALL be retained. The two step multisets SHALL NOT be pooled. Unknown,
additional, altered or missing lines, repetition overflow, unreadable/invalid
output or result, nonzero compilation/applicability, or any other nonzero
exit/DumpResult pair SHALL retain the original refusal and snapshot recovery.
An ordinary clean `0/0` result remains on the existing strict clean path.

The checked-load owner SHALL bind the CFE to the canonical pin and recheck its
SHA before editable load, after load and immediately before first apply.
A matching exception SHALL retain explicit WARN, complete raw codes/hashes,
baseline identity and actual context, with `nativePassed=false` and
`cleanPassed=false`; it SHALL NOT rewrite the generic native verdict.
Snapshot, per-infobase guard, timeout, split load/apply, rollback,
`-WarningsAsErrors`, runtime protection reconciliation and exact runtime proof
SHALL remain unchanged. No new persistent coordinator, public switch,
platform/topology support barrier, vendor modification or pin change is added.

Observed live evidence covers only platform `8.3.27.2130`, a file infobase and
thin-client dispatch. Instrumented callback evidence SHALL NOT qualify the
official CFE or original Release; a failed whole diagnostic driver, including
its raw database-byte postcondition, SHALL NOT be relabelled as acceptance.
Ordinary-client/server/other-platform acceptance remains unverified, without
creating a new barrier solely from that absence. The original Release SHALL
still exercise the official CFE and both original ondemand backend families
with unchanged workload, assertions, runtime proof and cleanup.

#### Scenario: Exact pinned YAxUnit vendor diagnostics
- **WHEN** the internal dependency owner selects the exact canonical engine pin, strict modules pass, and applicability/configuration match their complete raw multisets and native code pairs
- **THEN** the original guarded apply can continue with explicit WARN and all snapshot/runtime obligations retained
- **AND** the original native failed verdict remains visible; no clean Gate 6 or Release acceptance is inferred

#### Scenario: Artifact or diagnostics differ from the accepted YAxUnit baseline
- **WHEN** pin/name/scope/CFE bytes drift, any required SHA recheck fails, or diagnostics/results differ from the exact per-step baseline
- **THEN** the same operation refuses apply and preserves its existing snapshot-backed continuation
- **AND** generic intercepted-method, product CF/CFE, tests-extension and other dependency failures remain strict

#### Scenario: Existing configuration has unchanged structural findings
- **WHEN** a full deployment reproduces confirmed previous outside-scope findings and introduces no unresolved finding
- **THEN** the original load/check/apply and verification can complete with the findings retained as warnings
- **AND** the native failed result remains visible and is not reported as a clean check

#### Scenario: New failure hidden among existing findings
- **WHEN** a candidate introduces or worsens a finding, lacks complete comparison evidence, or fails compilation/applicability
- **THEN** the original operation stops before apply and retains snapshot-backed recovery

#### Scenario: Original load continues after a confirmed rollback
- **WHEN** a rejected candidate is restored to the exact owned prior target and cursor and its defect is corrected
- **THEN** the same load command can reconstruct the previous-corpus context and complete its original apply
- **AND** the rejected candidate and its native failure remain visible as failed evidence

#### Scenario: A confirmed previous compiler defect is repaired
- **WHEN** complete before evidence contains a recognized compiler defect inside the repair scope and strict current CheckModules proves it was resolved
- **THEN** the assessment retains it as a resolved previous compiler finding separate from legacy structural findings
- **AND** an unknown or incomplete before diagnostic, any current compiler defect, or missing current compilation proof still stops apply

### Requirement: EV8c The original PM5 acceptance reproducer is retained
Acceptance SHALL establish the actual test corpus and installed extension
inventory, repair the confirmed procedure-with-return compilation defect in the
owned stand, and repeat the original fresh journey on that stand. It SHALL NOT
replace the corpus, remove check switches, hide diagnostic lines, or bypass
Vanessa, export, refresh and rollback to avoid the observed failure. Existing
failed receipts and source-restoration evidence SHALL be retained.

#### Scenario: Original fresh acceptance follows the owned corpus repair
- **WHEN** the confirmed stand compilation defect is corrected with complete source/target evidence
- **THEN** the same original fresh journey, Vanessa, export and refresh are repeated with original workload and assertions
- **AND** the failed runs and snapshot recovery proof remain available

### Requirement: EV9 Essential UI needs actual managed-route evidence
New projects SHALL default UI_TESTING to essential under accepted Q23. Missing or
empty resolves to essential; invalid retains the upstream manual fallback and
MUST NOT be reclassified as a stored legacy manual for migration. After an
authorized change reaches the dev/test infobase, essential SHALL automatically
check important new or changed user-visible behaviour with actual expected/actual
UI evidence bound to that artifact and target. auto checks all applicable
scenarios; manual requires an explicit request; off and a broader no-UI instruction
remain respected under EV4/EV5. Enabling policy alone MUST NOT authorize deploy,
infobase loading or the opt-in test-fix loop.
In managed scope the new fork SHALL use the existing ITL Vanessa UI route with
its authorization, provider and native-launch ownership contracts. Missing an
allowed route SHALL leave the dependent evidence unverified with the exact
prerequisite; an explicit permitted UI request makes that prerequisite blocking
for that step. Static evidence or a generic saved-suite pass MUST NOT be promoted
to confirmation of the requested interactive behaviour. ITL_VANESSA_TESTING SHALL
remain independent: essential neither enables saved suites nor changes that
setting. Standalone QA support is separate and remains unimplemented/unverified
until its own qualification. Historical 9ec proof does not qualify this new policy.
Policy activation SHALL require actual installed-rules support under IM7. A
source-only receipt/setting test SHALL NOT count as managed UI execution, live
legacy recovery, or qualification of the new c1 fork identity.

#### Scenario: Essential verifies the important changed behaviour
- **WHEN** an authorized UI change is present in the current dev/test base and the managed ITL Vanessa UI route is available
- **THEN** the agent obtains actual expected/actual evidence for that behaviour in the exact target, without silently enabling saved Vanessa or starting a repeated repair loop

#### Scenario: Essential lacks an allowed UI route
- **WHEN** essential applies but no authorized applicable UI route is available
- **THEN** the dependent scenario remains unverified with its missing prerequisite, independent work can continue, and static or saved-suite evidence cannot manufacture UI pass

#### Scenario: User retains a disabled or on-request UI policy
- **WHEN** off, a broader no-UI instruction, or later intentional manual is effective
- **THEN** essential default cannot bypass that policy, trigger deployment or rewrite the independent saved Vanessa setting
