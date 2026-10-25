# MCP Reference

Use this reference for ROCTUP branch data MCP, vibecoding1c MCP, branch-local Vanessa UI MCP, External MCP preservation, and legacy branch Data MCP. Do not load it for ordinary lifecycle commands unless MCP is part of the request or helper failure.

Optional explicitly qualified Cognee memory uses the same client owner; load only [scoped-memory.md](scoped-memory.md) for its opt-in, pending/status or recovery. Project association alone never enables it.

## Families And Ownership

- ROCTUP MCP Toolkit is the preferred branch-local data channel for `itldev/*` infobases and does not require web publication.
- vibecoding1c MCP is managed by ITL helper actions and natural-language requests.
- Vanessa UI MCP is separate branch-local runtime tooling for user-mode inspection, recording, and debugging. It is not the Vanessa Automation verification runner.
- External MCP entries are user-provided or future integrations. Preserve entries without proven ITL ownership. The managed receipt binds ownership to a client, physical config and server key; the existing legacy marker rules do not grant ownership in another config layer.
- Final verification never uses MCP. Use `/itl-check` through Vanessa Automation `TESTMANAGER -> TESTCLIENT`.
- A configured auxiliary contour may add `itl-roctup-aux-<id>` and `itl-vanessa-ui-aux-<id>`. These are separate compact facades with separate runtime ownership; the primary `itl-roctup-data` and `itl-vanessa-ui` entries are unchanged. See `auxiliary-contours.md`.

Qualify each family against the current client surface independently. Unavailable or unexposed remote `vibecoding1c` tools do not make the pre-registered branch-local `itl-roctup-data` or `itl-vanessa-ui` facades unavailable. When a concrete task routes to either facade, inspect both direct tools and every client-supported deferred/lazy catalog before declaring it unavailable or falling back; in Codex search `ALL_TOOLS` for the hyphenated logical name and normalized underscore name. A deferred facade counts as exposed. Do not call either facade without the concrete data or runtime question required by its skill.

Do not paste MCP license keys into chat or tracked files. Helper-managed private keys and model state live under `%LOCALAPPDATA%\ITL\MCP\vibecoding1c`; helper-managed local ports are reserved through the ITL port registry (`ITL_PORT_REGISTRY_SCOPE`, `ITL_PORT_REGISTRY_HOME`); ignored project/worktree state lives under `.agent-1c/mcp/`, `.codex/config.toml`, and `.kilo/kilo.json*`.

## OpenCode project configuration

OpenCode can combine `opencode.json`, `opencode.jsonc`,
`.opencode/opencode.json` and `.opencode/opencode.jsonc`. The clientcfg owner
reads their effective entries and physical provenance; it edits only proved
managed contributions in their existing files. Legacy names-only ownership
means root `opencode.json`. A same-name foreign override remains user-owned;
resolve the reported collision and repeat the original reconciliation. The
existing final-set and rollback owners protect all four paths, including absence.

The observed stock Desktop backend 1.18.11 adds `$schema` to schema-less configs
when loading them and can change BOM/newlines. ITL does not perform this host
rewrite. Keep the client's changes; if they race an ITL update, follow the
reported preserved-state reconciliation and rebuild its plan. Configuration
observation alone proves neither MCP attachment nor a successful tool call.

## Availability, recovery and return to work

Observe each server separately: configured entry, explicit enablement (including
`enabled=false`/`disabled=true`), MCP initialization, tools exposed in this task,
and the result of the requested tool. Registry freshness or TCP reachability is
not MCP readiness. A successful validator call is separate evidence. Status and
refresh report configuration only; they do not probe every endpoint or gate the
successful branch/base update on auxiliary remote services.

For a concrete remote tool failure, use current client discovery/status first.
If needed, one targeted diagnostic may perform `initialize ->
notifications/initialized -> tools/list` with a single total budget of 20 seconds,
recording server, checked-at time and failed stage without secrets. Prefer the
client's authenticated transport; never export credentials into a probe. An
external probe proves the endpoint only, not its attachment to this task.

