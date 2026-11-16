## ADDED Requirements

### Requirement: User selects discovery and formal planning

The source-development agent MUST investigate available facts before asking the user about intent. If materially different interpretations remain, the cause is unproven, new state/recovery complexity is unjustified, or no concrete acceptance scenario can be stated, it MUST explain the uncertainty and offer grill and/or OpenSpec. It MUST wait for the user's selection before activating that process, preserve a prior selection, and keep the direct route available for clear bounded work.

#### Scenario: Uncertain update change
- **WHEN** an update fix is proposed without evidence of its cause
- **THEN** the agent investigates the available code and evidence, identifies remaining uncertainty, and offers an appropriate discovery/planning route instead of silently choosing an implementation

#### Scenario: Clear bounded correction
- **WHEN** the defect, desired behavior, scope and acceptance are clear and the user has not selected grill or OpenSpec
- **THEN** the agent can use the normal source-development route without creating a specification or imposing an interview

#### Scenario: Previously selected route
- **WHEN** the user has selected OpenSpec or grill in the current task
- **THEN** the agent continues within that authorization without asking the same process-selection question again

### Requirement: Planning exposes sufficiency and maintenance cost

A selected formal proposal MUST describe the concrete problem and user scenario; required behavior and scope; the simplest sufficient solution and a considered alternative with rationale; newly introduced maintenance obligations; and acceptance evidence with its limitations. Existing architecture and verification contracts MUST be referenced rather than redefined. Implementation MUST NOT begin with unresolved user decisions that materially affect behavior, responsibility, compatibility or acceptance.

#### Scenario: Additional recovery mechanism
- **WHEN** a proposed fix introduces persistent state or another recovery mechanism
- **THEN** its design explains the proven need, owner, simpler alternative, maintenance cost and acceptance, and applies the existing architecture checkpoint rules

#### Scenario: Verification establishes only a component result
- **WHEN** available tests prove an internal step but not the required user result
- **THEN** the proposal identifies the missing evidence and does not describe component success as complete acceptance

### Requirement: Grill handoff has one requirements destination

When the user selects OpenSpec after grill, the agent MUST transfer settled decisions, facts and unresolved questions into the change artifacts without restarting the same interview. Requirements, design and implementation tasks MUST remain in OpenSpec. Glossary and ADR documents MUST be created only for resolved domain terms or qualifying architectural decisions, without duplicating specifications. A new material conflict discovered during implementation MUST be surfaced before dependent work proceeds.

#### Scenario: Interview decisions are reused
- **WHEN** the user confirms a grill handoff and chooses OpenSpec
- **THEN** the proposal preserves the confirmed goal, scope, decisions and evidence and asks only genuinely unresolved questions

#### Scenario: No qualifying glossary or ADR content
- **WHEN** discovery resolves no new domain terms or decisions requiring an ADR
- **THEN** no empty glossary, ADR or parallel requirements document is created

### Requirement: Codex tools are reproducible and local to the source checkout

The source checkout MUST expose grill-me, grill-with-docs and their required skill dependencies, plus generic OpenSpec explore/propose/apply/archive skills, to Codex. Their provenance and prerequisites MUST be recorded. This setup MUST preserve explicit user selection and MUST NOT write personal Codex configuration, import the installed-project 1C instruction bundle, or require the original author's local fork checkout.

#### Scenario: Fresh Codex context
- **WHEN** a fresh Codex context opens the prepared source checkout
- **THEN** the documented skill entrypoints are discoverable and resolve their required local resources

#### Scenario: OpenSpec CLI is absent
- **WHEN** the user selects OpenSpec and its required CLI is unavailable
- **THEN** the agent reports the missing prerequisite, preserves existing artifacts, and does not claim validation or silently install tooling; grill remains independently usable

### Requirement: Source planning preserves installation and delivery boundaries

Source-only planning assets MUST NOT enter installed-project managed-copy or overwrite installed skills owned by controlled ai_rules_1c. The process MUST follow existing source architecture, verification, commit/registration and publication rules. OpenSpec artifact completion MUST NOT imply implementation, runtime acceptance or publication.

#### Scenario: Workflow package update
- **WHEN** bootstrap or update-workflow resolves managed source-package files
- **THEN** the new maintainer-only skills, OpenSpec workspace and source-planning documentation are excluded, while existing installed-project skill ownership remains intact

#### Scenario: Proposal is valid
- **WHEN** all proposal artifacts pass OpenSpec validation but the implementation tasks have not run
- **THEN** the reported result is a validated proposal, with implementation and acceptance still pending

### Requirement: Pilot acceptance distinguishes observed and inferred evidence

The pilot MUST record the outcomes of source routing and skill behavior checks, a fresh Codex discovery check, and a retrospective analysis of one known update incident. Each result MUST distinguish static inspection, observed behavior, retrospective reasoning and unverified evidence. Executable verification gaps discovered by the retrospective MUST be scoped as separate follow-up work rather than silently expanding this change.

#### Scenario: Historical blocked migration
- **WHEN** the pilot analyzes an update that could report success after a managed rules migration was blocked
- **THEN** its acceptance account requires correct top-level outcome and preservation of genuine user changes, names the evidence boundary, and does not claim that a new live update was tested

#### Scenario: Fresh context check unavailable
- **WHEN** skill files validate but fresh-context discovery or behavior was not observed
- **THEN** that acceptance item remains unverified and the pilot is not reported as fully accepted
