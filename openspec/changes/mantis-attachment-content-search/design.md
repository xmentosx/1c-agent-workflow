## Context

`mantis_state.sources()` emits issue text, comments and attachment **names**. `search_tickets` uses the same `fragments`/FTS/Zvec store and already enforces issue/comment access, 10-card pagination, a 12000-character response cap and a $5 monthly embedding limit. MantisBT 2.28.1 and the direct MCP endpoint remain fixed. The live index is still importing, so extraction must not block normal issue synchronization or force a full rescan.

## Goals / Non-Goals

**Goals:** Find phrases inside visible PDF, DOCX and XLSX files with a filename and page/paragraph/cell coordinate; expose bounded extraction status; reuse unchanged text and the existing embedding budget; remove derived text on confirmed source revocation.

**Non-Goals:** OCR, macros, legacy DOC/XLS, remote link fetching, document rendering, file-byte retention, a second search service or a shared queue.

## Decisions

1. **Mantis-local ownership and installed-state checkpoint.** Mantis MCP alone owns extraction scheduling, the additive `attachment_extracts` SQLite table and `attachment_content` rows in its existing `fragments`/FTS/Zvec stores. The file ID plus immutable Mantis attachment descriptor identifies work; downloaded bytes are hashed and discarded. No host, Code, BookStack, SPPR or 1C coordinator receives work. The current `State` transaction remains the only authority for publishing fragments and removing revoked data. This is an installed-state migration, so the existing stage-7 plan and this design are the architecture checkpoint: the old image ignores the additive table and can still read the SQLite database, while a rollback disables attachment extraction and may lose derived search rows as old `put_issue` refreshes them. The write journal remains intact. Returning to the new image rehydrates derived text from `attachment_extracts` where possible; any vector lost during old-image cleanup is subject to the shared monthly budget. The preferred operational rollback is the new image with extraction off.
2. **Bounded parser subprocess.** A single file is downloaded only after a fresh visible-parent check, then parsed in a child process with a 20-second deadline and 512-MiB address-space limit. Initial bounds are 5 MiB input, 40 PDF pages, 20 DOCX tables with at most 2000 paragraphs, 20 XLSX sheets/20000 inspected cells, 100000 extracted characters and 10000 ZIP entries/50 MiB expanded ZIP size. The child emits only bounded JSON text/coordinates, never executes macros or external links; scans without a text layer report `unsupported`. This is preferred to in-process parsers because a malformed document can otherwise pin the index worker.
3. **Separate source version and status.** The state records `pending`, `ready`, `unsupported`, `too_large` or `failed` per file, descriptor hash, byte hash, parser version and bounded extracted segments. A worker takes a small number per tick after issue synchronization; retries temporary Mantis/network failures with backoff and retains the last usable result. A changed descriptor or confirmed inaccessible file removes old derived fragments before publishing replacements. A failed parser does not erase a verified old result unless the source changed. Repeated refresh of an unchanged descriptor does not download or re-embed the file.
4. **Search integration.** `mode="attachment_contents"` restricts existing `search_tickets`; `all` includes content matches alongside issue text, comments and filenames. A match has `file_id`, filename, coordinate, snippet and issue/file URL. The existing revision-bound cursor, candidate cap, card grouping, access recheck and 12000-character limit apply. No raw file bytes enter the index or tool response. Semantic embedding uses the same fragment queue and $5 cap; lexical FTS works while OpenRouter is unavailable.

## Risks / Trade-offs

- Parser limits can miss text later in a large document → return an explicit `partial`/`too_large` outcome and sampled counts, never imply full coverage.
- Mantis may expose a file descriptor before bytes are available → keep work pending with a bounded retry; never mark it ready from filename alone.
- Rollback to the older image can remove derived rows on issue refresh → retain the additive extracted-text table, prefer the same-image extraction-off rollback and disclose the possible semantic reindex cost on a later forward transition.
- Existing semantic backlog is large → cap extraction per tick and report separate pending/ready/failed counts; $5 budget still blocks new embeddings without blocking lexical search.

## Migration Plan

1. Add the table and parser dependencies without enabling extraction; test old/new database opening, write journal, revocation and malformed documents on copies.
2. Build and test an exact image. Deploy under the Mantis host lease with the old container retained, volumes unchanged and extraction off. Verify ten tools, normal read/search/write and owner state.
3. Upload marked control PDF/DOCX/XLSX to the approved «Прототипы» project, enable extraction, verify unique phrases/coordinates, bounded status and normal index progress. Expand to the available corpus only after measuring per-file work and free space.
4. On failure disable extraction and restart the same image; if the image itself is bad, restore the old container and report that attachment-content search may be temporarily unavailable. Never discard the SQLite database or write journal.

## Open Questions

No user decision is outstanding. The initial bounds and live throughput are subject to measurement before global extraction is enabled; tighten limits if the sampled corpus exceeds the expected disk/time envelope.
