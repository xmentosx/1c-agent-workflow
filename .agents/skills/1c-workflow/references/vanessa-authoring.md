# Vanessa MCP Test Development

Read this together with `vanessa-tests.md` only while creating, editing, or diagnosing `.feature` files.

## Flow

There is no separate Vanessa authoring gate. Use the pre-registered `itl-vanessa-ui` facade only when it shortens test development or resolves a concrete runtime question. Static code, metadata, local libraries, and existing scenarios come first.

Before a runtime MCP call, make the copied branch infobase current when configuration or extension sources changed. `update-dev-branch-base` compares the source fingerprint and skips Designer/Enterprise when the infobase is already current. A `.feature`-only edit does not require an infobase update.

Known inner tools may be passed directly to `call_tool`: `search_for_steps_by_keywords`, `open_feature_file`, `check_syntax`, `get_info_about_line_scenario`, `run_scenario`, and `get_test_results`. Use only the calls needed for the current question. A scenario run is optional diagnostic feedback, not a persisted verdict or completion condition. There is no required ordered evidence chain and no MCP result can replace `/itl-check`.

The search schema is `search_name`, `search_description`, `search_type`, `exclude_name`, `exclude_description`, `exclude_type`, and `limit`. Never invent `keywords`, call the private endpoint through raw HTTP, or treat KB/reference text as proof that the current runtime exposes a step. When interpreting a run, pair `run_scenario` with `get_test_results` from the same facade instance and feature SHA; do not aggregate stale calls, screenshots, or evidence from another instance.

Source-only lint warns about SQL-style `''` inside single-quoted Gherkin values, current-row selection without concrete positioning, unexplained `Пауза`, unsupported cross-step state, and mixed client/server BSL context. These warnings are cheap preflight diagnostics; they neither execute nor certify a scenario.

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
