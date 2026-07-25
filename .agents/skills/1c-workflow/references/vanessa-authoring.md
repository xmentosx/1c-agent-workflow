# Vanessa MCP Authoring Contract

Read this together with `vanessa-tests.md` only while creating or editing `.feature` files.

## Flow

Run `/itl-vanessa-author`. The helper updates the copied branch infobase, validates the pre-registered `itl-vanessa-ui` facade, and records authoring state schema v3 without starting a backend. Pass the following known inner names to `call_tool`; the first inner call starts the backend automatically:

`search_for_steps_by_keywords → open_feature_file → check_syntax → get_info_about_line_scenario → run_scenario → get_test_results`.

The search schema is `search_name`, `search_description`, `search_type`, `exclude_name`, `exclude_description`, `exclude_type`, and `limit`. Never invent `keywords`, call the private endpoint through raw HTTP, or treat KB/reference text as proof that the current runtime exposes a step. `complete-vanessa-authoring` requires schema-v2 evidence for the complete ordered chain: search once, open and syntax-check every changed feature, then inspect, run, and read results for every scenario. Evidence is bound to facade instance, project-relative feature path, feature SHA, scenario line, and call arguments SHA; semantic runtime/editor errors are failed calls even if upstream sets `IsError=false`. Failed calls may add a sanitized short `resultMessage` and backend `logPath` without changing schema v2; raw arguments, secrets, configuration content, and successful result content are not persisted.

Execute one authoring chain through one facade instance. Do not aggregate calls, messages, screenshots, or evidence from earlier instances or feature hashes. Always pair each `run_scenario` with `get_test_results`; do not retry a scenario automatically. After the current chain passes, stop editing the feature unless fresh evidence from that same feature SHA identifies a test defect.

A fresh `failed/runner` state may enter `runner-fallback-pending` only with feature-bound failed evidence carrying a recognized facade/backend infrastructure code. The schema-v3 state adds an optional `runnerError` summary with safe code/message, evidence/log paths, facade instance, feature identity, and timestamp; `userReport` emits the same safe summary or the exact text `runner error evidence not found` when the current authoring chain has no matching error. `/itl-check` still runs the normal unfiltered `TESTMANAGER → TESTCLIENT` verification. The fallback becomes passed only when a zero-error, zero-skip JUnit report uniquely matches every changed feature by `testcase@classname`; state records `completionMode=verification-fallback` and retains the original runner failure. Unsupported steps, scenario/product failures, stale hashes, tag filters, legacy schemas, and ambiguous or missing JUnit matches remain blocked.

Before the runtime flow, `/itl-vanessa-author` emits bounded, non-blocking warnings for three source-only risks in changed features: SQL-style `''` inside single-quoted Gherkin values (use `\'`; docstring/BSL bodies are excluded), selecting the current row without an immediately preceding concrete row/key positioning step, and `Пауза` without an immediate explanatory comment. These warnings neither change schema v3 nor replace MCP syntax/runtime evidence. Prefer an observable-state wait to a committed pause. Interactive profiling is a separate diagnostic flow; do not turn its manual observation window into an ordinary acceptance path.

## Libraries And References

`Libraries/ITL/Core` and exactly one of `Libraries/ITL/PM4|PM5` are workflow-managed. `Libraries/Product` is project-owned. Current reference URLs are in `assets/vanessa-reference-suites.json` and always use latest `master`, not pinned commits. PM4 is executable only for PM4; in PM5 it can suggest business cases and Gherkin structure, but steps, data, selectors, forms, and assertions require PM5/MCP validation.

Use the established navigation-link pair:

```gherkin
И я сохраняю навигационную ссылку текущего окна в переменную "Ссылка"
И Я открываю навигационную ссылку "$Ссылка$"
```

In BSL use `ПолучитьНавигационнуюСсылку(Объект.Ссылка)`. A local server-block variable does not become a Vanessa `$Переменная$`; consume it inside that block or transfer it through supported Vanessa context/library steps.

For arbitrary BSL, classify the execution context before authoring. Metadata managers and database access run on the server; forms and client-only common modules run in the client/extension context. When both are required, compute and serialize the reference on the server, store it through a supported Vanessa variable step, and restore it in the client block. Do not use `СохранитьЗначение`/`ВосстановитьЗначение` to bridge VAExtension steps.

## Diagnose One Run

Classify a failure before changing the feature:

- facade/backend/TestClient/path/unsafe-action failures are runner infrastructure; keep a previously passing feature unchanged;
- syntax, missing step, scenario assertion, or product behavior failures may require a feature or product change;
- stale or foreign instance evidence is not evidence for the current chain.

For `/itl-check`, inspect the current run only, in this order: `status.json`, JUnit, the error directory, `vanessa.log`, then TestClient `/Out`. Use a screenshot only for a remaining visual question: capture the intended TestManager window before cleanup, never an arbitrary active desktop window, and never treat the image as a substitute for structured results.
