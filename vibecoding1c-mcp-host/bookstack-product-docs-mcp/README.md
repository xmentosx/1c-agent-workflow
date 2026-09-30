# BookStack semantic indexing

BookStack owns its SQLite cache, fragment vectors, inventory reconciliation and recovery.
Public MCP tools retain their existing arguments; `search_docs` adds optional `mode`
and `diagnostics` arguments.
Exact/FTS search remains available
when semantic indexing is incomplete; `search_docs` discloses that state. `read_page`
continues returning the document during a provider failure.

## Search modes and query cache

`search_docs(query="...", mode="hybrid")` retains the default combined exact/FTS and
semantic search. Use `mode="text"` for SQLite full-text/substring search without an
embedding request, or `mode="semantic"` for vector matches only. Text and hybrid modes
retain the existing BookStack API search fallback when the local search has no matches
or `filters.live=true`; semantic mode never mixes in lexical fallback. Text search is
independent of semantic-index readiness and provider availability. Keep the same query,
filters and mode when following `next_cursor`.
Local FTS uses the standard Snowball Russian stemmer to match inflections through
prefixes in the existing `unicode61` index. Stems shorter than three letters,
Latin tokens, numbers and identifiers remain exact. This is suffix stemming, not
a synonym dictionary or complete linguistic lemmatization. BM25 weights are
4 for titles, 1 for content and 2 for tags. Hybrid ranking combines the lexical
and cosine result positions using reciprocal rank fusion (constant 60), retaining
the existing exact-phrase priority. Semantic mode contributes cosine positions
without a lexical rank. There are
no topic-specific query rules, page boosts or corpus schema changes.

The embedding client keeps the last 256 successful query vectors in an in-memory LRU
cache, keyed by the exact prefixed input hash, embedding profile and credential hash. Repeated queries,
including pagination and different filters, reuse the vector. Concurrent identical
queries share one provider request; failures are not cached. Results are recomputed
against current page revisions, so edits and reindexing remain visible. Changing the
model/profile cannot reuse incompatible entries. Packed Qwen vectors consume up to
8 MiB plus small cache overhead.

A separate disposable SQLite file (`<BOOKSTACK_CACHE_PATH>.query-vectors.sqlite`)
retains up to 256 query vectors across restarts, with the same key and a 24-hour TTL.
It stores float64 vectors and hashes, not query text or credentials. LRU eviction,
expiry and vector/dimension validation bound reuse. Errors in this optional cache
fall back to the normal complete embedding request; they never modify the document
index. `BOOKSTACK_QUERY_CACHE_PATH` can override the path (empty disables disk caching).
`embeddingQueryCacheTtlSeconds` also controls disk TTL; zero disables both disk and
OpenRouter response caching. The in-memory LRU remains available. This adds no
document-index schema migration and requires no reindexing; previous server versions
ignore the new disposable file during rollback.

