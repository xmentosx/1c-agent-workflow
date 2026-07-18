---
name: product-docs
description: Use BookStack product documentation through the BookStack-product-docs-mcp server for PM5 projects before answering, researching, planning, proposing, applying, or changing product business logic, technical or implementation architecture, internal subsystem design, technical decisions and constraints, user workflows, terminology, permissions, reports, integrations, acceptance tests, and OpenSpec explore/propose/apply tasks. Search BookStack before broad repository traversal, then verify against code/tests/current 1C metadata and available MCP evidence, cite relevant pages, and surface conflicts.
---

# Product Docs

## PM4/PM5 Guard

Before using BookStack, inspect `.agent-1c/project.json` when it exists. If `baseConfigurationVersion` is `PM4`, do not use `BookStack-product-docs-mcp`; BookStack product docs cover PM5 only. Continue from the user request, code, tests, current 1C metadata, and available non-product MCP evidence, and explicitly state that PM5 product docs were skipped for a PM4 project.

## Workflow

Use the `BookStack-product-docs-mcp` MCP server as the source of product context and intended behavior when answering, researching, planning, proposing, applying, or changing anything that may depend on business rules, technical or implementation architecture, the internal design of a subsystem, adopted technical decisions and their constraints or rationale, user-facing behavior, product terms, permissions, reports, integrations, test scenarios, or any OpenSpec explore/propose/apply phase.

1. Search first with `search_docs`, before a broad repository traversal. Use 2-4 focused queries with `limit=3` to `5`: user-facing terms, subsystem/architecture terms, 1C object names, report names, integration names, and Russian synonyms when relevant. Stop searching when the same relevant pages recur or the evidence is sufficient. A question such as "как устроена архитектура редактора планов" is a mandatory BookStack-first case.
2. Read only the 1-2 relevant pages with `read_page`, preferring markdown and narrowing the first call with `query` or `heading`. The default response is bounded; follow `next_cursor` only while the missing continuation is relevant. Use `max_chars=0` only when the task explicitly requires the entire page. Keep the BookStack page URL and `updated_at` in your notes when available.
3. Use `list_structure` only when search terms are unclear or when you need to locate the right shelf/book/chapter. Prefer a specific `scope` and keep `limit` at 30 or less.
4. In plans, code explanations, PR notes, and review findings, cite the BookStack page titles, URLs, and relevant `updated_at` values that influenced the decision.
5. Verify the findings against code, tests, current 1C metadata, and available MCP evidence. Explicitly describe documentation/implementation differences.
6. Before changing business logic or recording an architectural/product decision, record a concise chain: `BookStack context`, `Code/MCP evidence`, `Decision`.

## Evidence Policy

Treat current code, tests, 1C metadata, runtime behavior, and domain MCP results as evidence of the product's current factual behavior.

Treat BookStack as evidence of product intent, architecture context, terminology, user workflows, and historical decisions. BookStack is advisory, not automatically authoritative.

Treat the user's task, acceptance criteria, and explicit instructions as the target change request. If BookStack, code, MCP evidence, or the user request disagree, do not assume BookStack is right.

## Verification Workflow

After reading relevant BookStack pages, verify the current behavior in code with `rg`, targeted file reads, tests, and available MCP tools.

For 1C objects, queries, forms, registers, procedures, modules, dependencies, and graph relationships, use `1c-code-metadata-mcp` or available code/graph MCP tools when connected.

For platform APIs and standard 1C mechanisms, use `1C-docs-mcp`, `1c-syntax-checker-mcp`, `1c-ssl-mcp`, and other relevant MCP tools when connected.

If relevant MCP tools are unavailable, continue with files and tests when safe, and explicitly mention that MCP verification was not performed.

## Conflict Handling

If code/MCP evidence and BookStack disagree, do not silently choose one. State the conflict, link the source page, cite the code/MCP evidence, and explain which behavior the implementation follows.

If BookStack is unavailable, explicitly say so before switching to code-only research. Continue only when the task can be handled safely from code, MCP evidence, and local tests, and avoid claiming product-intent certainty.
