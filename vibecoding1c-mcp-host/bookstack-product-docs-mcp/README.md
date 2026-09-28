# BookStack semantic indexing

BookStack owns its SQLite cache, fragment vectors, inventory reconciliation and recovery.
Public MCP tools retain their existing arguments; `search_docs` adds optional `mode`.
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

The embedding client keeps the last 256 successful query vectors in an in-memory LRU
cache, keyed by the exact prefixed input hash and embedding profile. Repeated queries,
including pagination and different filters, reuse the vector. Concurrent identical
queries share one provider request; failures are not cached. Results are recomputed
against current page revisions, so edits and reindexing remain visible. Changing the
model/profile cannot reuse incompatible entries; restarting the process empties the
cache. Packed Qwen vectors consume up to 8 MiB plus small cache overhead. This adds no
SQLite schema migration and requires no reindexing.

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
