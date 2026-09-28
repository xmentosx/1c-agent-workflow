## ADDED Requirements

### Requirement: SM1 Exact intake and complete semantic accounting
The migration SHALL use the exact old upstream, r36 fork and target upstream
commits recorded in proposal.md. Every prior downstream invariant, including
sub-IDs inside a path group, and every changed input path MUST have an explicit
preserve, adapt or retire decision, target owner and behavioral acceptance.
The planning inventory SHALL NOT be treated as a qualified release ledger.

#### Scenario: New upstream path bypasses an old adaptation
- **WHEN** a new operation skill implements a rule previously adapted only in AGENTS.md
- **THEN** its caller relationship and the same effective invariant are included in the migration map and acceptance

#### Scenario: Intake moves
- **WHEN** the remote intake differs from the audited target before reconstruction
- **THEN** reconstruction stops for an incremental audit rather than silently changing the target

### Requirement: SM2 Upstream root with routed ITL additions
Installed projects SHALL use the new upstream root structure. ITL additions MUST
retain their trigger, required action, exceptions, precedence and failure result
at one authoritative owner. Mandatory compact lifecycle ownership remains loaded;
situational detail stays on demand. Source-repository AGENTS.md MUST NOT enter
managed project copies. User-authored text SHALL be preserved and conflicting
effective overrides reported with the affected behavior, without automatic deletion.

#### Scenario: Preserved override contradicts migrated rules
- **WHEN** user text still demands persistent Caveman levels or an obsolete verification route
- **THEN** the text is retained, the effective conflict is identified, and only dependent work waits for resolution

### Requirement: SM3 Planning selection and full-cycle review remain distinct
Execution path and planning mode SHALL remain independent of verification depth,
UI mode and orchestration. Full-cycle SHALL receive parent review unless explicitly
waived; a separate reviewer requires explicit request and actual model selection.
Error-fixer SHALL use coding tier with bounded defect-class search and one writing
owner; broader work is routed to the parent without automatic scope expansion.

#### Scenario: Full-cycle without a reviewer model
- **WHEN** a direct or OpenSpec full-cycle task has no usable explicit reviewer model
- **THEN** the parent reviews requirements, correctness, regressions and security, with MCP gates still applied

#### Scenario: Planning was already authorized together with implementation
- **WHEN** the user explicitly authorized planning followed by implementation
- **THEN** the planning skill preserves that authorization within its scope; a planning-only request still stops after artifacts

### Requirement: SM4 Managed lifecycle and repository ownership
ITL SHALL own operations against managed infobases, repository synchronization,
bootstrap, MCP and recovery. Repository settings for the source infobase MUST NOT
be interpreted as a binding of a detached development copy. New repository,
database, web, source-dump and repair entrypoints MUST dispatch to their ITL owner
or return an actionable managed-scope refusal before mutation.

#### Scenario: Repository-backed source with a detached branch copy
- **WHEN** REPOSITORY_PATH is set for the source and work edits the branch copy
- **THEN** no upstream lock-edit-commit cycle binds the branch copy; ITL source locks and synchronization retain their exact source target

#### Scenario: Direct tool is invoked in a managed project
- **WHEN** a bundled PowerShell or Python tool would mutate a managed base, publication or repository
- **THEN** it cannot bypass the per-infobase guard or host recovery, and reports the supported continuation

### Requirement: SM5 Preserve metadata repairs and new upstream checks
Migration SHALL retain exact UUID delta semantics, GeneratedType handling,
Form/Template/IntegrationService descriptor support, managed-form context,
explicit false row flags, advisory empty Action, and compatible descriptor
completion with UUID/payload preservation. New upstream structural, module,
version and DynamicList checks MUST remain effective. Specialized metadata tools
remain the normal route for supported operations.

#### Scenario: Compatible descriptor already exists
- **WHEN** form/template creation completes an existing descriptor with matching identity and type
- **THEN** its UUID and existing template payload survive; incompatible descriptors are rejected without partial mutation

#### Scenario: Empty Action with an unrelated structural error
- **WHEN** a form has both an empty Action and a real structural violation
- **THEN** Action remains advisory without dummy handlers while the structural violation still fails

### Requirement: SM6 Preview preserves the requested boundary
A requested preview SHALL not become an apply when preview is unavailable.
Temporary writes and rollback MUST preserve unrelated dirty files and concurrent
changes. File preview SHALL not be represented as infobase rollback or runtime proof.

#### Scenario: Dirty target or rollback failure
- **WHEN** safe preview cannot preserve the target state
- **THEN** the operation returns a bounded explanation and continuation, never a silent apply or broad checkout/clean of unrelated work

### Requirement: SM7 Evidence sources and memory boundaries
MCP standards routing SHALL be qualified with the actual required capabilities.
ITL-specific architectural facts MUST remain available locally rather than be
assumed to exist in an external standards corpus. Branch delta is read from the
worktree; unchanged baseline discovery uses bounded MCP-first routing. Project
facts MUST NOT be written into shared cross-project memory by default.

#### Scenario: Current branch differs from indexed baseline
- **WHEN** relevant local BSL changes are absent from the index
- **THEN** the agent inspects the exact branch delta and uses baseline MCP evidence without replacing current code with stale indexed content

#### Scenario: Required standards tool is unavailable
- **WHEN** a dependent task needs the required standards capability
- **THEN** the task reports the missing capability and continuation while unrelated work proceeds; presence of an endpoint alone is not success
