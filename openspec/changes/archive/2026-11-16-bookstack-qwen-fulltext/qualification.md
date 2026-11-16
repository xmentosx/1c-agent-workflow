# BookStack Qwen candidate qualification — 2026-09-28

The real DEV-ERMAKOV corpus was indexed while the original E5 container continued
serving. This records candidate evidence; source registration, publication and the
post-registration installation receipt are separate.

## Corpus and profile

| Measurement | Result |
| --- | ---: |
| Complete pages / source inventory | 196 / 196 |
| Nonempty / empty pages | 195 / 1 |
| Current fragments | 1468 |
| Covered normalized characters | 1,371,631 / 1,371,631 |
| Fragment input tokens, including titles/overlap | 506,924 |
| Maximum fragment input | 1024 tokens |
| Vector dimensions | 4096 |
| SQLite bytes, including preserved legacy data and reusable vectors | 159,485,952 |
| Previous E5 SQLite bytes | 15,679,488 |

Profile: `qwen/qwen3-embedding-8b::retrieval-v3::94a89a514cfc929527e0`.
The independent auditor checked every page's contiguous offsets, input hashes,
tokenizer limits and vector dimensions. HTML heading preservation accounts for the
normalization-size difference from the old 1,353,742-character cache. All 196 pages
have usable ID permalinks after the final refresh.

## Fixed retrieval sample

The 14 queries and expected pages were fixed before Qwen evaluation; source excerpts
were recorded before examining Qwen results. Query/page/region identity SHA256:
`741ffb22cfc7e75fdd66dbf6ed503e2c56cc53358db2a1b7edc45e675fc8059c`.

| Cases | E5 expected page in semantic top five | Qwen semantic top five | Qwen public top five |
| --- | ---: | ---: | ---: |
| Ordinary (2) | 2/2 | 2/2 | 2/2 |
| Middle (5) | 0/5 | 5/5 | 5/5 |
| Tail (5) | 2/5 | 5/5 | 5/5 |
| All positive (12) | 4/12 | 12/12 | 12/12 |

Qwen ranks the expected page first in 10/12 cases and second in two. Examples include
the plan storage map at offsets 28,969–29,928, indicator version-change description at
27,616–28,843, and earned quantity calculation at 71,543–73,846. Results identify the
heading path and deduplicate the page.

Expected-positive cosine scores range from 0.684248 to 0.819571. The highest scores
for the two absent topics are 0.318736 and 0.367892. The Qwen default **0.50** retains
all expected pages and rejects both absent-topic semantic results. This small sample
does not establish a universal precision estimate.

The original BookStack live-search fallback still returns five broad lexical matches
for the orchid question, identically under E5 and Qwen; the bicycle question returns
none. These are not semantic matches. Exact/FTS/live fallback behavior was preserved,
so negative-topic evidence must not be reported as two empty public responses.

## Performance, reuse and recovery

The same evaluator (one provider embedding plus separate semantic/public searches per
query) measured median query time 1.727 s for E5 and 5.898 s for Qwen. Qwen's first cold
query took 19.379 s; the complete evaluation plus coverage audit took 112.030 s.
These are host observations, not a latency guarantee or a single-MCP-call benchmark.

The initial fragment implementation reread about 215 MB on each search: SQL 9.937 s,
JSON parsing 1.982 s, cosine scoring 0.775 s. The final disposable read cache measured
8.371 s cold load, 0.270 s warm load and 0.971 s warm scoring on the full fragment set.
Numeric arrays occupy 48,103,424 bytes. Page/profile revision changes invalidate it;
tests exercise changed text, renames and deletion after warming the cache. WAL allows
usage/page commits during read snapshots; the reproduced write-lock failure has a
concurrent-reader regression.

A real process interruption left 98 ready pages and 504 saved vectors. Restart reused
saved inputs. A later provider disconnect left 195/196 pages ready, with explicit
incomplete status; ordinary `reindex_docs` completed the remaining page. A final forced
196-page refresh and audit retained identical usage counters: **no additional paid
embedding requests** for unchanged fragment inputs.

Successful provider responses reported 356 requests, 535,454 input tokens and
**USD 0.00574622**, including candidate preparation, retained attempts and query probes.
This is not an invoice: interrupted requests and one response whose usage commit was
blocked can have unreported charges. Live endpoint probes are accounted separately.

The automatic pre-migration SQLite backup was restored to a disposable database and
opened with the previous image/code: integrity `ok`, 196 pages, 195 E5 vectors, no new
fragment tables, and successful text search. The previous image is retained as
`itl/bookstack-product-docs-mcp:pre-qwen-20260928`; private config/source/cache recovery
assets remain only on the host under `backups/bookstack-qwen-20260928`.

## Build and verification boundaries

The default PyTorch dependency tried to download CUDA libraries and exceeded the
existing 900-second image-build bound. The BookStack image now installs the CPU wheel
for the host's local embedding mode. The normal owner build passed; its actual runtime
returned a finite 768-dimensional E5 vector with `torch 2.14.0+cpu`. The actual FastMCP
runtime exposed the same five tools and successfully executed `index_status`.

The Python suite passes 28 tests; focused host regressions cover scoped settings,
build-before-replacement/cache preservation, the exact Cyrillic/whitespace transport
round trip, and maintenance-lock continuation. RegisterChange owns final Targeted proof.
There are no new always-on instructions or public tool arguments; fragment/status
details are returned only by the corresponding calls.

Post-registration installation must use the exact registered source, the qualified
cache and the existing BookStack replacement command. Its ignored runtime receipt
records source/image identity, config isolation, MCP protocol/real queries and other
container identities. Candidate qualification alone does not claim live installation
or source publication.