On connection/initialize failure or missing expected tools, before local fallback
run one `sync-client-mcp -Client <current-client>`: it refreshes the registry once
and writes the same selection through the existing configuration owner, preserving
overrides and disablement. A failed refresh retains current connections and does
not prove freshness. Do not run this on successful calls, business/argument errors,
or intentional disablement. Do not blindly replay an uncertain mutation.
Then use supported reconnect and discovery; when useful, perform the bounded
targeted protocol diagnostic above against the resolved address. Distinguish
fresh registry, identity/tools, safe-call result, written config and tools actually
attached to this task. If that gives no useful remedy, continue the
original work without just that remote server. Do not SSH to the dedicated host,
restart its services/containers, deploy, rotate keys, change provider or install a
local replacement unless a separate user request authorizes that work. Do not
disable/remove entries, mark a server permanently offline, or repeat identical
attempts in a loop. Other remote tools and local facades stay in use. Report only
the checks actually omitted; an unavailable validator never becomes a pass.

The failure observation expires: when that tool is next needed after at least
60 seconds, rediscover/retry it once through the current client. A ready event or
changed connection/config evidence permits an immediate retry. Success clears
the observation and the agent uses the recovered tool in the same task. No
background polling or durable offline cache is required. Respect an intentional
user-disabled server; this is not an outage to repair or re-enable.

Expiry clears only the availability observation. It does not prove completion
or cancellation of a timed-out request. Preserve its request ID (when supplied),
input/evidence hashes, observation bounds, raw error and call count; use the
documented status/recovery route before replaying it. Without such evidence,
remote completion stays unknown: do not automatically duplicate that operation,
including from a new chat. Discovery and independent safe calls may continue.

If the client cached a startup failure and still has no tools after the endpoint
recovers, use its supported MCP reload/reconnect and rediscover in the same task.
Codex App Server exposes `config/mcpServer/reload` on the **owning** connection;
use it only when the host provides that capability. Starting a second App Server
does not reconnect this task. Desktop/CLI exposure is client-specific: if the
current host supplies no reload interface, distinguish the fresh registry/written
config, a working endpoint and tools actually attached to this chat. When the
first two are proved but the required tool is still absent, save a compact handoff
in the existing task artifacts and propose a new chat or fork in the exact project
on the same host. Check whether the client exposes creation/fork tools. Use them
only with explicit user authorization for this transition; an existing applicable
authorization needs no repeated question. If tools or authorization are absent,
provide the handoff and supported manual next step while independent work continues.

Carry the original goal and next owner command, checkout/branch/infobase, MCP
versions, source/evidence identities, blocker, permissions and their source,
repair session ID/history/counters and any active or unknown operation. Reference
raw artifacts instead of copying secrets. Context transfer does not transfer live
PID/lease ownership or expand permissions. In the destination, verify actual tool
discovery and a target-scoped safe call; fork history alone does not prove fresh
MCP attachment. For manual protocol qualification retain initialize → initialized
→ tools/list → safe tools/call. Reconcile the existing operation through its owner
before any continuation; never start a second writer or reset a repair session.
If the tool is still absent, report whether config, endpoint or client startup
remains unproved and give that owner's next step. Keep the original task open;
do not claim automatic attachment or demand an application restart on every refresh.

Local workflow-owned MCP: do not settle for working indefinitely without it.
Distinguish normal stopped on-demand backends from a failed facade/tool call;
catalog resolution alone does not start 1C. Use the family's existing recovery
below. For an exposed Vanessa or ROCTUP facade with a connection/cleanup failure,
call `call_tool(name="itl_recover_connection", arguments={})` without asking for
a manual reset. Its existing owner confirms cleanup, including its retained
guard, and verifies a usable connection within the same bounded request phase
as a normal cold call (ten minutes by default, respecting shorter caller limits).
Failed startup reports its phase, elapsed/remaining budget and helper exit or
cancellation reason. Proven registered peers of either family remain alive;
unknown exact-base sessions still require their owner's continuation. Before a new
normal call the facade also reconciles its pending cleanup automatically. A new
chat waiting for the same resources requests cleanup from the original facade
through its project-local connection mailbox; the original signed owner performs
the stop. Active calls are allowed to finish. An obsolete facade without this
control is retired by the helper only after exact project/helper, executable,
process creation, supervisor and complete resource-set identity checks, with
owned native cleanup before guard release. This is version-independent and
needs neither a full Codex restart nor manual PID termination. When the client's
old tools cannot expose this route, start one new chat on the updated config.

