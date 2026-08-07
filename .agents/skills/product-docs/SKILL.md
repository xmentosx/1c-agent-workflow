---
name: product-docs
description: Use BookStack product documentation through the BookStack-product-docs-mcp server for PM5 projects before answering, researching, planning, proposing, applying, or changing product business logic, technical or implementation architecture, internal subsystem design, technical decisions and constraints, user workflows, terminology, permissions, reports, integrations, acceptance tests, and OpenSpec explore/propose/apply tasks. Search BookStack before broad repository traversal, then close task-relevant current-state gaps with the minimum sufficient non-duplicative code, metadata, test, runtime, or MCP evidence, cite relevant pages, and surface conflicts.
---

# Product Docs

## PM4/PM5 Guard

Before using BookStack, inspect `.agent-1c/project.json` when it exists. If `baseConfigurationVersion` is `PM4`, do not use `BookStack-product-docs-mcp`; BookStack product docs cover PM5 only. Continue from the user request and the minimum sufficient available code, test, current-metadata, runtime, or non-product MCP evidence, and explicitly state that PM5 product docs were skipped for a PM4 project.

## Workflow

Use `BookStack-product-docs-mcp` as the source of product context and intended behavior for the PM5 scope in the description, including OpenSpec explore/propose/apply.

### OpenSpec Context Reuse

Evaluate the PM4/PM5 guard before either BookStack lookup or reuse. A PM4 project must not reuse recorded PM5 BookStack context as product evidence.

For the same OpenSpec change and unchanged scope, do not repeat `search_docs` or `read_page` when the conversation or proposal `## Context Sources` contains a sufficient handoff. In `proposal.md`, record each material page title, URL, exact `updated_at` returned by BookStack, and relevant conclusion. Explore may reuse the conversation; propose writes the handoff; apply reads it through OpenSpec `contextFiles`.

Reuse only complete, relevant entries not marked provisional or unavailable. Re-query on scope change, missing URL or `updated_at`, a page update known or suspected, an explicit freshness request, conflicting code/MCP evidence, or an unresolved product-context gap. For same-page freshness call `read_page` by ID or URL; repeat broad `search_docs` only when scope or source relevance changed.

Stored `updated_at` is provenance, not proof of live freshness. Never call reused context confirmed current. Reuse avoids only repeated BookStack lookup; close unresolved current-state gaps under the evidence policy below.

### Lookup When Reuse Does Not Apply

1. Search first with `search_docs`, before a broad repository traversal. Use 2-4 focused queries with `limit=3` to `5`: user-facing terms, subsystem/architecture terms, 1C object names, report names, integration names, and Russian synonyms when relevant. Stop searching when the same relevant pages recur or the evidence is sufficient. When the task explicitly requires exhaustive coverage, follow `next_cursor` until `has_more=false`; do not increase the per-call limit merely to avoid pagination. A question such as "как устроена архитектура редактора планов" is a mandatory BookStack-first case.
2. Read only the 1-2 relevant pages with `read_page`, preferring markdown and narrowing the first call with `query` or `heading`. The default response is bounded; follow `next_cursor` only while the missing continuation is relevant. Use `max_chars=0` only when the task explicitly requires the entire page. Keep the BookStack page URL and `updated_at` in your notes when available.
3. Use `list_structure` only when search terms are unclear or when you need to locate the right shelf/book/chapter. Prefer a specific `scope` and keep `limit` at 30 or less.
4. In plans, code explanations, PR notes, and review findings, cite the BookStack page titles, URLs, and relevant `updated_at` values that influenced the decision.
5. Close task-relevant current-state gaps with minimum sufficient evidence; stop when the question is answered instead of collecting every channel. Explicitly describe documentation/implementation differences.
6. Before changing business logic or recording an architectural/product decision, record a concise chain: `BookStack context`, `Code/MCP evidence`, `Decision`.

## Evidence Policy

Current code, tests, 1C metadata, runtime behavior, and domain MCP results are evidence of factual behavior. BookStack supplies intent and architecture context; BookStack is advisory, not automatically authoritative. The user's task and acceptance criteria define the requested change.

## Verification Workflow

After BookStack, gather minimum sufficient non-duplicative evidence only for unresolved current-behavior facts; stop when those gaps are closed.

For 1C objects, code, forms, dependencies, graph relationships, and source locations, use `1c-code-metadata-mcp` or available code/graph MCP as the primary discovery path. Read a specific MCP-located file only for exact edit context, untruncated surroundings, or current disk state; that targeted read complements discovery and is not a second search. Do not run `rg`, glob, scan modules, or repeat a lookup after MCP answered the gap. Native discovery is allowed only when project-index MCP is unavailable, a bounded tuned MCP attempt is insufficient, the index may be stale after local edits, or the target is outside it; state the reason briefly.

Use tests or runtime evidence only to establish behavior, resolve a conflict, or validate a change. They are not mandatory for every explanation, research task, plan, or proposal.

For platform APIs and standard 1C mechanisms, use `1C-docs-mcp`, `1c-syntax-checker-mcp`, `1c-ssl-mcp`, and other relevant MCP tools when connected.

If relevant MCP tools are unavailable, continue with files and tests when safe, and explicitly mention that MCP verification was not performed. For `Session not found`, tell the user to run `/reload` before retrying the MCP call; do not imply that a repeated call on the same stale session restored verification.

## Conflict Handling

If code/MCP evidence and BookStack disagree, state the conflict, link the page, cite current evidence, and explain which behavior the implementation follows.

If BookStack is unavailable, say so before code-only research. Continue only when safe and do not claim product-intent certainty.
