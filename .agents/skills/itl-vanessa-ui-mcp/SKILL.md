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
2. If configuration or extension sources changed since the last branch-infobase load, run the supported `update-dev-branch-base` helper action first. Its fingerprint check skips Designer/Enterprise when the infobase is already current; a `.feature`-only edit needs no base update.
3. Call the pre-registered `itl-vanessa-ui` MCP server. It exposes compact `resolve_tool` and `call_tool`; the verified 38-tool catalog stays inside the facade. For a known semantic tool, call `call_tool` directly with its exact inner `name` and only explicitly intended `arguments`. Use `resolve_tool` once only when the name or schema is unknown; resolution does not start Vanessa or 1C.
4. The first `call_tool` invocation installs missing cached CFE tooling, silently installs/enables the embedded VanessaExt component, and starts a backend instance owned by this client process. There is no confirmation dialog to click; startup fails closed if VanessaExt is not ready. When a UI tool needs TestClient, invoke inner `connect_test_client` with `profileName="itl-ondemand"`. Do not create/edit that profile and do not launch `1cv8.exe` yourself: Vanessa Automation starts its TestClient on the separately leased port supplied by the gateway.
5. Use its semantic tools only to answer the recorded runtime question. The backend and its owned TestClient stop automatically after ten minutes without completed calls or when the client exits.
6. Do not invoke helper start/stop/status actions and do not call the backend through raw HTTP. Report structured facade, catalog, unsafe-action-protection, VanessaExt, or TestClient errors as returned.

For changed feature development, pass known inner names such as `search_for_steps_by_keywords`, `open_feature_file`, `check_syntax`, `get_info_about_line_scenario`, `run_scenario`, and `get_test_results` directly to `call_tool`; do not resolve them first. Search arguments are only `search_name`, `search_description`, `search_type`, `exclude_name`, `exclude_description`, `exclude_type`, and `limit`. Do not treat a knowledge-base entry as proof that a runtime step exists. Use only the calls needed for the current question and one facade instance. Pair `run_scenario` with `get_test_results` from that instance and feature SHA, but treat the result as diagnostic feedback rather than a persisted gate.

## Failure Handling

If a call fails, report the structured facade error and its log path when present. Classify facade/backend/TestClient/path/unsafe-action failures as runner infrastructure and keep a previously passing feature unchanged. Treat syntax, unsupported-step, assertion, and product-behavior failures separately; do not relabel them as runner failures. Ignore stale or foreign-instance evidence. Then use static analysis only as an explicitly labelled diagnostic fallback: it cannot prove the missing runtime behavior.

Run `/itl-check` as the only Vanessa Automation verification gate after configuration or test changes. Diagnose its current run from `status.json`, JUnit, error files, `vanessa.log`, and TestClient `/Out`, in that order. A screenshot is supplementary: capture the intended TestManager window before cleanup, never an arbitrary active window, and do not substitute it for structured results. Never ask the user to click through an ordinary automated run. Do not delete, skip, filter, or weaken a core assertion merely to make verification green.
