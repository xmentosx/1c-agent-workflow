# Source test selection

## Purpose

Обеспечить обоснованные проверки исходного workflow, независимые окружения и
переиспользование доказательств без потери регрессий и ложной готовности выпуска.

## ADDED Requirements

### Requirement: Test necessity and execution are attributable
The workflow SHALL identify the behavior, risk, production inputs, execution route,
environment and resources of every source test family and its cases. Removal or
replacement MUST retain equivalent evidence for the original observed failure
unless concrete evidence establishes that the expectation itself is invalid.

#### Scenario: Audit includes nested suites
- **WHEN** a Pester case launches a Python, Go or Node suite
- **THEN** the audit identifies both the wrapper and the nested cases and distinguishes static definitions from expanded executed cases

#### Scenario: A test is proposed for removal
- **WHEN** an existing regression is removed or replaced
- **THEN** the decision identifies the invalid expectation or equivalent retained proof without changing the original reproducer to avoid the defect

### Requirement: Selection follows proved behavior dependencies
The workflow SHALL select only checks justified by changed behavior and declared
dependencies. Unknown ownership or dependencies MUST preserve the existing
conservative failure/reuse rules rather than silently produce green evidence.

#### Scenario: Independent component change
- **WHEN** a change affects only one MCP component and its tests
- **THEN** the check requires that component's environment and does not require unrelated component runtimes

#### Scenario: Documentation-only change
- **WHEN** a change modifies only documentation without executable or installed-behavior inputs
- **THEN** the check performs applicable documentation checks without launching 1C or requiring Python

### Requirement: Reuse covers actual test and runtime inputs
The workflow SHALL reuse only successful evidence with matching test inventory,
production and loaded dependencies, checker identity and required external runtime
identity. Unknown external identity MUST NOT qualify reusable proof.

#### Scenario: Actual dependency changed
- **WHEN** a loaded production dependency or required interpreter environment changes
- **THEN** affected evidence is invalidated while independently applicable evidence remains reusable

### Requirement: Independent registrations remain isolated and measurable
Independent checks SHALL run without modifying another task's files, processes,
ports or result artifacts. Performance acceptance MUST include cold preparation,
warm execution and recovery, using existing measurements when available.

#### Scenario: Two checks overlap
- **WHEN** independent tasks register from separate worktrees concurrently
- **THEN** their results and cache writes remain correctly attributed and cancellation affects only owned processes

#### Scenario: Performance comparison
- **WHEN** a small-change route is accepted as faster
- **THEN** its report includes preparation and retry costs and compares the existing 300-second Targeted target without introducing a new hard timeout