Recovery preserves the preceding operation's outcome. After success, the agent
checks its observable effects: reuse a completed result, retry an action proven
not applied, or repeat a safe/idempotent action. The transport does not blindly
duplicate a potentially applied modification. An unknown outcome alone is not
a user-approval barrier: perform available status/readback/recovery steps and
continue independent work; ask only for a concrete unresolved consequential
choice. Preserve a failed recovery's concrete owner/identity/port error and evidence;
do not loop unchanged attempts. Reconcile wrong/missing client entries with
`sync-client-mcp -Client` and the owning client's supported reconnect. Keep project/worktree/infobase scope,
guards and owned-process cleanup. A workflow defect follows
[workflow-incidents.md](workflow-incidents.md): prepare the smallest owner repair,
use already authorized local repair scope, preserve failed evidence, and resume
the original task. Do not bypass the facade or relax database guards. A remaining
local blocker blocks only the dependent operation, with concrete recovery details;
independent work continues.

Config reload advice is emitted for semantic changes to any managed MCP owner,
including remote URLs and local command/args/env; repeated equivalent writes do
not request reload. Writers preserve explicit disablement and user access/tool
policy. Reload only affects when the changed connection can be used and does not
invalidate completed refresh work.

## ROCTUP MCP Toolkit

The client sees the stable logical server `itl-roctup-data` immediately after task startup. Its local stdio facade exposes compact `resolve_tool` and `call_tool`; the verified full catalog remains internal. Resolution never starts 1C. Each inner invocation through `call_tool` acquires the exact call-scoped execution guard before starting `MCP_Toolkit.epf` inside the copied branch infobase in embedded mode:

```powershell
1cv8 ENTERPRISE ... /Execute <MCP_Toolkit.epf> /C "startup;mode=embedded;port=<branchPort>"
```

Rules:

1. Init/update/refresh registers `itl-roctup-data` for the active client and caches the compatible EPF and facade executable. `sync-client-mcp -Client` can register the same facade for another client without switching. No user service or manual MCP action is required.
2. Every client process gets its own backend instance and port. Ports come from `ROCTUP_MCP_PORT_RANGE` and are reserved through the shared ITL port registry with family, project, worktree, branch, and instance identity.
3. The facade may keep its private backend alive between calls, but idle backend lifetime is not database ownership. Each call releases its guard after completion and bounded owned cleanup. A mutating supervisor may drain only an exact identified workflow-owned backend after acquiring the same base guard; foreign processes are preserved. Stdio EOF performs ownership-scoped backend cleanup.
4. Use ROCTUP only for a concrete data exploration operation; do not call its private Streamable HTTP URL directly.
5. Pass known inner names directly to `call_tool` with only intended arguments; use `resolve_tool` only for an unknown name or schema. Start with filtered `get_metadata`, then bounded `execute_query`. Do not invoke `execute_code` or `restart_1c_session` without explicit user request. `close_1c_session` may release the current managed dev-branch session during lifecycle recovery without separate confirmation; source and other-branch infobases remain protected.
6. `ITL_INFOBASE_APPLICATION_NOT_READY` means the source snapshot is not proven in the dev infobase. Report the dependent read as unverified and give the supported `update-dev-branch-base` continuation. Run that helper only when updating this exact branch infobase is already authorized by the task; read access alone is not permission to load a configuration. After the authorized update, repeat the original MCP call once; never make the MCP broker perform the lifecycle mutation itself.
7. Do not load full ROCTUP references eagerly. Cached upstream ROCTUP skills are read only on demand from the version/SHA-scoped immutable artifact directory.
8. The installed workflow lock selects ROCTUP; compatibility metadata and the exact tools/list catalog validate that selection. An explicit qualified hotfix carries its matching catalog. Legacy fresh/locked modes are migration aliases; see [dependency versions](../../../../docs/itl-workflow/dependency-versions.md). A catalog mismatch returns `ITL_ONDEMAND_CATALOG_MISMATCH` and stops the backend.
9. General `status`/`doctor` reports a facade/lock mismatch as a warning so unrelated lifecycle diagnostics remain available. Facade installation and dependent MCP calls still fail closed until normal branch refresh reconciles the branch-local workflow and lock.

