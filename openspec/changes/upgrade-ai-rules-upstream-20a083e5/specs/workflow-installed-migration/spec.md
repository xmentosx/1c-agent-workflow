## ADDED Requirements

### Requirement: IM1 Transactional managed transition
Managed transition SHALL extend existing eligibility, exact source checks,
pre-write plan, dirty-state protection and snapshot recovery to all selected clients and changed
settings. Genuine userModified files and custom source repositories SHALL remain
protected. Byte-identical/strict UTF-8 EOL-only stale markers may be cleared only
under the existing ownership proof.
Each root transaction SHALL start before host package replacement and retain its
recovery snapshot through fresh-process post-copy, client/rules migration, commit
and terminal outcome. Target eligibility and locked-dependency migration SHALL
be planned before replacement; adding a component MUST NOT reset locked mode to
fresh. A later root failure SHALL preserve completed roots and report partial
rollout with an exact continuation instead of claiming all roots completed.
Rollback SHALL compare the expected post-state of owned files/config entries,
including ignored settings and ownership manifests. Later user changes MUST be
preserved with scoped reconciliation instead of replacement by an old snapshot.

#### Scenario: Failure after rendering several clients
- **WHEN** any postcondition fails during installation
- **THEN** the owned project snapshot is restored including client membership, manifest, dotenv and MCP, with a usable recovery report

#### Scenario: New helper fails before the rules snapshot exists
- **WHEN** package copying succeeded but post-copy fails before rules migration or its narrower snapshot
- **THEN** the retained pre-copy state supports recovery of one coherent root through the existing owner, including package, lock and settings; a stopped process can resume or restore without a manual reset

#### Scenario: Commit completed before the process stopped
- **WHEN** the updater stops after the root commit but before recording its terminal outcome
- **THEN** recovery reconciles the owned commit and installed bytes without duplicating the transition or rewriting unrelated history

#### Scenario: Later worktree cannot complete its update
- **WHEN** one root completed and a subsequent root fails
- **THEN** the report preserves per-root outcomes, retains completed roots and recovery for the failed root, and repeating update-workflow processes unfinished work idempotently

#### Scenario: User changes settings after a successful migration
- **WHEN** rollback finds later dotenv, MCP credentials or ownership changes
- **THEN** it preserves those current values and the recovery candidate, reports the exact conflicting scope and does not blindly restore the older snapshot

### Requirement: IM2 Existing projects and worktrees have explicit coverage
The migration SHALL inventory known managed project roots and registered worktrees,
record completed/deferred/blocked outcomes per scope, and preserve unrelated dirty
work. update-workflow SHALL update the main project and every available managed
worktree through one existing update owner with the exact candidate, reconciling
helper, rules, client surfaces, lock and owned settings together. It SHALL preserve
branch-specific infobases, connections and user settings. User-named additional
roots join the inventory without a broad disk scan.
This file update MUST NOT merge business configuration from master, load/update
an infobase or automatically run tests/Gate 6. A dependency needing installation
inside an infobase SHALL report pending preparation through the existing route;
downloaded bytes are not proof of installed runtime. A genuinely active operation
using affected code/resources SHALL defer replacement under the existing guards.
Unrelated dirty business files and stopped pending operations alone MUST NOT block
the update. Conflicting user edits in owned write paths remain protected.
Repeating update-workflow SHALL resume deferred updates without requiring refresh.
A separately requested refresh SHALL use the same migration owner while retaining
its ordinary configuration, database and verification behavior. Legacy execution
guard transition SHALL participate in this owner, not independently copy a partial
package or discard runtime/recovery state on every unchanged update.

#### Scenario: Active process or conflicting owned-file edit during migration
- **WHEN** a branch cannot safely receive the transition
- **THEN** it remains intact, is recorded as deferred with the exact continuation, and cannot be counted as migrated

#### Scenario: Only business files have uncommitted changes
- **WHEN** an idle worktree has unrelated configuration edits and update-workflow runs
- **THEN** workflow and client state update coherently while configuration bytes and unrelated index entries remain intact, with no master configuration merge, database mutation or test run

#### Scenario: Repeat after the active operation stops
- **WHEN** update-workflow is repeated after a deferred worktree becomes available
- **THEN** it updates that workflow without mandatory refresh or rerunning completed root migrations and reports any required client reload

