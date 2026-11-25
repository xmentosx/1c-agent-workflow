## Why

Mantis MCP currently indexes attachment names but cannot find a phrase that appears only inside a PDF, DOCX or XLSX file. Analysts must open candidate files one by one, while the existing issue search already provides bounded cards, source links and access revocation.

## What Changes

- Extract bounded text from supported attachments after their parent issue is visible to the service account. Keep a per-file outcome (`ready`, `unsupported`, `too_large`, `failed`) and source coordinates.
- Add attachment-content matches to the existing `search_tickets` cards and an explicit content-only mode. Preserve separate filename matches, pagination, output limits, current-access behavior and the $5 shared monthly embedding budget.
- Remove extracted text and vectors when an attachment, comment, issue or project is confirmed inaccessible. Never execute active document content or OCR scanned PDFs in this change.
- Extend the Mantis-owned state compatibly and qualify recovery/rollback before turning extraction on for the live corpus. No other MCP or workflow component owns its queue or data.

## Capabilities

### New Capabilities

- `mantis-attachment-content-search`: Bounded PDF/DOCX/XLSX extraction, source coordinates, visible search matches, status, recovery and revocation.

### Modified Capabilities

None. This repository has no published `openspec/specs` directory; the prior Mantis change lives under `openspec/changes`.

## Impact

`vibecoding1c-mcp-host/mantis-ticket-mcp` gains document parsers, a Mantis-local extraction queue/state migration, attachment-content fragments and search output. The direct `:18006` endpoint and existing ten tools remain; `search_tickets` and `index_control` gain bounded optional fields. Deployment must preserve the current SQLite, Zvec, attachment cache and write journal. The host, Code/BookStack/SPPR MCPs, 1C lifecycle, MantisBT 2.28.1 and its database are unaffected.

Evidence: `mantis_state.sources()` currently emits `filename` fragments only; `mantis_index.search()` restricts modes to `all`, `comments` and `filenames`. The accepted development plan is `build/mantis-development-plan-20260929.md`, stage 7.
