# vibecoding1c MCP Host

This folder is for the dedicated LAN machine that runs shared vibecoding1c MCP servers.
It does not require Codex, Kilo, the workflow agent, or a target 1C project.

For the administrator runbook in Russian, see [`RUNBOOK.ru.md`](RUNBOOK.ru.md).

## Setup

1. Copy `host.config.example.json` to `host.config.json`.
2. Edit `hostId`, `baseUrl`, `stateRoot`, GitLab URLs, server settings, and `configurations`.
3. Keep the working `host.config.json` local; it is ignored because it can contain `ONEC_AI_TOKEN`, local paths, and passwords.
4. Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action setup -ConfigPath .\host.config.json
```

`setup` validates Git, Docker, and Python; clones or updates the vibecoding1c MCP distribution;
refreshes configured Git XML dump repositories or reads configured local `sourcePath` folders; generates `Report.txt` with
`norkins/metadata`; starts global and config-specific vibecoding1c MCP containers; writes
`registry.json` to the registry repository; commits and pushes it.

Use `dump-config` manually when a local `sourcePath` should be refreshed from a 1C infobase connected to configuration repository storage:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action dump-config -ConfigPath .\host.config.json -ConfigId trade-local
```

## Actions

```text
setup           Refresh sources, start servers, publish registry.
start           Refresh sources and start servers without publishing.
stop            Stop containers tracked in host state.
status          Show tracked servers and endpoints.
dump-config     Update a local sourcePath from a 1C configuration repository infobase.
refresh-config  Regenerate Report.txt and fingerprints for one or all configs.
publish         Publish current host state to the registry repo.
```

Use `-ConfigId <id>` with `start` or `refresh-config` to limit config-specific work.
Use `-ConfigId <id>` with `dump-config` to update one local dump.
Use `-DryRun` to validate generated paths and payloads without Docker/Git writes where possible.

## Registry Contract

The registry repo stores `registry.json` with:

- `schemaVersion`, `publishedAt`, `host`
- `configurations[]`: `configId`, title/source, source fingerprint, report hash, indexed time
- `servers[]`: server id/scope/provider/configId/name/url/health and freshness inputs

The registry must not contain license keys, API tokens, infobase passwords, or local host paths that are not needed by clients.