## vibecoding1c MCP

Goal: make MCP usable on weak developer machines by preferring remote LAN endpoints while preserving local overrides.

Actions:

- `vibecoding1c-mcp-setup`: default setup/status path; applies saved selection and opens selection when missing or incomplete.
- `vibecoding1c-mcp-select`: explicit remote/local provider, remote `configId`/`hostId`, or local `project|branch` scope.
- `vibecoding1c-mcp-refresh-registry`: update remote endpoint discovery.
- `vibecoding1c-mcp-update`: update registry/distribution/keys/images.
- `vibecoding1c-mcp-status`: inspect configured/skipped/stale/missing-configId servers.
- `vibecoding1c-mcp-start`, `vibecoding1c-mcp-stop`, `vibecoding1c-mcp-rotate-keys`, `vibecoding1c-mcp-ensure-model`, `vibecoding1c-mcp-write-client-config`: advanced helper actions for the active client.
- `sync-client-mcp`: required `-Client`; writes vibecoding1c, on-demand facades, and UI MCP into that client's config without changing the active client, `ai_rules_1c`, or skills. After Cursor `.cursor/mcp.json`, reload the window, enable ITL servers in `+ -> MCP Servers`, and open a new Agent chat. Do not treat an already open chat as connected, and do not dot-source internal writers as a public scenario.

Rules:

1. Remote LAN is the default provider. Remote `code` and `graph` are config-specific and require explicit per-server `configId`; selections do not inherit `configId` or `hostId` from each other.
2. If multiple remote hosts publish the same server, require per-server `hostId`.
3. Store per-developer selection in ignored `.agent-1c/mcp/vibecoding1c-selection.json`.
4. Developers may override each server to local. Local `code` and `graph` require `project` or `branch` scope.
5. Project/branch vibecoding1c endpoints should not be added to neighboring worktrees.
6. Runtime server names stay unique, for example `itl-1c-docs`, `itl-project-code`, or `itl-project-branch-code`.
7. Client config uses upstream `ai_rules_1c` canonical names such as `1c-code-metadata-mcp`, `1c-graph-metadata-mcp`, `1C-docs-mcp`, and `1c-data-mcp` when mapped.
8. Product documentation MCP (`bookstack` / `BookStack-product-docs-mcp`) is PM5-only. When `.agent-1c/project.json` has `baseConfigurationVersion=PM4`, helper selection/start/status/client-config ignores it and removes PM5-only managed client entries while preserving External MCP.
9. `vibecoding1c-mcp-write-client-config` removes only entries marked as vibecoding1c-managed; never delete External MCP or unrelated custom entries.
10. `status`, `/itl-status`, and `list-dev-branches` show configured names, URLs, provider, configId, health, indexed time, and freshness such as `fresh`, `stale`, `remote-shared`, `unknown`, or `indexing`.
11. New `itldev/*` worktrees inherit a complete `master` `.agent-1c/mcp/vibecoding1c-selection.json` automatically. The helper does not copy raw `state.json`; it rematerializes selected `remote` and `local + project` endpoints in the new worktree context so project paths and client config belong to that worktree. Inheritance failures are non-blocking and can be repaired with `vibecoding1c-mcp-setup`.
12. Ignore the legacy logical server `vanessa` if an older or external vibecoding1c distribution manifest or registry still publishes it. Vanessa UI MCP is owned by the separate `ondemand-facade` configuration and must not participate in vibecoding1c selection, completeness, runtime state, status, or client config.
13. For Cursor, distinguish entries present in `.cursor/mcp.json` from the per-chat Agent MCP switches. ITL can report configured and missing managed entries, but Cursor exposes no supported workflow interface for reading those switches. Init, branch creation/refresh, and `/itl-status` therefore state that switch status is not observable and require the user to enable all ITL servers in `+ -> MCP Servers`, then open a new Agent chat. Never infer switch enablement from config presence or endpoint health.

