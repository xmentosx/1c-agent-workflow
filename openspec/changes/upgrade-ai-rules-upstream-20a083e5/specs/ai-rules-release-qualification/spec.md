## ADDED Requirements

### Requirement: RQ1 Applicable upstream and downstream checks have one inventory
Qualification SHALL include preserved downstream regressions and applicable new
upstream installer, adapter, metadata, tool-policy, plugin and Python checks.
Source inputs, runtimes, exact fork and bundle identities SHALL enter reuse keys.
Tests are adapted only when an accepted contract changes, retaining the original
defect reproducer or equivalent proof. Omitted applicable checks remain unverified.

#### Scenario: Old downstream Full is green
- **WHEN** new upstream checks have not run
- **THEN** the old record cannot qualify the new release or be reused as complete proof

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
