# Source check derivation

## Purpose

Проверки исходного репозитория защищают настоящие инварианты, не заставляя вручную
дублировать авторитетный источник. Расхождение обнаруживается до дорогого гейта
либо безопасно деградирует в более широкое выполнение.

## ADDED Requirements

### Requirement: Inventories derive from their authoritative source
A source check that needs an inventory of functions, actions, operations, consumers or
versions SHALL derive that inventory from the authoritative source it protects.
It MUST NOT require a hand-maintained copy whose only failure mode is a legitimate
addition. A replaced pinned check MUST still fail on the defect it was originally written for.

#### Scenario: A helper gains a new in-owner callee
- **WHEN** a production function loaded by a fixture starts calling another function defined in the same owner files
- **THEN** the fixture loads that callee without a test edit, and functions the test explicitly substitutes remain substituted

#### Scenario: A substitute is missing in scope
- **WHEN** the test file defines a function as a substitute but the calling block does not have it in scope
- **THEN** the call fails as a missing command naming that function, and the real owner function is never imported or executed

#### Scenario: A new public action is added
- **WHEN** an action is added to the entrypoint and fully registered
- **THEN** no test requires an updated total action or broker-operation count, and every action is still checked for a valid startup disposition with lifecycle-lock consistency

#### Scenario: A legitimate selection consumer is added
- **WHEN** a new quality contract adds a consumer of an already selected lifecycle path
- **THEN** the cohort capacity check uses the real selection and stays green while the estimated critical path remains within the Targeted hard budget minus its margin

#### Scenario: A legitimate consumer is added to a narrow path
- **WHEN** an additional owner declares a test for a narrow Targeted path
- **THEN** selection includes both owners and their tests and leaves unrelated paths unchanged
- **AND** the route keeps its explicit exclusions and uses the existing gate budgets

#### Scenario: Selection outgrows capacity
- **WHEN** the estimated critical path of the representative lifecycle selection exceeds the Targeted hard budget minus its margin
- **THEN** the capacity check fails and names the estimate, the budget and the largest contributors

### Requirement: Duplicated registries are reconciled before Pester
Registries that must enumerate the same public actions and component versions SHALL be
reconciled by the quality catalog validation that runs before any Pester stage. This covers
the action set (validate set, dispatch labels, lifecycle journey/boundary, action owners,
and the agent-facing advanced action catalog) and the on-demand MCP version and release tag
in the compatibility manifest and dependency lock. One failure MUST name every place that
disagrees.

#### Scenario: A new action is missing from documentation
- **WHEN** an action exists in the entrypoint but not in the agent-facing advanced action catalog
- **THEN** catalog validation fails within seconds of the gate starting, before Pester, and names the missing documentation entry together with any other missing registry

#### Scenario: Compatibility and lock disagree
- **WHEN** the compatibility manifest names a facade version different from the dependency lock
- **THEN** catalog validation fails before Pester and names both versions

### Requirement: Locked on-demand MCP build matches its source
When the change range modifies build inputs of the on-demand MCP component, the gate SHALL
verify, before Pester, that a build of the current source produces the executable SHA-256
named by the dependency lock. Changes that do not alter the built executable MUST pass naturally.
A single repository command MUST rewrite all lock and compatibility fields from one build.

#### Scenario: Go source changed without repinning
- **WHEN** a commit changes on-demand MCP production source and keeps the previous lock SHA-256
- **THEN** the early check fails before Pester and names the repin command

#### Scenario: Only Go tests or README changed
- **WHEN** only on-demand MCP test files or documentation change
- **THEN** the rebuilt executable matches the lock and the early check passes without a repin

#### Scenario: Repin
- **WHEN** the developer runs the repin command
- **THEN** lock version, release tag, URL, SHA-256 and the compatibility manifest are updated together from the same build, and tests read these values from the lock rather than holding copies

### Requirement: Proof-reuse invariants fail safe in production
An invariant that permits excluding inputs from a reusable proof SHALL be evaluated by the
production projection. When the invariant is not proven for the current tree (an unreviewed
caller, file version or consumer), the projection MUST fall back to the complete input
binding and execution with a recorded reason. It MUST NOT fail the gate.

#### Scenario: New caller of the retained-runtime reader
- **WHEN** a function outside the reviewed update-only set starts calling the retained-runtime busy-reason reader
- **THEN** the fresh cold-cutover projection is not applied, the affected scenario executes, the reason names the caller, and no Pester or Develop stage fails because of the new caller

#### Scenario: Audited consumer file is edited
- **WHEN** a hash-audited consumer of a reusable projection changes to an unreviewed version
- **THEN** reuse is withheld for the dependent scenarios with a recorded reason, while the reuse regressions still prove reuse on fixtures that hold the audited versions

### Requirement: Static checks are selected by the sources they read
A test that statically inspects a source file SHALL be selected when that file changes.
It MUST NOT rely on the file being only an invalidating reuse input of a broader process suite.

#### Scenario: Lifecycle change with a static source inventory
- **WHEN** a commit changes a source file that a static inventory check reads
- **THEN** Targeted selects that check, and its cost stays limited to the static check rather than the whole process suite

### Requirement: Source text assertions protect stable contracts
New source checks SHALL verify behavior by execution or by derivation from the parsed
syntax tree, not by regular expressions over implementation text. Text assertions are
permitted for prohibitions (forbidden legacy names or secrets) and for documentation
contract markers that are stable identifiers such as error codes, flags or action names,
not prose wording. When an existing implementation-text assertion breaks on a
behavior-preserving change, it MUST be replaced by a behavioral or derived check
instead of being updated to the new text.

#### Scenario: Error message is reworded
- **WHEN** an error message wording changes but its stable code and behavior do not
- **THEN** the owning check passes because it asserts the code or the behavior

#### Scenario: Documentation prose is reworded
- **WHEN** a documented rule is reworded while its stable identifier remains
- **THEN** the documentation contract check passes

### Requirement: Timing checks observe owned deadlines
A check of a timeout or watchdog SHALL assert the deadline recorded by the owning
component. It MUST NOT assert wall-clock duration that includes process startup,
host load or cleanup outside that deadline.

#### Scenario: Host under parallel load
- **WHEN** the watchdog test runs while parallel workers load the host
- **THEN** the test passes if the phase deadline was reserved once and the recorded terminal deadline matches it, regardless of total elapsed time
