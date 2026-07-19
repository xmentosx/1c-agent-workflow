# MCP Reference

Use this reference for ROCTUP branch data MCP, vibecoding1c MCP, branch-local Vanessa UI MCP, External MCP preservation, and legacy branch Data MCP. Do not load it for ordinary lifecycle commands unless MCP is part of the request or helper failure.

## Families And Ownership

- ROCTUP MCP Toolkit is the preferred branch-local data channel for `itldev/*` infobases and does not require web publication.
- vibecoding1c MCP is managed by ITL helper actions and natural-language requests.
- Vanessa UI MCP is separate branch-local runtime tooling for user-mode inspection, recording, and debugging. It is not the Vanessa Automation verification runner.
- External MCP entries are user-provided or future integrations. ITL must preserve entries not marked as `managedBy = vibecoding1c-mcp` with `family = vibecoding1c`.
- Final verification never uses MCP. Use `/itl-check` through Vanessa Automation `TESTMANAGER -> TESTCLIENT`.

Do not paste MCP license keys into chat or tracked files. Helper-managed private keys and model state live under `%LOCALAPPDATA%\ITL\MCP\vibecoding1c`; helper-managed local ports are reserved through the ITL port registry (`ITL_PORT_REGISTRY_SCOPE`, `ITL_PORT_REGISTRY_HOME`); ignored project/worktree state lives under `.agent-1c/mcp/`, `.codex/config.toml`, and `.kilo/kilo.json*`.

## ROCTUP MCP Toolkit

The client sees the stable logical server `itl-roctup-data` immediately after task startup. Its local stdio facade serves the verified full tool catalog without starting 1C. The first `tools/call` starts `MCP_Toolkit.epf` inside the copied branch infobase in embedded mode:

```powershell
1cv8 ENTERPRISE ... /Execute <MCP_Toolkit.epf> /C "startup;mode=embedded;port=<branchPort>"
```

Rules:

1. Init/update/refresh registers `itl-roctup-data` for the active client and caches the compatible EPF and facade executable. No user service or manual MCP action is required.
2. Every client process gets its own backend instance and port. Ports come from `ROCTUP_MCP_PORT_RANGE` and are reserved through the shared ITL port registry with family, project, worktree, branch, and instance identity.
3. The facade stops only its owned instance after ten idle minutes or stdio EOF. Lifecycle mutations wait for active calls and stop all owned branch instances before changing the infobase.
4. Use ROCTUP only for a concrete data exploration operation; do not call its private Streamable HTTP URL directly.
5. Start data exploration with filtered `get_metadata`, then bounded `execute_query`. Do not call `execute_code`, `restart_1c_session`, or `close_1c_session` without explicit user request.
6. Do not load full ROCTUP references eagerly. Cached upstream ROCTUP skills are read only on demand from ignored `.agent-1c/tools/roctup-mcp-toolkit/skills`.
7. `fresh` selects the newest ROCTUP version present in the workflow compatibility manifest, never an unverified upstream latest. A catalog mismatch returns `ITL_ONDEMAND_CATALOG_MISMATCH` and stops the backend.

## vibecoding1c MCP

Goal: make MCP usable on weak developer machines by preferring remote LAN endpoints while preserving local overrides.

Actions:

- `vibecoding1c-mcp-setup`: default setup/status path; applies saved selection and opens selection when missing or incomplete.
- `vibecoding1c-mcp-select`: explicit remote/local provider, remote `configId`/`hostId`, or local `project|branch` scope.
- `vibecoding1c-mcp-refresh-registry`: update remote endpoint discovery.
- `vibecoding1c-mcp-update`: update registry/distribution/keys/images.
- `vibecoding1c-mcp-status`: inspect active/skipped/stale/missing-configId servers.
- `vibecoding1c-mcp-start`, `vibecoding1c-mcp-stop`, `vibecoding1c-mcp-rotate-keys`, `vibecoding1c-mcp-ensure-model`, `vibecoding1c-mcp-write-client-config`: advanced helper actions.

Rules:

