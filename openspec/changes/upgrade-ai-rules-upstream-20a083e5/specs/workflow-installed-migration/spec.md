## ADDED Requirements

### Requirement: IM1 Transactional managed transition
Managed transition SHALL extend existing eligibility, exact source checks,
pre-write plan, dirty-state protection and snapshot recovery to all selected clients and changed
settings. Genuine userModified files and custom source repositories SHALL remain
protected. Byte-identical/strict UTF-8 EOL-only stale markers may be cleared only
under the existing ownership proof.
Rollback SHALL compare the expected post-state of owned files/config entries,
including ignored settings and ownership manifests. Later user changes MUST be
preserved with scoped reconciliation instead of replacement by an old snapshot.

#### Scenario: Failure after rendering several clients
- **WHEN** any postcondition fails during installation
- **THEN** the owned project snapshot is restored including client membership, manifest, dotenv and MCP, with a usable recovery report

#### Scenario: User changes settings after a successful migration
- **WHEN** rollback finds later dotenv, MCP credentials or ownership changes
- **THEN** it preserves those current values and the recovery candidate, reports the exact conflicting scope and does not blindly restore the older snapshot

### Requirement: IM2 Existing projects and worktrees have explicit coverage
The migration SHALL inventory known managed project roots and their active
worktrees, record completed/deferred/blocked outcomes per scope, and preserve
unrelated dirty work. Master rule upgrades SHALL not silently advance active
branches. Normal refresh performs the branch transition using the same semantics.
User-named additional roots join the inventory without a broad disk scan.

#### Scenario: Busy or dirty branch during migration
- **WHEN** a branch cannot safely receive the transition
- **THEN** it remains intact, is recorded as deferred with the exact continuation, and cannot be counted as migrated

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