Do not use upstream `/installmcp`, `/updatemcp`, or `/checkmcp` as the normal MCP path in ITL projects. ITL owns MCP client config and removes default upstream endpoints after rules install/update only after ready vibecoding1c replacements have been written. If selection or state is incomplete, preserve upstream entries as a working fallback and run `vibecoding1c-mcp-setup` when ready.

## SPPR project knowledge

The shared registry advertises logical server `sppr` as `sppr-knowledge`.
Workflow setup refreshes the registry before discovering servers, so a newly
published SPPR endpoint is connected by default. For a project with a saved MCP
selection, `update-workflow` also refreshes the registry and reconciles the
active client; an incomplete selection leaves existing connections intact and
requires `vibecoding1c-mcp-setup`. A project that deferred MCP setup still
needs that action. Explicit `sync-client-mcp` refreshes the registry once before reconciling managed
connections. If refresh fails, existing remote connections are preserved and
independent local MCP families can still be reconciled.
Installed projects do not provision the OData collector or store 1C credentials.
The corpus follows the server's explicit project allowlist, independently of
the installed project's infobase. Search is top-k; use `list_sppr_relations`
continuations for complete stored relations and `read_sppr_object` for fields.
`sppr_index_status` reports freshness and extraction/vector gaps without scanning.

## Product and MCP source context

`-Action vibecoding1c-mcp-status -CatalogAction context` reads the applied
selection without network calls or settings writes. The CLI emits compact UTF-8
JSON, including nested values; no extra serialization pipeline is needed.
Internal `Invoke-ItlProductProjectCommand context` callers keep the object result.
It shows the current project,
its declared differences, and selected Code/Graph sources with explicit origin,
usage, limitations and configuration/index information from registry. Preview
uses the same source summary. Missing origin/usage is shown as incomplete; it is
never inferred from a server name or configuration version.

A customized project can explicitly use a typical base product. Its changes
require project/local evidence. PROF can explicitly use CORP as a reference;
apply the target product's knowledge-area rules and exclusions before claiming
a function is available. `own` means an explicit connection, not ownership of
its code. Source version is not automatically the local project's version.

For an explicit connection check, add `-CatalogRecordPath <observation.json>`.
The bounded UTF-8 record has `schemaVersion=1`, applied `catalogRevision` and
`settingsHash`, and optional `roles.code`/`roles.graph` with endpoint, checkedAt
and raw correlated read exchanges; metadata exchanges are optional. The helper
compares the actual selected endpoint and supported native selectors. Code needs
no sourceKey/index stamp. Graph can use selected-project/fulltext context without
an active revision. Registry versions and client activation are separate facts;
HTTP proof alone does not establish native activation. Use existing sync/reload
and a scoped read for a stale connection, or continue with local code. No server
patch/reindex, automatic product substitution or Startup probe is introduced.

### Kilo and OpenCode in one project

Kilo also reads root OpenCode config. ITL keeps Kilo's established `1c-*` names
and permissions, and writes disabled `onec-*` import aliases through the same
MCP owner. OpenCode files and unrelated MCP remain unchanged. An alias already
explicitly configured in Kilo by another owner is preserved with a warning;
verify actual activation before claiming that duplicates were removed.

Kilo 7.8.15 gates its native `/experimental/mcp/call-tool` diagnostic API behind
`KILO_EXPERIMENTAL_MCP_APPS`. A 404 there is not a Code/Graph failure. Native
qualification uses the flag only in its private authenticated loopback `serve`
process; normal agent calls, global client settings and MCP servers are unchanged.
CLI/core proof does not qualify the VS Code frontend.

## Vanessa UI MCP

Vanessa UI MCP is always branch-local and exposed as the stable logical server `itl-vanessa-ui`. The client sees compact `resolve_tool` and `call_tool`; its full verified catalog remains internal. Static form structure, handlers, commands, bindings, and direct edits use graph/code MCP and sources instead.

