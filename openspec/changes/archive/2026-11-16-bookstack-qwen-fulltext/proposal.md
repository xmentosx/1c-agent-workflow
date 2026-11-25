## Why

Product / BookStack currently embeds only one truncated prefix per page. The live cache has 196 pages and 195 E5 vectors; semantic retrieval cannot represent the middle and end of long documents. Embedding failures are swallowed and deleted pages remain cached.

## What Changes

- Use an explicit BookStack-only OpenRouter profile for `qwen/qwen3-embedding-8b`, including Qwen's query instruction.
- Index complete documents as token-bounded, section-aware fragments; retain compact page-level hybrid results and pagination.
- Keep SQLite. Track profile identity, reusable fragment vectors, complete page revisions and full-inventory reconciliation; expose incomplete coverage and provider errors truthfully.
- Prepare and qualify a candidate cache while E5 remains available. Save the previous image/configuration/SQLite for explicit recovery, then switch only BookStack using its existing host owner.
- Validate 12–15 fixed real queries plus lifecycle regressions before claiming live completion.

## Capabilities

### New Capabilities

- `bookstack-complete-semantic-index`: Complete, resumable and profile-consistent fragment retrieval with isolated provider configuration and recoverable migration.

### Modified Capabilities

None.

## Impact

Owned implementation: `vibecoding1c-mcp-host/bookstack-product-docs-mcp`, the BookStack branch of the host installer, owner tests and maintainer documentation. Public MCP tool names/signatures, URLs and other MCP services remain compatible. No new database server, global coordinator, elevation or always-on client instructions. One source commit and RegisterChange; publication remains a separate source-delivery operation.
