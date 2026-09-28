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

#### Scenario: External requirements change without source changes
- **WHEN** acceptance relevant to an existing proof changes in the selected store
- **THEN** the dependent proof becomes stale even if the source fingerprint is unchanged

#### Scenario: Incomplete runtime obligation
- **WHEN** only a fragment or filtered subset was checked while integration remains applicable
- **THEN** the result reports partial coverage and cannot pass block export as whole-task verification

### Requirement: EV4 Execution settings do not prohibit test authoring
Execution off SHALL not prohibit preparing needed test artifacts. An explicit
request for a named one-off component SHALL authorize that invocation without
persistently changing its setting. A broader current no-UI instruction, target
authorization and missing required capabilities still apply.

#### Scenario: Named Vanessa run with its persistent mode off
- **WHEN** the user explicitly requests that scenario and no broader no-UI instruction forbids it
- **THEN** that run is allowed in the authorized scope, the persistent mode remains off, and unrelated components do not start

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
