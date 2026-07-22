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
`list_structure`, `index_status`, and `reindex_docs`.
Search defaults to five compact results and exposes `total_matches`, `has_more`, and
`next_cursor` for bounded pagination. Multi-term FTS requires every term, exact matches stay
first, confident semantic matches rank ahead of pages where query terms only occur separately,
and semantic fallback is bounded to the best 20 candidates above the configured
`bookStackProductDocsServer.semanticMinScore` (`0.82` by default). A healthy cache is not padded
with weaker live or semantic results merely to reach the requested limit. `read_page` returns at most 12,000 characters by
default and supports `query`, `heading`, and cursor continuation; use `max_chars=0` only for
an explicit full-page read. `list_structure` returns compact entries and treats its default
limit of 30 as a total budget across the requested scopes.
Tool calls keep the machine-readable payload in `structuredContent` and put only a short
status summary in the traditional text content, avoiding a second full
JSON copy in clients that expose both result forms.

The `mantis` global server is built locally from `mantis-ticket-mcp/`.
Configure `mantisTicketServer.baseUrl`, set read-only `MANTIS_API_TOKEN` in `secrets`,
and keep `mantis` in `enabledServers.global`. The MCP publishes as
`itl-mantis-ticket-mcp` and exposes `read_ticket`, `get_attachment`, and `health`.

The optional `toolsListProxy` (enabled in the example config) supports all permanently hosted
MCP servers and excludes branch-local on-demand MCP. It forwards MCP sessions and `tools/call`
unchanged. `tools/list` substitutes only reviewed top-level routing cards whose source-description
hash still matches `tools-contract.json`; nested JSON Schema descriptions and unapproved or
changed descriptions pass through unchanged. Before publishing a proxy URL it compares tool
names, annotations, and description-free JSON Schemas with the approved contract.
`GET /health` reports only proxy-process liveness. `GET /ready` opens a bounded MCP probe,
validates the live upstream tool contract, and terminates any diagnostic stateful session;
the proxy starts listening before the upstream is ready, and the installer retries readiness
during upstream warm-up before it publishes the proxy URL. A successful readiness probe also
retains the canonical redirected upstream URL for subsequent transparent client calls.

The locally owned BookStack and Mantis HTTP MCP servers run in stateless mode. Restarting or
recreating either container therefore does not invalidate an already connected client's
transport session. The proxy remains transparent and never replays `tools/call`.

After the host has already been set up, enable or refresh all tracked proxies without refreshing
configuration sources, restarting direct MCP servers, or triggering indexing:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action proxy -ConfigPath .\host.config.json
```

`-Action proxy` qualifies every target before updating host state and publishing the registry.
On failure it restores prior proxy containers and host state and does not publish the new URLs.
Use `-ServerId <id>` for one tracked server. Use
`scripts/export-tools-list-proxy-catalog.ps1` to export the live original/candidate catalog and
the byte-reduction report before approving description changes.
`read_ticket` returns comments, issue-level and comment-level attachments, sanitized
rendered HTML, formatting spans, and prompt-ready markdown. Image originals are always
represented as attachment resource handles; OCR text is only draft accompaniment and tells
vision-capable agents to inspect the original image as the source of truth.

For local CPU semantic search, keep the shared embedding setting:

```json
"embedding": {
  "model": "intfloat/multilingual-e5-base"
}
```

BookStack MCP receives `EMBEDDING_MODEL`, uses the shared `<stateRoot>/model-cache`
mounted as `/app/model_cache`, and loads the model locally through `sentence-transformers`.
Retrieval inputs for E5 models use the required `query:` and `passage:` prefixes. The indexed
embedding profile is versioned; a changed profile makes unchanged pages eligible for automatic
reindexing instead of silently reusing incompatible vectors.
When `embedding.apiKey` is configured instead, the server uses the existing
OpenAI-compatible `/embeddings` endpoint path.

To set up and publish only the BookStack MCP without touching other configured servers:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action setup -ConfigPath .\host.config.json -ServerId bookstack
```

To set up and publish only the Mantis ticket MCP:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action setup -ConfigPath .\host.config.json -ServerId mantis
```

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
Use `-ServerId <id>` with `setup`, `start`, `stop`, `status`, or `reindex` to manage one MCP server, for example `-ServerId bookstack` or `-ServerId mantis`.
Use `-ConfigId <id>` with `dump-config` to update one local dump.
Use `-DryRun` to validate generated paths and payloads without Docker/Git writes where possible.
Run `publish` after `reindex` when remote clients should see updated registry freshness metadata.
For BookStack, `index_status` reports local cache freshness and embedding coverage; `reindex_docs` refreshes the cache.
In CPU mode, `index_status` should show `embedding_enabled: true`,
`embedding_model: intfloat/multilingual-e5-base`, and `embedded_pages > 0` after reindex.

BookStack-only operations:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action start -ConfigPath .\host.config.json -ServerId bookstack
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action status -ConfigPath .\host.config.json -ServerId bookstack
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action stop -ConfigPath .\host.config.json -ServerId bookstack
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action reindex -ConfigPath .\host.config.json -ServerId bookstack
```
Mantis-only operations:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action start -ConfigPath .\host.config.json -ServerId mantis
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action status -ConfigPath .\host.config.json -ServerId mantis
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action stop -ConfigPath .\host.config.json -ServerId mantis
```
CPU embedding mode always sets `RESET_CACHE=false` because CPU model cache is mounted at `/app/model_cache` and must not be removed from inside a container.
In CPU embedding mode the Graph server receives a non-secret placeholder `OPENAI_API_KEY` only to satisfy its startup OpenAI client initialization; set `CHAT_API_KEY`, `CHAT_API_BASE`, and `CHAT_MODEL` in `config.env` or `host.config.json` secrets when real Graph chat calls must use an LLM.
Config-specific vector stores from `PATH_BASES` are isolated as `<stateRoot>/bases/<configId>/<serverId>/...` so multiple `code` containers do not share the same zvec lock.

## Registry Contract

The registry repo stores `registry.json` with:

- `schemaVersion`, `publishedAt`, `host`
- `configurations[]`: `configId`, title/source, source fingerprint, report hash, indexed time
- `servers[]`: server id/scope/provider/configId/name/url/health and freshness inputs

The registry must not contain license keys, API tokens, Mantis tokens, infobase passwords, or local host paths that are not needed by clients.

## Troubleshooting

If setup fails with `Unable to find image ...` and Docker also reports `read-only file system`, the host script cannot fix it inside the container command. Restart Docker Desktop or run `wsl --shutdown`, then verify:

```powershell
docker info
docker pull comol/template-search-mcp:latest
```

After Docker can pull or the image is loaded locally, rerun `-Action setup`. If the server is not needed, remove `templates` from `enabledServers.global`.
