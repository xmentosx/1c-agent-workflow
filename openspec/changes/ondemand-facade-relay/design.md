# Design

## Context

See proposal.md for motivation and specs/ondemand-facade-relay/spec.md for the
required behaviour. Current state that shapes the approach:

- `Get-ItlOnDemandMcpEndpointDescriptors` (`agent-1c.ondemand-mcp.ps1`) builds
  one stdio endpoint per family and auxiliary contour: the versioned facade
  executable plus `serve --family … --project-root … --catalog … --helper …
  --surface gateway --idle-timeout 10m`. All client adapters (Claude, Codex,
  Kilo and others) consume these descriptors through
  `Write-ItlClientMcpEndpointSet`.
- Facade and catalog resolution is PowerShell-owned and not a plain read of
  `compatibility.json`: hotfix selections can replace the facade contract and
  the catalog (`Get-WorkflowHotfixCatalog`), and `ITL_ONDEMAND_MCP_EXE` is an
  explicit SHA-checked override (`Get-ItlOnDemandMcpExecutablePath`).
- The facade already stops its owned backend when its stdin closes:
  `server.Run` returns and `rt.close` runs the bounded owned cleanup
  (`main.go`). Guard ownership stays inside the facade.
- Facade 0.4.34 reports `ITL_ONDEMAND_FACADE_SUPERSEDED` by comparing its
  version with `compatibility.json`.
- Owned client entries are updated only when unchanged since the last write
  (`managed-mcp-continuity`).

## Goals / Non-Goals

**Goals:**
- One authoritative owner of facade selection (the PowerShell workflow); the
  relay is a mechanical launcher and forwarder.
- No new shared state, lock or coordinator: the relay owns only its child
  process; backends, guards and recovery stay with the facade.

**Non-Goals:**
- Hot replacement of the relay itself: a relay release changes the client
  entry and needs a reconnect, accepted as rare.
- Preserving UI state across a facade replacement.
- Changing the facade's tool surface or catalogs.

## Decisions

### D1. Launch descriptor written by the workflow, read by the relay
The workflow writes `.agent-1c/mcp/ondemand/launch/<server-name>.json`
(atomic UTF-8 write) wherever it writes client endpoints: `schemaVersion`,
`facadePath`, `facadeSha256`, `facadeVersion`, `args` (the exact `serve …`
arguments today in the client entry), `writtenAt`. The client entry becomes
`<relay.exe> --project-root <root> --server <server-name>`.
- Alternative: the relay reads `compatibility.json` and `dependency-lock.json`
  itself. Rejected: it would duplicate hotfix, override and catalog policy in
  Go, giving one invariant two owners.
- The descriptor is ignored runtime state in the project (like registrations
  and evidence), so `update-workflow` across worktrees updates each one.

### D2. Separate binary in the facade's Go module
`tools/itl-ondemand-mcp/cmd/itl-ondemand-relay` with its own version constant,
build output and release tag `itl-ondemand-relay-v<version>`. It reuses
`internal/childprocess` (hidden-window child start, UTF-8 safe arguments).
This refines grill Q4 (`tools/itl-ondemand-relay`): same separate binary and
release, but inside the existing module to reuse the child-process helper
instead of copying it. Installed path:
`%LOCALAPPDATA%\ITL\MCP\relay\v1\<sha>\itl-ondemand-relay-windows-amd64.exe`
(the version segment changes only on an incompatible relay change; the SHA
segment changes on any relay release, which is the accepted rare reconnect).

### D3. Line-level forwarding with minimal protocol knowledge
MCP stdio messages are newline-delimited JSON-RPC. The relay parses each line
only to read `id`, `method` and whether it is a request, response or
notification; it forwards the original bytes. It tracks in-flight client
requests (ids awaiting a response) and keeps the first `initialize` request
and the client's `notifications/initialized`. It modifies exactly three
things: the `initialize` result it forwards gets `capabilities.tools.
listChanged = true`; a replacement/restart note is appended as an extra text
content item to the first `tools/call` result after a swap; relay errors are
returned as tool errors in the facade's `toolError` shape.
- Alternative: a full MCP SDK client+server pair. Rejected: it would
  re-encode every message and couple the relay to SDK and protocol revisions,
  so the relay would change as often as the facade.

