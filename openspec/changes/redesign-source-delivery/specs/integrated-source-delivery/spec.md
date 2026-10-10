# Integrated source delivery

## Purpose

Принимать изменения в общий проверяемый кандидат, сохранять независимую работу
и доставлять зафиксированный installable-выпуск с применимыми доказательствами.

## ADDED Requirements

### Requirement: Registration proves the next integrated candidate
Registration SHALL integrate a change with the accepted candidate and detect
conflicts before release qualification. Required delta checks MUST compare the
previous and next integrated candidates, without treating already accepted
changes as new task work.

#### Scenario: Individually valid branches conflict
- **WHEN** a task's branch conflicts with an accepted queued change
- **THEN** registration reports the integration conflict before running release qualification and preserves the existing candidate and task work

### Requirement: Concurrent registration uses bounded atomic acceptance
Independent registrations SHALL perform long checks outside the shared state
critical section. Acceptance MUST atomically verify the expected candidate and
queue inputs; concurrent movement MUST preserve applicable proof and recheck only
changed dependencies within a bounded original operation budget.

#### Scenario: Candidate moves during a check
- **WHEN** another registration changes the candidate while a task is checking
- **THEN** the task cannot accept stale combination evidence and continues with only the newly affected checks or returns a resumable bounded result

### Requirement: Qualification freezes an installable release
Release qualification SHALL freeze its composition, required dependencies and
artifacts and bind proof to the corresponding installable candidate. Subsequent
independent registrations MUST remain for the next release without changing the
frozen release or losing their queue entries.

#### Scenario: New task registers during qualification
- **WHEN** a task registers after a release has frozen its composition
- **THEN** the current qualification keeps its candidate and completion preserves the newer task for the next release

### Requirement: Delivery resumes applicable qualification
Publication SHALL use valid proof for the corresponding candidate and continue
delivery after a transfer failure without rerunning unchanged 1C qualification.
Changed inputs, damaged evidence and remote movement MUST retain the existing
owner-controlled recovery and no-bypass rules.

#### Scenario: Artifact transfer fails
- **WHEN** delivery fails after candidate qualification and qualification inputs remain unchanged
- **THEN** recovery resumes delivery with the retained evidence and does not launch 1C again

### Requirement: Existing state has a safe transition
The workflow SHALL preserve pending queue work, pinned publication authority,
existing proof and supported cancellation/recovery when introducing the common
candidate protocol. Changes to shared authority MUST receive the architecture
checkpoint required by the repository before dependent implementation.

#### Scenario: Existing queue is adopted
- **WHEN** the new implementation encounters an existing queue or saved publication plan
- **THEN** it follows a verified compatible transition or returns an owner-usable continuation without manual state edits or lost work
