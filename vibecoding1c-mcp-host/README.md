# vibecoding1c MCP Host

This folder is for the dedicated LAN machine that runs shared vibecoding1c MCP servers.
It does not require Codex, Kilo, the workflow agent, or a target 1C project.

For the administrator runbook in Russian, see [`RUNBOOK.ru.md`](RUNBOOK.ru.md).
The canonical upstream MCP behavior and environment contract is documented at [OneRPA MCP servers for 1C](https://docs.onerpa.ru/mcp-servery-1c).

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
Ticket reads return original image attachments as MCP image content. Per-call OCR is disabled by
default so vision-capable models inspect the original; clients without image support can repeat
`read_ticket` with `image_ocr=true` to receive the draft OCR fallback alongside the original.

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
The first normal MCP request performs the same single-flight readiness check automatically, so
clients do not need to know or call `/ready`. Upstream redirects are consumed inside the proxy
and are never returned to a remote client. After a transport failure only `initialize` and
`tools/list` may be retried once after requalification; `tools/call` is never replayed.

The locally owned BookStack and Mantis HTTP MCP servers run in stateless mode. Restarting or
recreating either container therefore does not invalidate an already connected client's
transport session. The proxy remains transparent and never replays `tools/call`.
Direct and proxy containers created by the installer use Docker
`restart=unless-stopped`. Existing direct containers receive the same policy when started or
reconciled.

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

For periodic recovery without refreshing sources or indexing, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action reconcile -ConfigPath .\host.config.json
```

`reconcile` applies the restart policy to exact containers recorded in host state, starts stopped
containers, checks MCP protocol readiness through each proxy, recreates only missing/unready
proxies, and publishes only qualified endpoints. If qualification still fails, it restarts only
the affected direct runtime and retries once. Missing direct containers require `setup`; reconcile
does not infer or create untracked runtimes.

The supported watchdog is part of the installer and does not require an administrator-written
wrapper script. Enable the `watchdog` section in `host.config.json`, then install its managed
Windows Scheduled Task:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action watchdog-install -ConfigPath .\host.config.json
```

The task runs as the current Windows user at logon and at the configured interval, invokes the
same bounded `reconcile` implementation, ignores overlapping runs, and persists the latest result
to `<stateRoot>/watchdog-state.json`. An unchanged qualified host does not create a new registry
commit on every interval. The installing account must be able to run `docker info` and push the
registry checkout. Manage the shipped task from the same console:

When `docker info` is unavailable, the watchdog uses the bounded Docker Desktop CLI
`status` plus `start` or `restart`, then waits for the daemon before reconciling containers.
If the daemon disappears after that initial probe during any tracked Docker operation, the
watchdog performs one bounded Docker Desktop recovery and retries the complete tracked
reconciliation. A failed retry remains bounded; the next scheduled watchdog interval tries again.
If recovery fails, it publishes the tracked host as `unavailable` without Docker inspection.
The watchdog never invokes `setup`, source refresh, or `reindex`. It also replaces the broken
graph image `curl` healthcheck in generated compose files. Existing running graph containers
receive a small compatibility shim without a container restart or indexing.

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action watchdog-status -ConfigPath .\host.config.json
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action watchdog-run -ConfigPath .\host.config.json
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action watchdog-uninstall -ConfigPath .\host.config.json
```

Installation refuses to replace a same-named task that is not marked as installer-managed.
`watchdog-run` exits successfully without repair when `watchdog.enabled` is false, so configuration
can disable recovery before the managed task is removed.

## Nightly incremental configuration indexing

Enable the managed nightly job only for local `sourcePath` configurations that have complete
`dump` settings:

```json
"nightlyIndex": {
  "enabled": true,
  "at": "02:00",
  "taskName": "ITL MCP Host Nightly Index",
  "timeoutMinutes": 480,
  "pollSeconds": 15,
  "configIds": ["pm5corp", "pm4corp"]
}
```

Install it and inspect or run it from the same host console:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action nightly-index-install -ConfigPath .\host.config.json
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action nightly-index-status -ConfigPath .\host.config.json
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action nightly-index-run -ConfigPath .\host.config.json
powershell -ExecutionPolicy Bypass -File .\install-vibecoding1c-mcp-host.ps1 -Action nightly-index-uninstall -ConfigPath .\host.config.json
```

Each run first updates the repository-connected infobase and performs a fresh incremental
`/DumpConfigToFiles -update -force`, then regenerates `Report.txt`. If the configuration content
and report hash match the last successfully indexed input, MCP indexing is skipped. Otherwise the
Code server receives `reindex(force=false)` and is polled through `stats`; the Graph MCP service
alone is restarted and polled through `get_indexing_status`, with its Neo4j service and data left
running. Graph restart is refused unless the effective runtime proves `RESET_DATABASE=false` and
`AUTO_UPDATE_ON_STARTUP=true`.

The job advances the shared Code/Graph `indexedAt` and publishes registry freshness only after both
servers reach a stable successful status. A failure keeps the previous published index freshness.
The host maintenance lock makes the watchdog skip reconciliation while a nightly run is active.
Task installation does not start an immediate index run; use `nightly-index-run` for the first
controlled execution. `<stateRoot>/nightly-index-state.json` records the last result.

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
proxy           Transactionally rebuild and qualify tracked tools-list proxies, then publish.
reconcile       Recover tracked runtimes/proxies and publish only MCP-ready endpoints.
nightly-index-* Manage or run fresh-dump incremental Code and Graph indexing.
```

Use `-ConfigId <id>` with `start`, `refresh-config`, or `reindex` to limit config-specific work.
Use `-ServerId <id>` with `setup`, `start`, `stop`, `status`, `reindex`, `proxy`, or `reconcile` to manage one MCP server, for example `-ServerId bookstack` or `-ServerId mantis`.
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
In CPU embedding mode the Graph server uses `EMBEDDING_MODEL` locally. Compatibility OpenAI variables are pinned to a loopback fail-closed endpoint so distribution defaults cannot send embedding or chat requests to OpenRouter/OpenAI; set a real `CHAT_API_KEY`, `CHAT_API_BASE`, and `CHAT_MODEL` in `host.config.json` secrets only when Graph chat functions should use an LLM.
Config-specific vector stores from `PATH_BASES` are isolated as `<stateRoot>/bases/<configId>/<serverId>/...` so multiple `code` containers do not share the same zvec lock.

## Registry Contract

The registry repo stores `registry.json` with:

- `schemaVersion`, `publishedAt`, `host`
- `configurations[]`: `configId`, title/source, source/content fingerprints, report hash, dump/report times, nightly status, indexed time
- `servers[]`: server id/scope/provider/configId/name/url/health, index-input fingerprint, and freshness inputs

The registry must not contain license keys, API tokens, Mantis tokens, infobase passwords, or local host paths that are not needed by clients.

## Troubleshooting

If setup fails with `Unable to find image ...` and Docker also reports `read-only file system`, the host script cannot fix it inside the container command. Restart Docker Desktop or run `wsl --shutdown`, then verify:

```powershell
docker info
docker pull comol/template-search-mcp:latest
```

After Docker can pull or the image is loaded locally, rerun `-Action setup`. If the server is not needed, remove `templates` from `enabledServers.global`.
