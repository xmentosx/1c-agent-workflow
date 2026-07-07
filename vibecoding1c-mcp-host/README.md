# vibecoding1c MCP Host

This folder is for the dedicated LAN machine that runs shared vibecoding1c MCP servers.
It does not require Codex, Kilo, the workflow agent, or a target 1C project.

For the administrator runbook in Russian, see [`RUNBOOK.ru.md`](RUNBOOK.ru.md).

## Setup

1. Copy `host.config.example.json` to `host.config.json`.
2. Edit `hostId`, `baseUrl`, `stateRoot`, GitLab URLs, server settings, BookStack settings, and `configurations`.
   Set `pythonPath` to a real Python 3 executable if `python` in PATH is not reliable.
3. Keep the working `host.config.json` local; it is ignored because it can contain `ONEC_AI_TOKEN`, BookStack API tokens, local paths, and passwords.
4. Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action setup -ConfigPath .\host.config.json
```

`setup` validates Git, Docker, and Python; clones or updates the vibecoding1c MCP distribution;
refreshes configured Git XML dump repositories or reads configured local `sourcePath` folders; generates `Report.txt` with
`norkins/metadata`; starts global and config-specific vibecoding1c MCP containers; writes
`registry.json` to the registry repository; commits and pushes it.

Before creating a new container the installer checks that the configured Docker image exists locally.
If the image is missing, it runs `docker pull <image>` and stops with an explicit Docker daemon/registry
diagnostic if the pull fails.

The `bookstack` global server is built locally from `bookstack-product-docs-mcp/`.
Configure `bookStackProductDocsServer.baseUrl`, set read-only `BOOKSTACK_TOKEN_ID` and
`BOOKSTACK_TOKEN_SECRET` in `secrets`, and keep `bookstack` in `enabledServers.global`.
The MCP publishes as `BookStack-product-docs-mcp` and exposes `search_docs`, `read_page`,
`list_structure`, and `reindex_docs`.

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
reindex         Regenerate Report.txt, recreate RESET_DATABASE-capable servers.
publish         Publish current host state to the registry repo.
```

Use `-ConfigId <id>` with `start`, `refresh-config`, or `reindex` to limit config-specific work.
Use `-ConfigId <id>` with `dump-config` to update one local dump.
Use `-DryRun` to validate generated paths and payloads without Docker/Git writes where possible.
Run `publish` after `reindex` when remote clients should see updated registry freshness metadata.
CPU embedding mode always sets `RESET_CACHE=false` because CPU model cache is mounted at `/app/model_cache` and must not be removed from inside a container.
In CPU embedding mode the Graph server receives a non-secret placeholder `OPENAI_API_KEY` only to satisfy its startup OpenAI client initialization; set `CHAT_API_KEY`, `CHAT_API_BASE`, and `CHAT_MODEL` in `config.env` or `host.config.json` secrets when real Graph chat calls must use an LLM.
Config-specific vector stores from `PATH_BASES` are isolated as `<stateRoot>/bases/<configId>/<serverId>/...` so multiple `code` containers do not share the same zvec lock.

## Registry Contract

The registry repo stores `registry.json` with:

- `schemaVersion`, `publishedAt`, `host`
- `configurations[]`: `configId`, title/source, source fingerprint, report hash, indexed time
- `servers[]`: server id/scope/provider/configId/name/url/health and freshness inputs

The registry must not contain license keys, API tokens, infobase passwords, or local host paths that are not needed by clients.

## Troubleshooting

If setup fails with `Unable to find image ...` and Docker also reports `read-only file system`, the host script cannot fix it inside the container command. Restart Docker Desktop or run `wsl --shutdown`, then verify:

```powershell
docker info
docker pull comol/template-search-mcp:latest
```

After Docker can pull or the image is loaded locally, rerun `-Action setup`. If the server is not needed, remove `templates` from `enabledServers.global`.
