# Proposal

## Why

Every on-demand facade or catalog change rewrites the `itl-roctup-data` and
`itl-vanessa-ui` client entries, because `Get-ItlOnDemandMcpEndpointDescriptors`
puts the versioned executable path
(`%LOCALAPPDATA%\ITL\MCP\ondemand\<version>\<sha>\…exe`) and the versioned
catalog path into the command. The pin changed 22 times between 2026-11-01 and
2026-11-20 (`compatibility.json` history). After each `update-workflow` the
client keeps the old facade process until a person reconnects it: `/mcp` in
Claude Code, a full Codex restart, or `/reload` in Kilo. Facade 0.4.34 (B3)
only tells the agent that its process is superseded; the agent cannot reconnect
itself. PM5 agents hit this repeatedly (review `itl-defect-notes-review-20261119`,
item 1b).

The design was settled in a grill session on 2026-11-20 (decisions Q1–Q11 in
`build/agent-artifacts/itl-defect-notes-review-20261119/fix-plan.md`).

## What Changes

- A new, rarely changing stdio relay executable (`itl-ondemand-relay`) becomes
  the command of every on-demand MCP client entry (both families, main and
  auxiliary contours, all clients that receive these entries).
- The workflow writes one resolved launch descriptor per on-demand server
  (facade path, SHA-256, version, full facade arguments) whenever it writes
  client MCP entries. The relay reads only that descriptor; facade, hotfix and
  catalog resolution stay with the PowerShell owner.
- The relay starts the pinned facade as a child, forwards MCP traffic unchanged
  and, before the next client request while no request is in flight, replaces
  the child when the descriptor changed. The replacement replays the client's
  `initialize`, reports `tools/list_changed`, and marks the first result as
  served by a new facade whose UI state was lost.
- When the described facade is missing or its SHA differs, the relay keeps the
  current facade and adds a note to repeat `update-workflow`; it never
  downloads.
- When the facade exits unexpectedly, the relay restarts it on the next request
  (at most 3 restarts in 5 minutes); the interrupted request returns
  `callOutcome: unknown` and is never replayed.
- The relay passes `ITL_ONDEMAND_RELAY=1` to the facade; the facade's
  `ITL_ONDEMAND_FACADE_SUPERSEDED` note then says to repeat `update-workflow`
  instead of reconnecting the client.
- A new `itlOndemandRelay` dependency-lock entry and component release; relay
  installation failure fails the `update-workflow` step (one configuration
  mode). The first switch to the relay changes the client entries once and
  needs one ordinary client restart.

## Capabilities

### New Capabilities
- `ondemand-facade-relay`: stable client command for on-demand MCP servers that
  serves the facade selected by the project without a client reconnect, with
  bounded replacement, restart and failure behaviour.

### Modified Capabilities
- (none) Client entry ownership and preservation of user overrides follow the
  existing `managed-mcp-continuity` requirement unchanged.

## Impact

- New Go command under `tools/itl-ondemand-mcp/cmd/itl-ondemand-relay`, its
  build in `scripts/Build-ItlOnDemandMcp.ps1`, component release
  `itl-ondemand-relay-v<version>`.
- `agent-1c.ondemand-mcp.ps1`: relay acquisition, launch descriptors, endpoint
  descriptors pointing at the relay.
- `templates/dependency-lock.json`, `compatibility.json` (no schema change),
  dependency-lock tests, client MCP config tests.
- Facade: `ITL_ONDEMAND_RELAY` continuation wording only (`facade_notes.go`).
- Unaffected: hosted vibecoding1c HTTP MCPs, agent-browser, the facade's tool
  surface, execution guard and broker ownership of backends.
- Architecture checkpoint (docs/package-architecture.md): new long-lived
  component and installed client-config migration; approved through the grill
  decisions, stated in design.md.