### Requirement: IM3 One-time Caveman transition
The effective default SHALL become auto with full session level. Old on values
SHALL be converted once to auto in every inventoried managed scope; off and auto
are preserved. Persistent CAVEMAN_LEVEL and persist commands cease controlling
behavior. Existing evidence and user text are not silently destroyed. Session
overrides and exact helper userReport output SHALL remain intact.
Eligibility SHALL follow scope provenance/version. New projects and branches
from an already migrated baseline inherit the completed policy without converting
an intentional on again; old scopes receive a receipt even for a no-op value.

#### Scenario: User chooses on after migration
- **WHEN** a completed scope is updated again after an intentional on selection
- **THEN** on remains on and the one-time migration does not repeat

#### Scenario: Rollback and old worktree refresh
- **WHEN** a transition rolls back or a previously deferred worktree refreshes
- **THEN** settings and its migration receipt remain consistent, and migration occurs once for that scope

#### Scenario: New branch inherits intentional on
- **WHEN** a migrated master is intentionally set to on and a new worktree inherits it
- **THEN** the new worktree starts with the completed policy receipt and retains on through subsequent refresh

### Requirement: IM4 Optional post-install work respects host ownership
Upstream first-source-dump, installtools and installation-repair routes SHALL
recognize ITL-owned initialization and existing tool provisioning. No duplicate
export, automatic external installer or manual manifest repair is introduced.
Source-less projects and explicit refusal of optional export remain valid.

#### Scenario: Noninteractive ITL bootstrap already owns source acquisition
- **WHEN** rules installation finishes inside that bootstrap
- **THEN** no second independent source dump or contradictory chat prompt is emitted

### Requirement: IM5 Repeated updates preserve bytes and ownership
Plan, render, installed hashes and update/remove ownership SHALL use one artifact
representation for Markdown, frontmatter, nested documents and TOML agent bodies.
Repeated unchanged updates SHALL be byte-idempotent and preserve user/global data.

#### Scenario: Second unchanged update
- **WHEN** the same qualified package and selected clients are applied twice
- **THEN** the second update creates neither false userModified markers nor changed tracked files

### Requirement: IM6 New workflow continues stopped operations through their owner
A stopped pending or failed operation, including an unfinished Git merge, SHALL
be eligible for the ordinary workflow update. The new workflow SHALL support
continuation of previously supported recorded state or recovery by the existing
operation owner. No separate hotfix installer or user-selected recovery runtime
SHALL be required. File update MUST NOT automatically resume database/test actions.
The operation identity, pinned target, completed stages, merge/index state,
resolved conflicts and user changes SHALL survive. Known workflow-owned updates
SHALL be accounted for by the same update/lifecycle owner without weakening exact
Git-result checks, making accidental merge commits or resetting user work.
Recovery SHALL reconcile recorded state with observed owned effects, reuse proven
completed steps and restore only the necessary owned incomplete step for retry.
Unknown state SHALL retain evidence and give scoped continuation, not fabricate
success, repeat uncertain mutations or instruct manual JSON/lock manipulation.
The pinned business target SHALL be independent of the updated executing helper
and moving main worktree. Ignored managed rules SHALL be reconstructed from the
exact fork/client/render identity of the reconciled installed workflow state and
verified contributions: the original operation target unless a separate recorded
workflow update superseded its package state. That known transition MUST NOT be
silently downgraded by the old merge. Main is only a hash-verified cache. Missing
inputs SHALL retain exact retrieval continuation.

#### Scenario: Old helper defect prevents completing a merge
- **WHEN** all affected processes stopped after the old helper failed in an unfinished merge and update-workflow installs the new package
- **THEN** the original command continues using the new workflow or its existing recovery, preserving target, index, resolved conflicts and user work without requiring the broken step to finish before updating

#### Scenario: Stopped post-merge operation needs recovery
- **WHEN** direct continuation is impossible after an ordinary workflow update
- **THEN** repeating the original command reconciles the saved stage and observed effects through its owner, preserves completed work and provides recovery of the affected step without a second repair coordinator

#### Scenario: Main advances while refresh is paused
- **WHEN** refresh selected A, stopped, and main advanced to B before workflow update and resume
- **THEN** the new helper retains business target A, obtains ignored managed files by the reconciled workflow identity, preserves branch-local env/MCP, and does not silently switch that business target to B or downgrade the separately updated workflow package

#### Scenario: The interrupted merge includes a workflow-path conflict
- **WHEN** update encounters a conflict or later edit in its own workflow paths
- **THEN** the existing owner preserves before/current/candidate and unrelated merge stages for scoped reconciliation; it cannot clear the merge or include unrelated staging in an update commit
