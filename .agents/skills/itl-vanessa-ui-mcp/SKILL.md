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
2. Call the pre-registered `itl-vanessa-ui` MCP server. It exposes compact `resolve_tool` and `call_tool`; the verified 38-tool catalog stays inside the facade. For a known semantic tool, call `call_tool` directly with its exact inner `name` and only explicitly intended `arguments`. Use `resolve_tool` once only when the name or schema is unknown; resolution does not start Vanessa or 1C.
3. The first `call_tool` invocation installs missing cached CFE tooling, silently installs/enables the embedded VanessaExt component, and starts a backend instance owned by this client process. There is no confirmation dialog to click; startup fails closed if VanessaExt is not ready. When a UI tool needs TestClient, invoke inner `connect_test_client` with `profileName="itl-ondemand"`. Do not create/edit that profile and do not launch `1cv8.exe` yourself: Vanessa Automation starts its TestClient on the separately leased port supplied by the gateway.
4. Use its semantic tools only to answer the recorded runtime question. The backend and its owned TestClient stop automatically after ten minutes without completed calls or when the client exits.
5. Do not invoke helper start/stop/status actions and do not call the backend through raw HTTP. Report structured facade, catalog, unsafe-action-protection, VanessaExt, or TestClient errors as returned.

For changed feature authoring, prefer `/itl-vanessa-author`. Pass the known inner names `search_for_steps_by_keywords`, `open_feature_file`, `check_syntax`, `get_info_about_line_scenario`, `run_scenario`, and `get_test_results` directly to `call_tool`; do not resolve them first. Search arguments are only `search_name`, `search_description`, `search_type`, `exclude_name`, `exclude_description`, `exclude_type`, and `limit`. Do not treat a knowledge-base entry as proof that a runtime step exists.

## Failure Handling

If a call fails, report the structured facade error and its log path when present. Then use static analysis only as an explicitly labelled diagnostic fallback: it cannot prove the missing runtime behavior. During `/itl-vanessa-author`, finish with `complete-vanessa-authoring -AuthoringResult failed -AuthoringErrorCategory runner`; do not relabel unsupported steps, scenario failures, or product assertions as runner failures.

Run `/itl-check` only as the ordinary Vanessa Automation verification gate after configuration or test changes. The helper may admit a fresh feature-bound infrastructure failure as `runner-fallback-pending`; only its unfiltered `TESTMANAGER -> TESTCLIENT` JUnit proof can complete that fallback. Never bypass or manually edit the authoring state.
