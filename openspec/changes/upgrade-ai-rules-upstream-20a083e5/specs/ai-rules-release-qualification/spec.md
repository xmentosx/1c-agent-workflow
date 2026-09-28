## ADDED Requirements

### Requirement: RQ1 Applicable upstream and downstream checks have one inventory
Qualification SHALL include preserved downstream regressions and applicable new
upstream installer, adapter, metadata, tool-policy, plugin and Python checks.
Source inputs, runtimes, exact fork and bundle identities SHALL enter reuse keys.
Tests are adapted only when an accepted contract changes, retaining the original
defect reproducer or equivalent proof. Omitted applicable checks remain unverified.
The primary installed-upgrade acceptance SHALL start from the actual published
workflow master package, including its old helper, rules, dependencies and state;
changing only a rules tag in the new helper is insufficient. The reviewed baseline
is workflow 69c0863bfe3bd837543267f122e81a28dcfa5488 with rules
itl-main-410951e7-r33 at 9309bfbbc9f8d844a21bce55178c2e0d72eaf965.
Before qualification the remote master SHALL be rechecked; a newer published
baseline requires the corresponding additional transition evidence. r36 projects
and representative previously supported legacy upstream/controlled-fork manifest
classes SHALL remain covered without requiring every historic tag or intermediate
r36 installation. Rollback, delegated MCP and user/global ownership remain part
of those upgrade contracts.

#### Scenario: Old downstream Full is green
- **WHEN** new upstream checks have not run
- **THEN** the old record cannot qualify the new release or be reused as complete proof

#### Scenario: Upgrade from the published workflow master
- **WHEN** a project installed by the actual published baseline upgrades with idle, busy and stopped-pending worktrees
- **THEN** its old helper hands off to a coherent new package, deferred roots remain explicit, and original commands resume/recover without business merge, database changes or tests being hidden inside file update

#### Scenario: Older supported manifest owns global client paths
- **WHEN** a representative legacy upstream or controlled-fork installation upgrades directly
- **THEN** the new owner preserves user/global content, delegated MCP and rollback without assuming r36 already normalized the manifest

### Requirement: RQ2 Qualification distinguishes static and live capabilities
Qualification SHALL distinguish file placement, CLI/schema validation, client
discovery, real MCP operation and live 1C acceptance as separate evidence states. Rendered agent evals SHALL
not count as executed evals. Every client has explicit passed/failed/unverified
capabilities and runtime variants. Fixtures cannot stand in for live claims.

#### Scenario: Plugin manifest parses but hook has not run
- **WHEN** only static package checks pass
- **THEN** plugin host activation remains unverified in the release report

### Requirement: RQ3 Existing delivery authority remains authoritative
The new immutable fork release SHALL be reconstructed from the audited upstream,
with reviewed schema-3 path hashes and pending compatibility. Existing
PublishDevelop owns qualification, promotion and component finalization; ordinary
commits use RegisterChange. No direct push, tag repointing or implied master release
is introduced. Windows 10/11/Server 2019+ and standard-user operation remain.
The fork finalizer SHALL preserve the atomic fast-forward of its origin/main to
the audited upstream together with immutable component branch/tag publication.

#### Scenario: Missing owned qualification evidence
- **WHEN** a candidate needs an applicable release capability
- **THEN** the existing delivery planner selects it and retains truthful unverified status for unavailable evidence under the established publication policy

### Requirement: RQ4 Planning completion is not migration completion
This change SHALL distinguish complete planning artifacts from executed tasks,
registered source changes, qualified releases, publication and installed acceptance.
All implementation tasks remain unchecked until their evidence exists. No separate
mandatory test-plan.md is needed; scenarios and task-linked evidence define acceptance.

#### Scenario: OpenSpec reports all artifacts complete
- **WHEN** proposal, design, specs and tasks exist and validate
- **THEN** the change is ready for implementation review, not implemented, installed or eligible for archive
