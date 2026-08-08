# Vanessa MCP Test Development

Read this together with `vanessa-tests.md` only while creating, editing, or diagnosing `.feature` files.

## Flow

There is no separate Vanessa authoring gate. Use the pre-registered `itl-vanessa-ui` facade only when it shortens test development or resolves a concrete runtime question. Static code, metadata, local libraries, and existing scenarios come first.

Before a runtime MCP call, make the copied branch infobase current when configuration or extension sources changed. `update-dev-branch-base` compares the source fingerprint and skips Designer/Enterprise when the infobase is already current. A `.feature`-only edit does not require an infobase update.

Known inner tools may be passed directly to `call_tool`: `search_for_steps_by_keywords`, `open_feature_file`, `check_syntax`, `get_info_about_line_scenario`, `run_scenario`, `get_test_results`, `user_actions_recording`, `execute_form_actions`, `get_window_list_os`, and `get_window_screenshot_os`. Use only the calls needed for the current question. A scenario run is optional diagnostic feedback, not a persisted verdict or completion condition. There is no required ordered evidence chain and no MCP result can replace `/itl-check`.

The search schema is `search_name`, `search_description`, `search_type`, `exclude_name`, `exclude_description`, `exclude_type`, and `limit`. Never invent `keywords`, call the private endpoint through raw HTTP, or treat KB/reference text as proof that the current runtime exposes a step. If semantic search and local libraries do not reveal a suitable standard step, `frequently_used_steps` is an optional fallback, not a mandatory inventory dump. Query `get_data_from_knowledge_base` only for a named gap and only in small portions; never default to `format=all`. Its text `search_string` is a string; prefer a narrow `question_search` or `answers_search`, and use `questions_only` plus one `one_question` when browsing by question number is cheaper. When interpreting a run, pair `run_scenario` with `get_test_results` from the same facade instance and feature SHA; do not aggregate stale calls, screenshots, or evidence from another instance.

Source-only lint warns about SQL-style `''` inside single-quoted Gherkin values, current-row selection without concrete positioning, unexplained `Пауза`, unsupported cross-step state, and mixed client/server BSL context. These warnings are cheap preflight diagnostics; they neither execute nor certify a scenario.

For a concrete scenario pattern, open only the selected section of `vanessa-recipes.md` and its matching file under `assets/vanessa-authoring-examples`. A `@template` example must have all `<...>` markers replaced and its exact steps/selectors validated in the current project. Do not copy upstream AI prompts or external features wholesale.

When runtime interaction is genuinely unknown, recording is an optional discovery loop: call `user_actions_recording` with `start`, perform the shortest interaction, then call it with `stop`. Treat Turbo Gherkin as an untrusted draft and normalize it into deterministic setup, stable internal names, and exact assertions. Use `execute_form_actions` for a short deterministic batch instead of many field-by-field calls, but stop the batch before a modal dialog, window change, or intermediate state that must be inspected. Read only relevant form state. Do not use command-interface `get_all` unless the route itself is unknown or the task audits the complete command interface. For screenshots, call `get_window_list_os` first and pass one exact returned title to `get_window_screenshot_os`; a screenshot never replaces structured evidence.

`run_scenario` mode `reloadAndRunFromLine` is a diagnostic shortcut only when `lineNumber` is the actual line of a runnable step. It can bypass setup, so rerun the complete focused scenario before interpreting behavior and still use `/itl-check` for verification.

## Libraries And References

`Libraries/ITL/Core` and exactly one of `Libraries/ITL/PM4|PM5` are workflow-managed. `Libraries/Product` is project-owned. Current reference URLs are in `assets/vanessa-reference-suites.json` and always use latest `master`, not pinned commits. PM4 is executable only for PM4; in PM5 it can suggest business cases and Gherkin structure, but steps, data, selectors, forms, and assertions require PM5/runtime validation.

Use the established navigation-link pair:

```gherkin
И я сохраняю навигационную ссылку текущего окна в переменную "Ссылка"
И Я открываю навигационную ссылку "$Ссылка$"
```

In BSL use `ПолучитьНавигационнуюСсылку(Объект.Ссылка)`. A local server-block variable does not become a Vanessa `$Переменная$`; consume it inside that block or transfer it through supported Vanessa context/library steps.

For arbitrary BSL, classify the execution context before authoring. Metadata managers and database access run on the server; forms and client-only common modules run in the client/extension context. When both are required, compute and serialize the reference on the server, store it through a supported Vanessa variable step, and restore it in the client block. Do not use `СохранитьЗначение`/`ВосстановитьЗначение` to bridge VAExtension steps.

## Diagnose One Run

`/itl-check` is the only executable verification gate. Inspect its current run in this order: `status.json`, JUnit, the error directory, fresh event-log report/entries, `vanessa.log`, then TestClient `/Out`. Treat `/Out` as supplementary because Enterprise may leave it empty.

Treat its category as a routing hint, not a proven root cause:

- syntax, undefined/ambiguous steps, and invalid scenario context normally point to the test or its library;
- facade/backend/TestClient/startup failures are runner infrastructure;
- a new event-log error in changed BSL or failure of previously passing unchanged coverage strongly points to the product;
- missing UI elements and assertion mismatches remain ambiguous until compared with the requirement and actual runtime state.

Do not delete, skip, filter, or weaken a scenario merely to make verification green. Change an expected value or core assertion only when requirement evidence shows that the test was wrong. A screenshot is supplementary: capture the intended TestManager window before cleanup and never substitute it for structured results.
