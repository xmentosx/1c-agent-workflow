# Spec Delta

## Purpose

Keeps the on-demand MCP client command stable across facade and catalog
updates, so a running client is served by the facade the project currently
selects without a manual reconnect.

## ADDED Requirements

### Requirement: Client entries do not depend on the facade version

Every on-demand MCP client entry the workflow owns SHALL launch the relay with
arguments that identify the project and the server only. A facade, catalog,
hotfix or backend version change SHALL change only the project's launch
descriptor, never the client entry, and SHALL NOT be reported as a client MCP
configuration change.

#### Scenario: Facade update after the relay is in place
- **WHEN** `update-workflow` selects a new facade version for a project whose entries already use the relay
- **THEN** the client entries stay byte-identical and the update reports no client restart for MCP

#### Scenario: First switch to the relay
- **WHEN** `update-workflow` first writes relay entries over proven unchanged owned facade entries
- **THEN** the entries change once and the ordinary client-restart instruction is reported

#### Scenario: User-modified entry
- **WHEN** an owned on-demand entry differs from its last workflow write
- **THEN** the entry is preserved with the existing diagnostic and is not switched to the relay

### Requirement: The relay serves the described facade

The relay SHALL start the facade named by the launch descriptor only after its
SHA-256 matches the descriptor, and SHALL forward MCP messages in both
directions without changing them, except for the notes and notifications this
capability defines. It SHALL never download or install a facade.

#### Scenario: Normal start
- **WHEN** the client starts the relay and the described facade exists with the described SHA-256
- **THEN** the client's `initialize` reaches that facade and every later request, progress notification and cancellation is forwarded unchanged

#### Scenario: Paths with whitespace and Cyrillic
- **WHEN** the project root, helper and facade paths contain whitespace and Cyrillic characters
- **THEN** the facade receives exactly the described arguments

### Requirement: Facade replacement happens between requests

When the launch descriptor changed, the relay SHALL replace the facade before
forwarding the next client request and only while no request is in flight. It
SHALL close the old facade's input so that the facade performs its own owned
backend stop, start the new facade, replay the client's original `initialize`
and `notifications/initialized`, send `notifications/tools/list_changed` to the
client, and add a note to the first result that the facade was replaced and UI
state from earlier calls is gone. A request in flight SHALL never be
interrupted by a replacement.

#### Scenario: Pin changed while idle
- **WHEN** the descriptor names a new facade and the client sends a request with nothing in flight
- **THEN** the request is served by the new facade and its result carries the replacement note

#### Scenario: Pin changed during a long call
- **WHEN** the descriptor changes while a request is in flight
- **THEN** that request completes on the old facade and the replacement waits until no request is in flight

### Requirement: A missing or mismatched facade keeps the current one

If the descriptor names a facade that is absent or whose SHA-256 differs, the
relay SHALL keep serving through the current facade and SHALL add a note with
the continuation to repeat `update-workflow`. Without a current facade the
request SHALL fail with `ITL_ONDEMAND_RELAY_FACADE_UNAVAILABLE` and the same
continuation.

#### Scenario: Interrupted update
- **WHEN** the descriptor changed but the new executable was not installed
- **THEN** the call runs on the current facade and its result says to repeat `update-workflow`

### Requirement: Unexpected facade exit is restarted with a bound

If the facade exits on its own, a request that was in flight SHALL return a
tool error with `callOutcome: unknown` and `automaticRetryPerformed: false`.
The relay SHALL start the facade again on the next request, with the same
replay and note as a replacement, at most 3 times within 5 minutes; beyond the
bound it SHALL return `ITL_ONDEMAND_RELAY_RESTART_LIMIT` with a continuation.

#### Scenario: Facade crash
- **WHEN** the facade process exits while a request is in flight
- **THEN** that request reports an unknown outcome and the next request runs on a restarted facade

#### Scenario: Crash loop
- **WHEN** the facade exits a fourth time within 5 minutes
- **THEN** the next request fails with `ITL_ONDEMAND_RELAY_RESTART_LIMIT` and is not sent to a facade

### Requirement: Superseded-facade note names the relay continuation

A facade started with `ITL_ONDEMAND_RELAY=1` whose version differs from the
project pin SHALL tell the agent to repeat `update-workflow`; without the
variable it SHALL keep telling the agent to reconnect the MCP server.

#### Scenario: Facade under the relay is behind the pin
- **WHEN** the relay keeps an older facade because the new one is missing
- **THEN** the superseded note asks to repeat `update-workflow`, not to reconnect the client

### Requirement: Relay installation is part of the update step

The relay SHALL be acquired from the pinned release with SHA-256 verification
like the facade. If it cannot be installed, the step that writes client entries
SHALL fail with its existing recovery, and no direct facade entries SHALL be
written instead.

#### Scenario: Relay download fails
- **WHEN** the relay asset cannot be acquired during `update-workflow`
- **THEN** the step fails and the client entries remain as they were
