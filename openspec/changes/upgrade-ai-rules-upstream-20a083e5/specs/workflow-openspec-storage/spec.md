## ADDED Requirements

### Requirement: OS1 Explicit and stable planning home
OpenSpec CLI SHALL resolve explicit store, project binding and user global default
using its own precedence. With no external selection, local storage SHALL remain
the default for new and existing projects. The resolved root and change SHALL be
retained for the task; selection changes do not move documents automatically.

#### Scenario: Unreachable or malformed selected store
- **WHEN** resolution fails for a declared external store
- **THEN** no local substitute is initialized and the diagnostic distinguishes missing CLI, invalid binding and unreachable storage

### Requirement: OS2 External documents are independent of branch lifecycle
Refresh, reset, close, update and migration rollback SHALL not delete, revert or
archive external planning documents. The task SHALL retain its change/root binding
and observed revision; subsequent work reconciles current requirements with code.

#### Scenario: Rollback after another task edits the external store
- **WHEN** installed-project migration rolls back its local snapshot
- **THEN** the external edit survives and only owned project instructions/binding are restored

### Requirement: OS3 Shared spec writes detect concurrent changes
Writes SHALL validate physical store identity, intended paths and the read
revisions under the store-write operation owner. Different changes writing the
same main spec are conflicting writers. No broad git reset or store rollback is
permitted. Conflict preserves both current content and the candidate contribution.
Read dependencies and change-tree membership SHALL remain protected during the
apply window; archive MUST verify the revision that was successfully synced.
Process death SHALL release the lock lease without manual lock-file deletion.

#### Scenario: Two changes update one capability
- **WHEN** one writer commits after the other read the main spec
- **THEN** the second detects drift before replacement, re-reads and reconciles instead of overwriting the first contribution

#### Scenario: Store alias is retargeted mid-task
- **WHEN** the alias resolves to a different physical root before writing
- **THEN** the write stops with both locations reported rather than silently redirecting the task

#### Scenario: Writer crashes after the first replacement
- **WHEN** the writer process dies partway through its batch
- **THEN** a subsequent operation acquires the released lease and recovers its own journal without deleting a live owner's lock or reverting another writer's changes

#### Scenario: Delta changes before archive
- **WHEN** a delta or change-tree input changes after sync preparation or before archive
- **THEN** revision mismatch stops the stale operation and preserves the changed active delta for reconciliation rather than archiving it using earlier sync evidence

### Requirement: OS4 Compatible executable and intact bundles are separate
The integration SHALL resolve an exact compatible CLI executable without changing
global npm or PATH for old projects. Native/natural/unavailable bundle state,
executable compatibility and store accessibility SHALL be diagnosed independently.
Native applies only to an intact managed bundle; natural is intentional absence.
The resolved executable identity SHALL include the absolute Node executable and
OpenSpec JS entrypoint; changing PATH MUST NOT silently replace that runtime pair.

#### Scenario: Old and upgraded projects coexist
- **WHEN** both invoke their planning workflows on the same machine
- **THEN** each uses its pinned compatible CLI/bundle; rollback of one cannot replace the other's executable

#### Scenario: Broken native bundle
- **WHEN** a required managed skill is missing or modified
- **THEN** integration reports unavailable with recovery rather than downgrading silently to natural

#### Scenario: PATH changes after executable resolution
- **WHEN** another Node version becomes first in PATH
- **THEN** the operation retains the qualified absolute pair; replacing either selected executable requires renewed compatibility evidence

### Requirement: OS5 Source pilot and every phase honor accepted policy
Installed native phases, natural flows and the source-only pilot SHALL preserve
planning choice, accepted authorization, required context sources, current proof,
style/report integrity and store selection. Source-only instructions MUST NOT be
copied into installed projects. Bundle refresh MUST reapply reviewed adaptations.

#### Scenario: Propose, update, sync and archive
- **WHEN** any supported phase acts on an external change
- **THEN** it uses resolved paths, preserves artifact substance and existing approved plans, and cannot claim archive readiness from checked task boxes alone