1. Remote LAN is the default provider. Remote `code` and `graph` are config-specific and require explicit per-server `configId`; selections do not inherit `configId` or `hostId` from each other.
2. If multiple usable remote hosts publish the same server, require per-server `hostId`.
3. Store per-developer selection in ignored `.agent-1c/mcp/vibecoding1c-selection.json`.
4. Developers may override each server to local. Local `code` and `graph` require `project` or `branch` scope.
5. Project/branch vibecoding1c endpoints should not be added to neighboring worktrees.
6. Runtime server names stay unique, for example `itl-1c-docs`, `itl-project-code`, or `itl-project-branch-code`.
7. Client config uses upstream `ai_rules_1c` canonical names such as `1c-code-metadata-mcp`, `1c-graph-metadata-mcp`, `1C-docs-mcp`, and `1c-data-mcp` when mapped.
8. Product documentation MCP (`bookstack` / `BookStack-product-docs-mcp`) is PM5-only. When `.agent-1c/project.json` has `baseConfigurationVersion=PM4`, helper selection/start/status/client-config ignores it and removes PM5-only managed client entries while preserving External MCP.
9. `vibecoding1c-mcp-write-client-config` removes only entries marked as vibecoding1c-managed; never delete External MCP or unrelated custom entries.
10. `status`, `/itl-status`, and `list-dev-branches` show active names, URLs, provider, configId, health, indexed time, and freshness such as `fresh`, `stale`, `remote-shared`, `unknown`, or `indexing`.
11. New `itldev/*` worktrees inherit a complete `master` `.agent-1c/mcp/vibecoding1c-selection.json` automatically. The helper does not copy raw `state.json`; it rematerializes selected `remote` and `local + project` endpoints in the new worktree context so project paths and client config belong to that worktree. Inheritance failures are non-blocking and can be repaired with `vibecoding1c-mcp-setup`.
12. Ignore the legacy logical server `vanessa` if an older or external vibecoding1c distribution manifest or registry still publishes it. Vanessa UI MCP is owned by the separate `ondemand-facade` configuration and must not participate in vibecoding1c selection, completeness, runtime state, status, or client config.

Do not use upstream `/installmcp`, `/updatemcp`, or `/checkmcp` as the normal MCP path in ITL projects. ITL owns MCP client config and removes default upstream endpoints after rules install/update only after ready vibecoding1c replacements have been written. If selection or state is incomplete, preserve upstream entries as a working fallback and run `vibecoding1c-mcp-setup` when ready.

## Vanessa UI MCP

Vanessa UI MCP is always branch-local and exposed as the stable logical server `itl-vanessa-ui`. Its full verified tool catalog is visible before Vanessa or 1C starts. Static form structure, handlers, commands, bindings, and direct edits use graph/code MCP and sources instead.

Rules:

1. Calls must originate from the active `itldev/*` worktree through `itl-vanessa-ui`.
2. The first call installs missing cached CFE dependencies, starts a client-owned Vanessa `runMcp` instance, initializes Streamable HTTP, and verifies the actual catalog before forwarding unchanged arguments.
3. Allocate a distinct port per facade process through the shared ITL registry. A client exit or ten idle minutes stops only that instance and releases its lease.
4. Init/update/refresh writes only the active client's native stdio config. One client reload is required when the facade is first installed or upgraded; backend starts never rewrite config and need no reload.
5. Use `search_for_steps_by_keywords`, `open_feature_file`, `check_syntax`, `get_info_about_line_scenario`, `run_scenario`, and `get_test_results` by their semantic names. The agent does not address the private gateway or raw HTTP endpoint.
6. All tools and annotations remain visible; client confirmations still apply and the facade never auto-approves dangerous operations.
7. A catalog mismatch returns `ITL_ONDEMAND_CATALOG_MISMATCH`, stops the backend, and exposes no unverified tools.
8. Final verification remains `/itl-check` through Vanessa Automation `TESTMANAGER -> TESTCLIENT`, not MCP.

## Legacy Branch Data MCP

Use this only as a conditional legacy fallback for branches that are intentionally web-published; ROCTUP is the preferred data channel. Empty `INFOBASE_PUBLISH_URL` is expected when publication is disabled and must not produce a setup recommendation.

When a new development branch infobase has a web publication URL, the helper may best-effort install branch-local `1c-data-mcp` from `MCP_1C_Distr.zip`, patch the `APA_Инструменты` XML tool name from `vcvalidatequery` to `validatequery`, expose `/hs/mcp`, and connect it only if the endpoint is reachable without authentication.

Data MCP failures during published branch creation are non-blocking unless the branch lifecycle action itself fails. Record the status/error in branch state for diagnostics.

After `ai_rules_1c` update, workflow reconcile removes an old ai_rules-managed `1c-data-mcp` entry when its URL is still an unresolved publication placeholder, the URL is empty, and project/branch publication is disabled. It never removes External/user-managed entries. A non-empty publication URL enables and probes the server as before.
