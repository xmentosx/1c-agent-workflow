## ADDED Requirements

### Requirement: OS0 Local planning home remains usable
The current release SHALL keep a local `openspec/` planning home for both new
and existing managed projects. Its pinned CLI and six supported phases SHALL
work without an external store. If the CLI selects a registered, declared or
global-default external store, the managed workflow SHALL report that this
release does not support that selection and stop the dependent OpenSpec action;
it MUST NOT create or use a local substitute or write to the external store.
Changing the selection is an explicit project/user choice, not an upgrade side
effect. External store support is specified separately in
`add-external-openspec-store`.

#### Scenario: External store is selected before the later feature release
- **WHEN** a managed OpenSpec phase resolves to an external store
- **THEN** it stops before writes and reports the selected root and local-only continuation

### Requirement: OS4 Compatible executable and intact bundles are separate
The integration SHALL resolve an exact compatible CLI executable without changing
global npm or PATH for old projects. Native/natural/unavailable bundle state,
executable compatibility and local planning-home accessibility SHALL be diagnosed independently.
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
style/report integrity and the local planning root. Source-only instructions MUST NOT be
copied into installed projects. Bundle refresh MUST reapply reviewed adaptations.

#### Scenario: Propose, update, sync and archive
- **WHEN** any supported phase acts on a local change
- **THEN** it uses CLI-resolved paths, preserves artifact substance and existing approved plans, and cannot claim archive readiness from checked task boxes alone
