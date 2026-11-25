# Reproducible source qualification

## Purpose

Подготавливать принадлежащие сценарию стенды из проверенного состояния каждой
фазы, сохраняя исходные отрицательные регрессии и успешную live-приёмку.

## ADDED Requirements

### Requirement: Qualification inputs include actual stand state
Qualification SHALL establish each phase's workflow package, dependencies,
configuration, actual database, Designer-baseline, cursor, pending operation and
expected outcome before the dependent expensive scenario. Git sources alone
MUST NOT establish equivalence of distinct database/baseline states.

#### Scenario: Identical sources have different Designer baselines
- **WHEN** two stands share configuration source bytes but have different trusted baselines or pending operations
- **THEN** qualification treats them as different scenario inputs and does not reuse incompatible proof

### Requirement: Phase preparation is owned and repeatable
The workflow SHALL prepare and restore scenario-owned disposable projects through
existing lifecycle and snapshot owners. Expected version transitions MUST be
performed as preparation; unexpected target or content mismatches MUST remain
detectable. Foreign projects and unrelated accumulated branches MUST NOT become
qualification fixtures or extend its work.

#### Scenario: Next candidate uses the stand
- **WHEN** a new candidate follows a qualified candidate
- **THEN** the appropriate upgrade baseline and installed-candidate phases are prepared without manual version or metadata edits

### Requirement: Original rejection and success remain independently proved
Qualification SHALL retain the original PM5 failure preconditions, prove rejection
before Apply and prove rollback, while independently proving the successful
upgrade and fresh journeys. A different fixture that no longer reaches the
observed defect MUST NOT replace its regression.

#### Scenario: Configuration is rejected
- **WHEN** the original invalid configuration reaches its declared rejection preconditions
- **THEN** Apply does not begin, the owned snapshot/cursor are restored and the receipt survives the real process boundary

#### Scenario: Valid scenario completes
- **WHEN** the independent positive scenario is qualified
- **THEN** required fresh passed, export and SHA checks complete on its owned stand

### Requirement: Server support retains truthful evidence
The workflow SHALL retain supported server behavior. Absent stand or server-reset
evidence SHALL be reported as unverified under the existing delivery contract,
without becoming a new publication barrier or permitting a direct push.

#### Scenario: Server stand is unavailable
- **WHEN** no applicable server-reset evidence can be obtained
- **THEN** the result distinguishes unverified server evidence while retaining the authorized standard publication route
