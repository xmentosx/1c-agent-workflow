---
name: product-docs
description: Use BookStack product documentation through the BookStack-product-docs-mcp server before changing product business logic, architecture, user workflows, terminology, permissions, reports, integrations, or acceptance tests. Search and cite BookStack pages, read only relevant pages, and surface conflicts between code and documentation.
---

# Product Docs

## Workflow

Use the `BookStack-product-docs-mcp` MCP server as the source of product behavior truth when a task may depend on business rules, architecture, user-facing behavior, product terms, permissions, reports, integrations, or test scenarios.

1. Search first with `search_docs`. Use 2-4 focused queries: user-facing terms, 1C object names, report names, integration names, and Russian synonyms when relevant.
2. Read only the relevant pages with `read_page`, preferring markdown. Keep the BookStack page URL in your notes.
3. Use `list_structure` only when search terms are unclear or when you need to locate the right shelf/book/chapter.
4. If the cache looks stale or search clearly misses known content, call `reindex_docs` or ask the operator to refresh the LAN MCP host if reindex is unavailable.
5. In plans, code explanations, PR notes, and review findings, cite the BookStack page titles and URLs that influenced the decision.

## Conflict Handling

If code and BookStack disagree, do not silently choose one. State the conflict, link the source page, and explain which behavior the implementation follows.

If BookStack is unavailable, continue only when the task can be handled safely from code and local tests. Mention that product docs could not be checked and avoid claiming product-intent certainty.
