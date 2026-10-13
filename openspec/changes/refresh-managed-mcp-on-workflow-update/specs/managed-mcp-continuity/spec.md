## Purpose

Maintain managed MCP configuration without losing user intent or treating an
optional remote capability as a prerequisite for unrelated project work.

## ADDED Requirements

### Requirement: Preserve user configuration during managed update

Workflow update SHALL add new published default MCPs and update proven unchanged
owned entries, preserving external entries, overrides, policy/auth, disablement,
and selected host/config/provider. Unproven legacy entries SHALL be preserved.

#### Scenario: SPPR appears and a transport override exists
- **WHEN** registry adds SPPR and an existing owned URL differs from its last write
- **THEN** SPPR is added and the override is preserved with a concrete diagnostic

#### Scenario: Registry is unavailable
- **WHEN** registry refresh fails during update
- **THEN** existing connections are retained and freshness is not claimed

### Requirement: Selection completeness is independent of service readiness

A unique valid remote selection SHALL remain complete during temporary
unavailability. Init SHALL continue its normal path with truthful unavailable
capability reporting. Missing parameters and ambiguous endpoints SHALL remain
selection errors. Dependent verification SHALL NOT pass without its evidence.

#### Scenario: The only codechecker is temporarily unavailable
- **WHEN** its published URL exists but status is unreachable or unknown
- **THEN** init passes MCP selection, retains the choice and reports unavailable readiness

#### Scenario: Host is ambiguous
- **WHEN** several matching endpoints exist without a host choice
- **THEN** selection remains incomplete regardless of their current health

### Requirement: Identity and optional functional health are separate proofs

The host SHALL retain matched identity when a safe tool fails, report the
functional failure separately and SHALL NOT authorize restart from that failure.
Wrong identity SHALL NOT become matched or ready.

#### Scenario: fetch_its times out
- **WHEN** internal and two public identities match but fetch_its times out
- **THEN** identity is matched, health is failed with method/budget diagnostics,
  and publication does not misreport the entire MCP as unknown

#### Scenario: SSE heartbeats do not complete a call
- **WHEN** heartbeats arrive without the matching response
- **THEN** the request terminates within its elapsed budget and reports failure

### Requirement: Bounded recovery precedes stale-address fallback

On transport/init/discovery failure the agent SHALL perform one immediate registry
refresh and same-selection owner sync before fallback, then supported reconnect
and discovery. Repeats SHALL occur only on actual demand and at least 60 seconds
apart unless new ready/config evidence permits an immediate retry. Successful calls SHALL NOT trigger registry refresh. Business errors,
explicit disablement and uncertain mutations SHALL NOT trigger blind replay.

#### Scenario: Published URL changes
- **WHEN** a managed old URL fails and registry publishes its replacement
- **THEN** recovery updates only the proven unchanged owned URL and retries
  discovery or reports reload-required if no current-client control channel exists

### Requirement: Operation-local registry snapshot
The workflow SHALL refresh at most once and use the same registry snapshot across
all remote selection, upstream reconciliation and final MCP writes within one
init or update post-copy invocation. The snapshot SHALL be discarded on exit.
A failed refresh SHALL preserve existing remote configuration; cached data SHALL
NOT prove freshness or dependent verification success.

#### Scenario: Registry publication changes during update
- **WHEN** publication changes after the operation captures its snapshot
- **THEN** all MCP reads in that operation use the captured publication
- **AND** a subsequent operation may capture the newer publication

#### Scenario: Header trickle or slow cleanup
- **WHEN** an endpoint continually emits incomplete HTTP headers or delays DELETE
- **THEN** request and cleanup terminate within their respective elapsed budgets
- **AND** optional health failure retains independently verified identity

### Requirement: Terminal cleanup preserves completed operation evidence
The compact runner SHALL use its existing bounded terminal cleanup grace after
a terminal result is published, capped by the global maximum deadline. It SHALL
NOT replace a completed result merely because the action deadline expires during
that grace. Nonterminal action and stale-heartbeat deadlines SHALL remain in force.

#### Scenario: Terminal helper exits after the action deadline
- **WHEN** the helper publishes success and exits within its cleanup grace
- **THEN** the runner retains success and observes the actual process exit

#### Scenario: Terminal helper never exits
- **WHEN** the helper remains alive beyond its cleanup grace
- **THEN** the runner stops only its owned process tree and reports cleanup timeout
