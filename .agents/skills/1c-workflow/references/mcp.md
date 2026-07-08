# MCP Reference

Use this reference for ROCTUP branch data MCP, vibecoding1c MCP, branch-local Vanessa MCP, External MCP preservation, and legacy branch Data MCP. Do not load it for ordinary lifecycle commands unless MCP is part of the request or helper failure.

## Families And Ownership

- ROCTUP MCP Toolkit is the preferred branch-local data channel for `itldev/*` infobases and does not require web publication.
- vibecoding1c MCP is managed by ITL helper actions and natural-language requests.
- Vanessa MCP is separate branch-local tooling for authoring, form inspection, recording, and debugging.
- External MCP entries are user-provided or future integrations. ITL must preserve entries not marked as `managedBy = vibecoding1c-mcp` with `family = vibecoding1c`.
- Final verification never uses MCP. Use `/itl-check` through Vanessa Automation `TESTMANAGER -> TESTCLIENT`.

Do not paste MCP license keys into chat or tracked files. Helper-managed private keys and model state live under `%LOCALAPPDATA%\ITL\MCP\vibecoding1c`; helper-managed local ports are reserved through the ITL port registry (`ITL_PORT_REGISTRY_SCOPE`, `ITL_PORT_REGISTRY_HOME`); ignored project/worktree state lives under `.agent-1c/mcp/`, `.codex/config.toml`, and `.kilo/kilo.json*`.

## ROCTUP MCP Toolkit

ROCTUP runs inside the copied branch infobase through `MCP_Toolkit.epf` in embedded mode:

```powershell
1cv8 ENTERPRISE ... /Execute <MCP_Toolkit.epf> /C "startup;mode=embedded;port=<branchPort>"
```

Actions:

- `install-roctup-mcp`: download/cache the OS-specific release EPF and upstream skills under ignored `.agent-1c/tools/roctup-mcp-toolkit`.
- `update-roctup-mcp`: refresh the cached EPF/skills and dependency lock in `fresh` mode.
- `start-roctup-mcp`: start the current branch embedded server, allocate a branch-local port, and write Codex/Kilo client config.
- `roctup-mcp-status`: inspect port/PID/URL/log/error.
- `stop-roctup-mcp`: stop only the current branch server.

Rules:

1. `new-dev-branch` and `new-extension-dev-branch` auto-start ROCTUP by default when `ROCTUP_MCP_ENABLED=true` and `ROCTUP_MCP_AUTO_START=true`.
2. Ports come from `ROCTUP_MCP_PORT_RANGE` and are reserved through the shared ITL port registry plus active branch states.
3. Branch client names are unique, for example `itl-<project>-<branch>-roctup`.
4. Failures are non-blocking unless `ROCTUP_MCP_REQUIRED=true`; status/error are written to branch state.
5. Agent data exploration should start with filtered `get_metadata`, then bounded `execute_query`. Do not call `execute_code`, `restart_1c_session`, or `close_1c_session` without explicit user request.
6. Do not load full ROCTUP references eagerly. Cached upstream ROCTUP skills are read only on demand from ignored `.agent-1c/tools/roctup-mcp-toolkit/skills`.

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

Do not use upstream `/installmcp`, `/updatemcp`, or `/checkmcp` as the normal MCP path in ITL projects. ITL owns MCP client config and removes default upstream endpoints after rules install/update only after ready vibecoding1c replacements have been written. If selection or state is incomplete, preserve upstream entries as a working fallback and run `vibecoding1c-mcp-setup` when ready.

## Vanessa MCP

Vanessa MCP is always branch-local and starts by default in new `itldev/*` worktrees. Run one server per worktree; do not run a shared Vanessa MCP from `master`.

Actions:

- `install-vanessa-mcp`: install branch-local CFE tooling into the current branch infobase.
- `start-vanessa-mcp`: start Vanessa `runMcp` on a branch-local port and write Codex/Kilo entries.
- `vanessa-mcp-status`: inspect branch-local port/PID/URL.
- `stop-vanessa-mcp`: stop only the current branch server.

Rules:

1. Actions must run from the active `itldev/*` worktree.
2. Allocate ports through the shared ITL port registry plus branch state so neighboring branches, projects, and terminal-server users do not collide.
3. Print client snippets with a branch-specific server name such as `VanessaAutomation-<safeBranchName>`.
4. `start-vanessa-mcp` writes ignored `.codex/config.toml` and `.kilo/kilo.json` through the shared branch MCP config writer.
5. Already running Kilo sessions may not reload MCP config automatically; if the server is not visible after start, reload or restart Kilo Code.
6. Do not write Vanessa MCP into global Codex, VS Code, Cline, Roo, or Continue configs automatically.
7. Do not generate Vanessa MCP as a visible Kilo slash command.

## Legacy Branch Data MCP

Use this only as a fallback for branches that are intentionally web-published; ROCTUP is the preferred data channel.

When a new development branch infobase has a web publication URL, the helper may best-effort install branch-local `1c-data-mcp` from `MCP_1C_Distr.zip`, patch the `APA_Инструменты` XML tool name from `vcvalidatequery` to `validatequery`, expose `/hs/mcp`, and connect it only if the endpoint is reachable without authentication.

Data MCP failures during published branch creation are non-blocking unless the branch lifecycle action itself fails. Record the status/error in branch state for diagnostics.
