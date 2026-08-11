---
name: itl-vanessa-ui-mcp
description: Use only when a 1C development-branch task needs runtime UI evidence from Vanessa UI MCP: inspect the actual resulting form, reproduce or debug UI behavior, or clarify/record steps for a Vanessa Automation scenario that static code and metadata analysis cannot establish.
---

# ITL Vanessa UI MCP

Vanessa UI MCP is branch-local runtime tooling for the current `itldev/*` worktree. Its TestManager and `client_mcp` run in the worktree's empty service infobase; its TestClient and `VAExtension` run in the development infobase through Vanessa Automation `runMcp`.

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
3. Call the pre-registered `itl-vanessa-ui` MCP server. It exposes compact `resolve_tool` and `call_tool`; the verified 38-tool catalog stays inside the facade. For a known parameterized semantic tool, call `call_tool` directly with its exact inner `name` and `argumentsJson` containing one JSON-encoded object with only explicitly intended fields; this preserves arbitrary inner property names across schema-restricting clients. For a no-argument inner tool, use `arguments={}`. Never send both forms. Use `resolve_tool` once only when the name or schema is unknown; resolution does not start Vanessa or 1C.
4. The first `call_tool` invocation installs missing cached CFE tooling, silently installs/enables the embedded VanessaExt component, and starts a backend instance owned by this client process. There is no confirmation dialog to click; startup fails closed if VanessaExt is not ready. When a UI tool needs TestClient, invoke inner `connect_test_client` with `profileName="itl-ondemand"`. Do not create/edit that profile and do not launch `1cv8.exe` yourself: Vanessa Automation starts its TestClient on the separately leased port supplied by the gateway.
5. Use its semantic tools only to answer the recorded runtime question. The backend and its owned TestClient stop automatically after ten minutes without completed calls or when the client exits.
6. Do not invoke helper start/stop/status actions and do not call the backend through raw HTTP. Report structured facade, catalog, unsafe-action-protection, VanessaExt, or TestClient errors as returned.

For changed feature development, pass known inner names such as `search_for_steps_by_keywords`, `open_feature_file`, `check_syntax`, `get_info_about_line_scenario`, `run_scenario`, `get_test_results`, `user_actions_recording`, `execute_form_actions`, `get_window_list_os`, and `get_window_screenshot_os` directly to `call_tool`; do not resolve them first. Search arguments are only `search_name`, `search_description`, `search_type`, `exclude_name`, `exclude_description`, `exclude_type`, and `limit`. Do not treat a knowledge-base entry as proof that a runtime step exists. Query it only for a named gap and in a bounded portion: `search_string` is text, so prefer a narrow `question_search` or `answers_search`, while `questions_only` plus one `one_question` remains useful when browsing by number is cheaper. Use only the calls needed for the current question and one facade instance. Pair `run_scenario` with `get_test_results` from that instance and feature SHA, but treat the result as diagnostic feedback rather than a persisted gate.

For an unknown interaction, optionally record the shortest action with `user_actions_recording` `start`/`stop`. Returned Turbo Gherkin is a draft: remove noise, replace captions and coordinates with stable element names, establish deterministic setup, and add exact assertions. Prefer one short `execute_form_actions` `actions_json` batch for deterministic exploratory input, but end it before a modal dialog, window change, or intermediate assertion. For visual evidence, always call `get_window_list_os`, choose an exact returned title, and only then call `get_window_screenshot_os`. Never enumerate the whole command interface or form when a targeted read answers the question; command-interface `get_all` is reserved for an unknown route or an explicit complete-interface audit. If local libraries and semantic step search are insufficient, `frequently_used_steps` may suggest a fallback but never proves suitability.

`run_scenario` with `mode=reloadAndRunFromLine` and the real `lineNumber` can shorten diagnosis, but it may skip setup and cannot certify the scenario. Rerun the complete focused scenario before drawing a behavioral conclusion; `/itl-check` remains the gate.

`run_scenario` progress is conditional. Vanessa emits `step N/M` notifications, and the facade forwards them only when the calling MCP client supplied a `progressToken`; the client must also expose those notifications to the user. Without that metadata, no intermediate message is promised. The Vanessa backend uses one UI session, so a concurrent `get_VanessaAutomation_state` can wait behind the active scenario and is not an independent liveness probe. Set the caller timeout from the expected scenario duration, do not classify silence alone as a hang, and use the facade evidence fields `progressTokenProvided` and `progressNotificationsForwarded` to distinguish missing client metadata, absent upstream notifications, and delivered progress after the call completes.

## Failure Handling

If a call fails, report the structured facade error and its log path when present. Classify facade/backend/TestClient/path/unsafe-action failures as runner infrastructure and keep a previously passing feature unchanged. Treat syntax, unsupported-step, assertion, and product-behavior failures separately; do not relabel them as runner failures. Ignore stale or foreign-instance evidence. Then use static analysis only as an explicitly labelled diagnostic fallback: it cannot prove the missing runtime behavior.

Run `/itl-check` as the only Vanessa Automation verification gate after configuration or test changes. Diagnose its current run from `status.json`, JUnit, error files, fresh event-log report/entries, `vanessa.log`, and TestClient `/Out`, in that order; `/Out` is supplementary because Enterprise may leave it empty. A screenshot is supplementary: capture the intended TestManager window before cleanup, never an arbitrary active window, and do not substitute it for structured results. Never ask the user to click through an ordinary automated run. Do not delete, skip, filter, or weaken a core assertion merely to make verification green.
