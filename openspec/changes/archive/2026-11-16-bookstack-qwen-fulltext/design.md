## Context

The user approved Q1/Q2 and the clarified recovery boundary on 2026-09-28: retain serving E5 until Qwen is qualified; predeclare 12–15 real queries; retain an explicit recovery kit without automatic fallback or two permanent indexes. This is the architecture checkpoint for the owner-local SQLite migration. Initial live evidence: DEV-ERMAKOV, container `itl-bookstack-product-docs`, 196 cached pages / 195 E5 vectors, `/data/bookstack-cache.sqlite`.

## Goals / Non-Goals

Goals: complete text coverage, section attribution, compact hybrid retrieval, truthful readiness, paid-vector reuse, interrupted-build recovery and BookStack-only installation. Non-goals: other MCP changes, a new database, rerankers, a global migration coordinator, automatic rollback, always-on dual indexing or changes to client tool signatures.

## Decisions

1. ProductDocsService remains the only index owner. SQLite transactions publish a page revision's complete fragment mapping only after all vectors exist. Separately cached vectors survive interruption. Profile identity includes provider endpoint, model, input instruction, tokenizer and chunking version. Page identity includes title and complete normalized content; timestamps alone are insufficient to invalidate title/content changes. Empty pages are explicitly complete without vectors.
2. The user explicitly approved structural splitting after clarifying it in this chat: headings define sections; preserve whole paragraphs, lists and tables while they fit; split oversized blocks with overlap. Use Qwen's tokenizer with a fixed revision and token-bounded fragments (initial target 1024 tokens including title/heading; 64-token overlap only within oversized blocks). Preserve offsets and all text, including HTML-only headings. The query uses `Instruct: ...\nQuery:...`; passages do not. Validate finite nonzero vectors and dimensions and complete batch indices; reject truncated/invalid responses. No local-model fallback under a remote profile. Batch up to eight uncached passages per request to bound latency and repeat work after a failure.
3. Keep existing SQLite tables readable and add owned profile/vector/page-fragment tables. Back up the legacy database with SQLite's backup API before first migration. Do not overwrite the legacy vectors. An unchanged fragment input reuses its vector even when another fragment changes. A changed page immediately invalidates its old searchable mapping; only a complete replacement becomes searchable. Full successful inventory reconciliation removes absent pages and their mappings; bounded or failed listing never deletes unseen pages.
4. Keep exact/FTS ranking and links. Semantic candidates are best-fragment-per-page before applying the page limit; matched section, offsets and bounded preview accompany the page. Incomplete/failed semantics stays visible in status and search responses while exact/FTS remains usable. Persistent coverage and inventory status survive restarts; a crashed run is incomplete until existing reindex_docs resumes. Serialize owner-local index writes to avoid overlapping scheduler/tool/read updates. Remote requests have bounded timeouts; interruption retains reusable vectors and no page is published halfway.
5. Add `bookStackProductDocsServer.embedding` as a complete scoped override of the shared settings, with an existing credential-file convention. Other server resolutions remain identical. The existing host installer owns image creation and BookStack container replacement. Candidate preparation uses an isolated cache copy and the same server code; it does not register a second permanent service or modify the production cache.

Full-corpus measurements added an owner-local read optimization: SQLite WAL plus a disposable revision-keyed in-process vector cache. Cold reads previously transferred 215 MB per search and blocked a concurrent usage commit in rollback-journal mode. The cache reads each page once, retains compact numeric arrays, and invalidates on page revision/profile changes. SQLite remains the only authoritative state. The image's CPU PyTorch dependency retains the host's local E5 mode; an actual CPU vector probe qualifies it.

Alternatives: one whole-page Qwen vector would fit today's longest page but dilutes local relevance and cannot handle future pages beyond context. In-place reindexing would expose a partial new corpus, contradicting Q1. Another database adds an unproven operating dependency. Keeping two active models permanently adds unnecessary state and cost.

## Risks / Trade-offs

- More fragments increase vector scan and token costs: measure the full corpus, request usage/cost, latency and disk footprint; keep result counts bounded.
- Qwen cosine scores differ from E5: freeze expected pages before evaluation, measure positive and absent-topic queries, and document threshold limits rather than copying 0.82.
- Content can change during preparation: refresh the candidate against the live complete inventory before final acceptance; readiness means that completed source snapshot, not an eternal freshness claim.
- Provider errors can occur after a successful build: expose degradation; retain FTS and cached pages. No automatic model switch.

## Migration Plan

Capture image/configuration identity and SQLite backup, prepare a candidate copy while E5 serves, build and evaluate Qwen, exercise interruption/update/delete/recovery on copies, and verify full coverage. Install the exact registered source via the host owner only for BookStack with the qualified cache. Verify MCP initialize, tools/list, index_status and real search through the client endpoint. Keep the old image/config/cache available for explicit recovery and test restoration on a copy. Source registration, publication, installation and live acceptance are separate evidence; no push or broad source gate is inferred.

## Open Questions

No unresolved product decisions. Candidate evidence is recorded in `qualification.md`; exact registration and installation are separate runtime receipts. Unexpected cross-owner authority or migration scope returns to the user before widening.
