## ADDED Requirements

### Requirement: PL1 Optional plugin delegates managed mutations to ITL
The controlled-fork plugin SHALL be an optional entrypoint into existing ITL
operations. In managed scope it MUST NOT directly run upstream init/add/update,
repair manifests, render MCP or launch infobase work outside the host owner.
Opening a folder alone does not authorize bootstrap or adding a client.

#### Scenario: Session hook sees an unconfigured client
- **WHEN** a plugin hook opens a managed project without that client installed
- **THEN** it reports the available attach action; an authorized attachment uses ITL and preserves existing clients

#### Scenario: Explicit bootstrap in a new project
- **WHEN** the user requests workflow initialization through the plugin
- **THEN** the existing bootstrap owns parameters, progress, completion and recovery

### Requirement: PL2 Plugin and project versions have separate lifecycles
The plugin SHALL resolve exact project-pinned sources and compatibility before
managed operations. Cached sources MUST be keyed/verified by repository and
immutable identity, not one reusable origin HEAD directory. Updating the plugin
MUST NOT implicitly upgrade project rules or globally change OpenSpec CLI.

#### Scenario: New plugin opens an old project
- **WHEN** its dispatcher encounters an older supported project version
- **THEN** it invokes that project's compatible operation or offers a named upgrade path without rewriting the project automatically

### Requirement: PL3 Failures and uninstall are explicit
Each supported plugin channel SHALL surface helper success, failure and recovery
without swallowing exit status. Disabling/uninstalling the plugin SHALL preserve
project rules, settings and bases; explicit project removal SHALL not be undone by
a later auto-ensure. Unsupported host hooks MUST NOT be advertised as automatic.

#### Scenario: Helper fails after a partial operation
- **WHEN** a hook or plugin command receives failure
- **THEN** it reports the owned recovery result and cannot hide it behind a successful plugin load

#### Scenario: Plugin is disabled
- **WHEN** the host disables the plugin
- **THEN** regular ITL project commands remain available and no project files or infobases are deleted
