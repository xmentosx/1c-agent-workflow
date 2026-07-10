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

Before starting the MCP, state the specific runtime question that static analysis could not answer. If the question is answered statically, do not start it.

## Runtime Flow

1. Work only in the active `itldev/*` worktree.
2. Inspect branch state with `vanessa-mcp-status`. Empty `VANESSA_MCP_PORT` or `VANESSA_MCP_URL` means the on-demand server is stopped; it does not mean Vanessa UI MCP is unconfigured.
3. Run `start-vanessa-mcp` when the runtime question requires it. The helper installs cached CFE tooling into the copied branch infobase when needed and writes branch-local Codex/Kilo MCP client config.
4. Use the exposed Vanessa UI MCP tools only to answer the recorded runtime question. If the current Kilo session does not expose the server after start, report that a reload or restart is required.
5. Run `stop-vanessa-mcp` after the research, recording, or debugging operation.

## Failure Handling

If start fails, report the actual helper error and the branch MCP log path from `vanessa-mcp-status`. Then use static analysis only as an explicitly labelled fallback: it cannot prove the missing runtime behavior.

Do not turn a Vanessa UI MCP failure into an `/itl-check` failure. Run `/itl-check` only as the ordinary Vanessa Automation verification gate after configuration or test changes.
