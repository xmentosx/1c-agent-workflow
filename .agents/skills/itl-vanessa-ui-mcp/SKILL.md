---
name: itl-vanessa-ui-mcp
description: Use only when a 1C development-branch task needs runtime UI evidence from Vanessa UI MCP: inspect the actual resulting form, reproduce or debug UI behavior, or clarify/record steps for a Vanessa Automation scenario that static code and metadata analysis cannot establish.
---

# ITL Vanessa UI MCP

Vanessa UI MCP is branch-local runtime tooling for the current `itldev/*` infobase. It runs through `client_mcp` and `VAExtension` CFE extensions plus Vanessa Automation `runMcp`.

It is distinct from **Vanessa Automation verification**: `/itl-check` runs `StartFeaturePlayer` in the `TESTMANAGER -> TESTCLIENT` topology, produces JUnit and checks the event-log baseline. That verification flow is not an MCP operation and must not be replaced by this skill.

## When To Use

Do **not** start Vanessa UI MCP merely because a request mentions a form. For static questions about form structure, attributes, commands, handlers, bindings, or a direct source change, first use graph/code MCP and the configuration sources.

Use Vanessa UI MCP only when one of these conditions is true:

- the user explicitly asks to inspect, show, reproduce, or debug behavior in user mode;
- the task needs actual UI steps for recording or clarifying a Vanessa Automation scenario;
- source and metadata analysis leave a named runtime gap because the final form depends on indirect code, roles, functional options, opening parameters, extensions, or dynamic form changes.

Before calling the MCP, state the specific runtime question that static analysis could not answer. If the question is answered statically, do not call it.

## Runtime Flow

1. Work only in the active `itldev/*` worktree.
2. Call the pre-registered `itl-vanessa-ui` MCP server. The first tool call installs missing cached CFE tooling when needed and starts a backend instance owned by this client process.
3. Use its semantic tools only to answer the recorded runtime question. The backend stops automatically after ten minutes without completed calls or when the client exits.
4. Do not invoke helper start/stop/status actions and do not call the backend through raw HTTP. Report structured facade, catalog, or broker errors as returned.

For changed feature authoring, prefer `/itl-vanessa-author`. Use `search_for_steps_by_keywords`, `open_feature_file`, `check_syntax`, `get_info_about_line_scenario`, `run_scenario`, and `get_test_results` on `itl-vanessa-ui`. Search uses `search_name`, `search_description`, `search_type`, `exclude_name`, `exclude_description`, `exclude_type`, and `limit`. Do not treat a knowledge-base entry as proof that a runtime step exists.

## Failure Handling

If a call fails, report the structured facade error and its log path when present. Then use static analysis only as an explicitly labelled fallback: it cannot prove the missing runtime behavior.

Do not turn a Vanessa UI MCP failure into an `/itl-check` failure. Run `/itl-check` only as the ordinary Vanessa Automation verification gate after configuration or test changes.