### D4. Replacement trigger and sequence
Before forwarding each client request, the relay compares the descriptor's
content hash with the one it started from (one small file read). If changed
and nothing is in flight: verify the new SHA (absent/mismatch → keep current,
note per spec), close the old child's stdin, wait for exit within the
facade's cleanup budget plus margin (the facade's `--cleanup-timeout`, default
1 minute, + 30 s), kill only on timeout, start the new child, replay
`initialize` with a relay-owned id and the client's original params, send
`notifications/initialized`, emit `notifications/tools/list_changed`, then
forward the waiting request. A new child that fails to start or initialize
within 20 s (the configured startup timeout) is reported as
`ITL_ONDEMAND_RELAY_FACADE_UNAVAILABLE` for that request; the next request
tries again.

### D5. Unexpected exit and the restart bound
A child exit not caused by the relay fails all in-flight requests with a tool
error (`callOutcome: unknown`, `automaticRetryPerformed: false`) and marks the
child absent. The next request restarts it through the D4 start sequence and
note. Restart timestamps are kept in memory; a fourth unexpected exit within
5 minutes makes requests fail with `ITL_ONDEMAND_RELAY_RESTART_LIMIT` until the
window passes or the descriptor changes.

### D6. Facade continuation under the relay
The relay sets `ITL_ONDEMAND_RELAY=1` in the child environment. The facade's
`facadeSupersededNote` keeps its code and facts and switches only the
continuation text. Older facades ignore the variable, so the contract is
one-way and optional.

### D7. Evidence
The relay appends JSONL records (`relay-started`, `facade-started`,
`facade-replaced`, `facade-kept`, `facade-exited`, `restart-limit`) to
`.agent-1c/mcp/ondemand/<family>/relay-<server-name>.jsonl`, next to the
facade's own evidence, with versions, SHAs and child PIDs; never message
payloads.

### D8. Acquisition and lock
`templates/dependency-lock.json` gains `itlOndemandRelay` (version,
releaseTag, assetName, url, sha256) acquired by the existing immutable
acquire path. Failure fails the step (grill Q7). The facade's existing hotfix
and override rules are untouched; the relay has no override variable.

## Risks / Trade-offs

- [The replacement drops live TestClient forms or a ROCTUP session] → Only
  between requests, with an explicit note; same loss as today's reconnect.
- [A client that ignores `tools/list_changed`] → The gateway surface is stable
  across facade versions, so a stale tool list still works; the notification
  only helps clients that cache full catalogs.
- [Relay bug blocks all on-demand MCP] → Small surface, Go tests for every
  spec scenario; rollback to the previous workflow rewrites direct entries.
- [Descriptor and client entry disagree after a partial update] → The relay
  trusts only the descriptor plus SHA; a missing executable keeps the current
  facade (spec) and the next `update-workflow` repairs it.
- [Two relays of different projects] → Each relay reads its own project's
  descriptor; no shared state.

## Migration Plan

1. Stage A (no pin): the relay source, its build next to the facade, the
   publisher's finalizer support for `dependencies.itlOndemandRelay`, and the
   workflow integration that activates only when the lock pins the relay. The
   published supervisor refuses a candidate lock with an owned asset it cannot
   finalize, so the pin cannot ship in the same publication (refines grill
   Q10: one change, two publications).
2. Stage B, after stage A is published on the user's request: pin
   `itlOndemandRelay`, route the relay source build through the E2E stands,
   release relay and facade (docs/source-publication.md).
3. `update-workflow` installs the relay, writes descriptors and switches
   proven unchanged owned entries; clients restart once.
4. Rollback: an older workflow rewrites its direct facade entries (they are
   owned and unchanged since the relay write); descriptors and the relay cache
   stay unused.

## Architecture checkpoint

Invariant: the client command is independent of the facade selection; the
project's selection has one owner (PowerShell workflow). Affected: on-demand
MCP client entries for all clients and contours, `update-workflow` acquisition,
facade continuation text. Unaffected: hosted MCP, agent-browser, broker,
execution guard, backend recovery, facade tool surface. One state machine (the
relay's child lifecycle), no shadow coordinator; bounded waits (20 s start,
cleanup budget + 30 s stop, 3 restarts / 5 min). Approved through grill
decisions Q1–Q11 on 2026-11-20.