Rules:

1. Calls must originate from the active `itldev/*` worktree through `itl-vanessa-ui`.
2. `resolve_tool` searches the local catalog without backend startup. The first inner `call_tool` installs missing cached CFE dependencies, starts a client-owned Vanessa `runMcp` instance with silent/fail-closed VanessaExt installation, confirms the component through `get_environment_data`, initializes Streamable HTTP, and verifies the actual catalog before forwarding unchanged arguments. The first-run VanessaExt dialog is disabled.
3. Allocate two distinct ports per facade process through the shared ITL registry: the private MCP manager port and a TestClient port from `VANESSA_MCP_TESTCLIENT_PORT_RANGE`. Starting the manager only reserves the TestClient port; editor-only tools do not start TestClient. The shared `ONEC_MAX_CONCURRENT_SESSIONS` registry guards the manager and each later TestClient launch against the exact infobase; it does not reserve an unused session for an editor-only manager. Before a TestClient-dependent tool, the facade reuses a proven owned process or starts one owned process through the same call-scoped execution context, proves its port, and then proves the manager connection. Idle cleanup stops only that manager and its owned TestClient; it does not release or retain database ownership because the call guard has already ended.
4. Init/update/refresh writes only the active client's native stdio config. `sync-client-mcp -Client` writes the same facades to another client without switching. One client reload is required when the facade is first installed or upgraded; backend starts never rewrite config and need no reload.
5. Pass known inner names such as `search_for_steps_by_keywords`, `open_feature_file`, `check_syntax`, `get_info_about_line_scenario`, `run_scenario`, and `get_test_results` directly to `call_tool`; use `resolve_tool` only when a name or schema is unknown. The agent does not address the private backend or raw HTTP endpoint.
6. All inner tools remain callable and are schema-validated before startup; the facade never auto-approves dangerous operations.
7. A catalog mismatch returns `ITL_ONDEMAND_CATALOG_MISMATCH`, stops the backend, and exposes no unverified tools.
8. Final verification remains `/itl-check` through Vanessa Automation `TESTMANAGER -> TESTCLIENT`, not MCP.
9. For MCP UI work, the workflow broker starts and owns TestClient lazily through the reserved `itl-ondemand` profile. Agents never start a separate `1cv8.exe`, change the reserved profile, or reuse the `/itl-check` TestClient port.
10. A branch must have confirmed unsafe-action protection setup before Vanessa starts. The gateway never weakens protection for the development/TestClient infobase and never edits the user's `conf.cfg`. TestManager uses a branch-local infobase restored from the packaged qualified empty-base DT template; its dedicated `itl_vanessa_service` user already has unsafe-action protection disabled. TestClient-dependent tools auto-connect only after process/capacity preflight. A positive window-list postcondition proves logical connection; explicit absence returns `ITL_VANESSA_TESTCLIENT_NOT_CONNECTED`, and an ambiguous upstream response returns fail-closed `ITL_VANESSA_TESTCLIENT_CONNECTION_STATE_UNAVAILABLE`.

## Legacy Branch Data MCP

Use this only as a conditional legacy fallback for branches that are intentionally web-published; ROCTUP is the preferred data channel. Empty `INFOBASE_PUBLISH_URL` is expected when publication is disabled and must not produce a setup recommendation.

When a new development branch infobase has a web publication URL, the helper may best-effort install branch-local `1c-data-mcp` from `MCP_1C_Distr.zip`, patch the `APA_Инструменты` XML tool name from `vcvalidatequery` to `validatequery`, expose `/hs/mcp`, and connect it only if the endpoint is reachable without authentication.

Data MCP failures during published branch creation are non-blocking unless the branch lifecycle action itself fails. Record the status/error in branch state for diagnostics.

After `ai_rules_1c` update, workflow reconcile removes an old ai_rules-managed `1c-data-mcp` entry when its URL is still an unresolved publication placeholder, the URL is empty, and project/branch publication is disabled. It never removes External/user-managed entries. A non-empty publication URL enables and probes the server as before.
