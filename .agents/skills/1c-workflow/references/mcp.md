# MCP Reference

Use this reference for vibecoding1c MCP, branch-local Vanessa MCP, External MCP preservation, and branch Data MCP. Do not load it for ordinary lifecycle commands unless MCP is part of the request or helper failure.

## Families And Ownership

- vibecoding1c MCP is managed by ITL helper actions and natural-language requests.
- Vanessa MCP is separate branch-local tooling for authoring, form inspection, recording, and debugging.
- External MCP entries are user-provided or future integrations. ITL must preserve entries not marked as `managedBy = vibecoding1c-mcp` with `family = vibecoding1c`.
- Final verification never uses MCP. Use `/itl-check` through Vanessa Automation `TESTMANAGER -> TESTCLIENT`.

Do not paste MCP license keys into chat or tracked files. Helper-managed private keys, ports, and model state live under `%LOCALAPPDATA%\ITL\MCP\vibecoding1c` and ignored project/worktree state under `.agent-1c/mcp/`, `.codex/config.toml`, and `.kilo/kilo.json*`.

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
8. `vibecoding1c-mcp-write-client-config` removes only entries marked as vibecoding1c-managed; never delete External MCP or unrelated custom entries.
9. `status`, `/itl-status`, and `list-dev-branches` show active names, URLs, provider, configId, health, indexed time, and freshness such as `fresh`, `stale`, `remote-shared`, `unknown`, or `indexing`.

Do not use upstream `/installmcp`, `/updatemcp`, or `/checkmcp` as the normal MCP path in ITL projects. ITL owns MCP client config and removes default upstream endpoints after rules install/update only after ready vibecoding1c replacements have been written. If selection or state is incomplete, preserve upstream entries as a working fallback and run `vibecoding1c-mcp-setup` when ready.

## Vanessa MCP

Vanessa MCP is always branch-local and advanced. Run one server per `itldev/*` worktree; do not run a shared Vanessa MCP from `master`.

Actions:

- `install-vanessa-mcp`: install branch-local CFE tooling into the current branch infobase.
- `start-vanessa-mcp`: start Vanessa `runMcp` on a branch-local port and write the Kilo entry.
- `vanessa-mcp-status`: inspect branch-local port/PID/URL.
- `stop-vanessa-mcp`: stop only the current branch server.

Rules:

1. Actions must run from the active `itldev/*` worktree.
2. Allocate ports from branch state so neighboring branches do not collide.
3. Print client snippets with a branch-specific server name such as `VanessaAutomation-<safeBranchName>`.
4. `start-vanessa-mcp` writes `.kilo/kilo.json` with `managedBy = "vanessa-mcp"` and `family = "vanessa"`.
5. Already running Kilo sessions may not reload MCP config automatically; if the server is not visible after start, reload or restart Kilo Code.
6. Do not write Vanessa MCP into global Codex, VS Code, Cline, Roo, or Continue configs automatically.
7. Do not generate Vanessa MCP as a visible Kilo slash command.

## Branch Data MCP

When a new development branch infobase has a web publication URL, the helper may best-effort install branch-local `1c-data-mcp` from `MCP_1C_Distr.zip`, patch the `APA_Инструменты` XML tool name from `vcvalidatequery` to `validatequery`, expose `/hs/mcp`, and connect it only if the endpoint is reachable without authentication.

Data MCP failures during published branch creation are non-blocking unless the branch lifecycle action itself fails. Record the status/error in branch state for diagnostics.