Queries sent to the official OpenRouter hostname also enable its response cache
with a 24-hour TTL. Identical request bodies under the same API key can reuse the
complete query vector after a process restart. OpenRouter may evict entries before
expiry; a cache miss makes the normal complete embedding request. Passage/indexing
requests do not enable this cache. `embeddingQueryCacheTtlSeconds` in the host config
(`BOOKSTACK_EMBEDDING_QUERY_CACHE_TTL_SECONDS`) sets the TTL; zero disables it.
This caches vectors, not search results: every search still scores the current index.
See [OpenRouter response caching](https://openrouter.ai/docs/guides/features/response-caching).

Requests to the official OpenRouter hostname default to `provider.sort=latency`.
An optional `embeddingProviderOrder` array in the host config
(`BOOKSTACK_EMBEDDING_PROVIDER_ORDER`, comma-separated) sets provider preference
while keeping fallback enabled. This selects a serving provider for the same model;
it does not change the embedding input, profile, dimension, index or result coverage.
Other embedding API endpoints retain their existing request body. External latency
and availability can still vary; full hybrid search waits for the query vector.
Diagnostics include the serving provider and OpenRouter response-cache `HIT`/`MISS`
when reported; the in-memory cache avoids the HTTP request entirely.
The embedding client reuses HTTP connections (up to ten idle connections, expiry
60 seconds), with normal certificate verification and environment proxy settings.
Connection establishment has a five-second timeout and one retry for connection
errors/timeouts; read/write retain 30-second timeouts. HTTP status failures and
read/write failures are not retried. It does not race semantic work against a
deadline that returns lexical-only results.

For a slow query, call `search_docs` with `diagnostics=true`. The optional response
reports server-side milliseconds for local text search, query embedding, vector
scoring, result ranking, live BookStack fallback, and the full search. It also reports
`hit`, `miss`, or `shared` for the query-vector cache and the number of scored
fragments. An embedding failure includes a bounded error in diagnostics and marks
that response `semantic_status=degraded`; index readiness remains a separate state.
Normal search responses omit diagnostics. Vector scoring uses NumPy when the server
requirements are installed and retains the same revision-aware fragment cache; no
index rebuild is required.

## Configuration

Keep the shared host `embedding` settings unchanged. Set only the BookStack override:

```json
"bookStackProductDocsServer": {
  "embedding": { "credentialFile": "E:/private/bookstack-embedding.json" },
  "chunkTokens": 1024,
  "chunkOverlap": 64,
  "semanticMinScore": null,
  "resetDatabase": false
}
```

Retain the existing BookStack base URL, cache path and other fields. The credential file
contains `apiBase: https://openrouter.ai/api/v1`, `model: qwen/qwen3-embedding-8b` and
the existing authorized `apiKey`; keep it private and out of Git. An explicit remote
profile without its key fails instead of silently selecting CPU. Model defaults apply
when `semanticMinScore` is null: E5 0.82, Qwen 0.50. The latter separates the fixed
positive/absent-topic sample in `openspec/changes/bookstack-qwen-fulltext/qualification.md`;
that small sample is not a universal relevance guarantee.

The image installs the CPU PyTorch wheel for the host's local embedding mode. It retains
E5 support without downloading CUDA libraries; Qwen inference uses the configured API.

Qwen uses the English retrieval instruction in `server.py` for queries and unprefixed
passages. The pinned Qwen tokenizer bounds complete inputs, including page and section
titles. No `[:6000]` truncation is performed. Documents split by Markdown/HTML headings,
then whole paragraph/list/table blocks; oversized blocks split with overlap. Offsets refer
to `read_page(format="text")`'s normalized text. One best fragment represents each page
in semantic results; exact/FTS results and page cursors retain their existing behavior.
When the page API omits a URL, the cache uses BookStack's stable `/link/<page-id>` permalink.

References: [Qwen model contract](https://huggingface.co/Qwen/Qwen3-Embedding-8B)
and [OpenRouter embedding API](https://openrouter.ai/docs/api/api-reference/embeddings/submit-an-embedding-request).

## Coverage and continuation

`index_status` reports `ready_pages`, `empty_pages`, `pending_pages`, `fragments`,
`covered_chars`, `total_chars`, `semantic_ready`, inventory completion time and errors.
Readiness requires a completed full inventory and current complete page revisions.
The embedding profile includes endpoint, model, tokenizer revision, instruction and
chunk policy; changing it excludes old vectors. Inputs with identical hashes within
the same profile reuse cached vectors, including after an interrupted build or forced
refresh. Empty pages are complete without a vector. Changed pages exclude old mappings
immediately; removed pages are purged after a successful full inventory only.

After provider/source failure, correct the named condition and call `reindex_docs` again.
A persisted in-progress state after restart is incomplete until that call finishes.
Limited runs never establish full-corpus readiness or delete unseen pages. Provider
request timeouts are bounded; successful batches survive interruption. One process-local
index lock prevents overlapping writers; a competing reindex returns an inspect/retry
continuation. The HTTP service is the sole writer for its cache; do not run a second
index process against a serving cache.

SQLite WAL permits search snapshots alongside atomic index/usage writes. A disposable
in-process vector cache avoids rereading all vectors for every query; the current
page revisions/profile invalidate it. SQLite remains authoritative. Backups and transfers
must use SQLite's backup API, including the WAL state.
The service warms this cache in the background at startup and after a completed
reindex. Searches arriving during that initial load may still wait for the cold
SQLite read; subsequent searches reuse the loaded vectors. The warmup does not
change the index or make remote query-embedding requests.
The pinned tokenizer also loads in a separate startup worker, independently of
reindexing. Concurrent indexing/search calls share one initialization. A query
arriving before that worker finishes waits for the same exact tokenizer; token
limits and complete semantic scoring are unchanged.

`provider_usage` stores successful response counts, returned input tokens and reported
cost. It is not an account invoice: a timed-out/interrupted request can be billed without
returning usage. Distinguish those reported amounts from tokenizer-based estimates.

## Prepare, qualify and switch only BookStack

1. Record the running image ID, BookStack configuration and other container identities.
   Save the private configuration and image under the host's existing backup locations.
   Use SQLite's `Connection.backup` API for a consistent cache copy while E5 keeps serving.
   Never copy a live SQLite main file without its transactional state.
2. Make a separate candidate cache from that snapshot. Run the new BookStack owner with
   this candidate path, the scoped Qwen credentials and automatic startup/scheduling off.
   No second public endpoint or other MCP change is necessary. First migration also makes
   `<cache>.pre-fragments.sqlite` before adding fragment tables; legacy tables remain readable.
3. Run `evaluate_index.py --queries <fixed-sample.json> --output <report.json> --reindex`
   against that candidate. Use `--force` when qualifying changed extraction code; it
   refreshes source text while reusing identical vector inputs. The explicit auditor checks
   every character range, input hash, token bound and vector dimension. Require all positive
   expected pages in semantic top five and check absent-topic scores before choosing a cutoff.
   Exercise interruption/resume, update/delete and restore on disposable copies.
4. Refresh the candidate against the full live inventory immediately before switching.
   Record final coverage, profile, cache hash, provider usage and the exact source commit.
   Source RegisterChange/Targeted is separate from publication and installation.
5. Put the qualified database at `bookstack-cache.sqlite` in its own final cache directory;
   point only `bookStackProductDocsServer.cachePath` there. Keep the previous directory.
   Set the BookStack embedding override, retain `resetDatabase=false`, then invoke the
   installer from the qualified source with the existing host configuration:

   ```powershell
   .\install-vibecoding1c-mcp-host.ps1 -Action start -ServerId bookstack -RecreateBookStack -ConfigPath .\host.config.json
   ```

   This reuses the host maintenance lock, builds before replacing the BookStack container,
   and preserves the prepared database. If maintenance is active, wait for its completion
   and repeat the same command. **Do not use `reindex` for this switch:** that host action
   explicitly resets the database. Ordinary `start` alone starts the existing container
   and does not apply a new image/environment. No source or registry publication is implied.
6. Verify initialize, initialized notification, tools/list, index_status and the fixed real
   queries through the original Product endpoint/proxy. Compare unrelated container IDs
   and configurations. Preserve the previous kit until live acceptance is complete.

## Explicit recovery

The saved image/configuration/cache is an emergency recovery kit. Verify the saved SQLite
with the previous code on a copy. If explicit recovery is needed after switching, use
the previous source/host installer with its saved image and BookStack cache/configuration;
restore only the BookStack fields, never overwrite newer unrelated host settings. The
restored cache reflects the saved point; its regular refresh catches up from BookStack.
There is no automatic E5 fallback or permanent dual index. Before switching, a failed
candidate requires only correction/resume while the existing E5 service keeps serving.
