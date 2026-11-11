# Source gate failure classification

## Purpose

Отличать недетерминированные отказы Pester от воспроизводимых, не ослабляя гейт,
и делать нестабильные тесты видимыми как рабочие задачи.

## ADDED Requirements

### Requirement: Failed Pester files receive one diagnostic isolated rerun
After a Pester stage fails, the gate SHALL rerun only the failed test files once,
serially and isolated from other workers, within the remaining stage budget.
The rerun is diagnostic: the gate MUST still fail, and no proof, cache entry or
registration MUST be produced from the rerun.

#### Scenario: Failure reproduces in isolation
- **WHEN** a test file fails in the parallel run and fails again in the isolated rerun
- **THEN** the gate fails with the ordinary failure class and the failure record lists the reproduced tests

#### Scenario: Failure does not reproduce
- **WHEN** a test file fails in the parallel run and passes in the isolated rerun
- **THEN** the gate still fails, the failure class is `nondeterministic`, and the record names each such test with both outcomes

#### Scenario: No budget for the rerun
- **WHEN** the remaining stage budget cannot cover the measured cost of the failed files
- **THEN** the rerun is skipped, the record states that classification was not attempted, and the failure class is unchanged

### Requirement: Classification informs diagnosis without bypassing the circuit breaker
A `nondeterministic` classification SHALL be recorded in the run and publication attempt
and SHALL be shown in the failure message as the diagnosis direction (fix the unstable
test or its environment). The existing repeated-failure circuit breaker and explicit
supervised retry MUST remain unchanged.

#### Scenario: Same stage fails twice with a flaky test
- **WHEN** a publication stage fails twice for the exact candidate and the second failure is `nondeterministic`
- **THEN** the existing block applies, and its message names the unstable tests and their isolated-rerun evidence as the diagnosis to perform before an explicit retry

### Requirement: Status reports unstable tests from the existing run index
Status SHALL list tests that failed and later passed on an identical tree, and tests
classified `nondeterministic`, from the existing bounded run index. It MUST NOT introduce
a new service or persistent store.

#### Scenario: Viewing unstable tests
- **WHEN** the user requests detailed status
- **THEN** the output lists each unstable test with occurrence count, last occurrence and its run records

### Requirement: Publication refuses a frozen plan superseded by a newer accepted head
Before running any gate stage, publication SHALL compare each queue entry frozen in the
active plan with the currently accepted head of the same queue id. When an accepted head
differs from the frozen head, publication MUST NOT re-run the frozen candidate. It MUST stop
immediately, preserving the checkpoint and proof, and name the replan continuation for
that plan, in the same way as a moved remote base. This applies while the plan has no qualified
phase; a plan that already qualified a phase continues it and leaves later registrations to the next
publication, and a Frozen-scope replacement keeps its own contract.

#### Scenario: Fix re-registered after a failed Develop gate
- **WHEN** a frozen plan failed on a test, the entry's fix was re-registered with a newer accepted head, and a plain publication is started
- **THEN** publication stops before building the stale candidate, names the entry with its frozen and accepted heads, and gives the replan command for the active plan

#### Scenario: Unchanged queue
- **WHEN** every frozen entry still matches its accepted head
- **THEN** the frozen plan resumes as before
