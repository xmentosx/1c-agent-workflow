# Vanessa Automation: Agent Guide

> Agent reference. Read this file only before creating or editing Vanessa Automation feature tests. Do not load it for routine lifecycle commands.

Verify the behavior being changed. Add broad smoke, whole-system E2E,
or long regressions only when explicitly requested.

## Quick Algorithm

1. Identify the behavior changed by the feature.
2. Choose the cheapest reliable check type:
   - `unit-like`: calculation, condition, filling, or local applied logic;
   - `integration`: object, document, register, exchange, or data movement between subsystems;
   - `UI`: form, command, or visible user behavior.
3. Search existing steps and local `Libraries`/`@ExportScenarios` before inventing new steps.
   When a concrete pattern is needed, open only the matching recipe in
   `vanessa-recipes.md`; its companion files are under
   `assets/vanessa-authoring-examples`.
4. For OpenSpec, write 2-3 scenarios: the main path and one meaningful
   boundary or negative case. A fourth needs justification. A quick-fix starts
   with one focused regression and adds another only for a separate boundary.
5. Run the final ITL check flow. Vanessa UI MCP may aid test development but is not the test runner.

## Development And Verification

No separate authoring pass. Use `itl-vanessa-ui` only when needed; see `vanessa-authoring.md`. MCP is diagnostic and never replaces `/itl-check`.

## Context Economy

- Search steps by meaning; use Vanessa UI MCP only for runtime UI evidence.
- Prefer data/object/register checks and existing library steps when they prove the same behavior.
- Keep each scenario short: setup, action, 1-3 observable assertions, cleanup if needed.

## UI Authoring Rules

- In single-quoted Gherkin parameters and table cells, escape an apostrophe as `\'`; do not use the BSL/SQL `''` convention.
- Make UI setup self-contained: do not depend on saved form state, the current row, or an active page or mode left by another scenario. Establish the relevant page or mode explicitly.
- Before selecting the current table row, position it by a stable business key; add columns when one value is not unique.
- Clear a field only when selection restores/adds values and the scenario asserts the exact result.
- Assert runtime-visible, available elements after explicitly selecting their page or mode; static child visibility is insufficient.
- For unknown selectors, use targeted graph/code evidence, then Vanessa UI MCP for dynamic state. Read only the relevant `Form.xml` fragment as a final fallback.
- For that local source fallback, call `scripts/get-form-element-context.ps1` with exact element names; it returns only bounded `DataPath`, multi-value, and group/page ancestry records.
- Keep acceptance scenarios fully automated. Interactive profiling is separate tooling, not a reason to add manual pauses or profiling tags to ordinary features.

## BSL Execution Context And State

- Vanessa's `Объект` scenario context is not an arbitrary `Структура`. Do not add fields with `Объект.Поле = ...` or `Объект.Вставить(...)`.
- Keep local BSL values inside one block; across steps use a supported Vanessa variable/library step, not invented `Объект` fields.
- The TestManager runs in a branch-local service infobase restored from the packaged qualified empty-base DT template; the TestClient runs in the development infobase. Before verification, the runner reconciles `client_mcp` in the service infobase and `VAExtension` in the development infobase, including exact per-infobase safe-mode proof. The dedicated `itl_vanessa_service` user in the template has unsafe-action protection disabled, so the runner does not edit the user's `conf.cfg` and does not bypass protection in the development infobase. In an execution-only feature copy, the runner binds Vanessa's generic TestClient opener to the first product profile; source feature files remain unchanged. Product metadata/data access therefore uses `на сервере (Расширение)`, while the plain `на сервере` step is reserved for code that intentionally belongs to the empty TestManager infobase.
- Classify every executable BSL block: product metadata/data access is TestClient server-side through VAExtension; forms and client-only modules are TestClient client-side. Never combine both contexts in one block.
- Transfer cross-context values through supported Vanessa variables. Do not use `СохранитьЗначение`/`ВосстановитьЗначение` as VAExtension cross-step transport.
- Extension forms are supported in the real `TESTMANAGER -> TESTCLIENT` run. A requirement about an extension form, command, or visible state needs a UI scenario; a unit-like BSL check does not replace it.

## Feature File Structure

Minimal structure:

```gherkin
#language: ru

@feature_<change-id>

Функционал: <Короткое имя проверяемой фичи>

Контекст:
	Дано Я запускаю сценарий открытия TestClient или подключаю уже существующий
	И я закрываю все окна клиентского приложения

Сценарий: <Успешный путь>
	# Подготовка
		...

	# Действие
		...

	# Проверка
		...
```

Rules:

- Store application scenarios in `tests/features`.
- Store `.feature` files as strict UTF-8. One leading UTF-8 BOM is accepted for compatibility with existing Windows text writers; invalid UTF-8, NUL, and C0/C1 controls other than TAB/CR/LF fail the preflight at a zero-based byte offset. This byte check does not infer Gherkin semantics; the existing parser/application-scenario preflight remains their owner.
- Name scenarios by checked behavior, not by internal task number.
- Keep independent acceptance scenarios flat so each produces its own JUnit verdict. Do not use `@tree` to group them; reserve it for deliberately aggregated non-acceptance output.
- Add the Vanessa-canonical, case-sensitive `@ExportScenarios` only to library feature files that are actually reused.
- Do not add tags for large smoke/E2E suites to feature-focused checks.

## Worked Recipes

`vanessa-recipes.md` contains five narrow patterns: unit-like logic,
integration/persistence, UI navigation, stable table-row selection, and report
output. Read only the selected recipe. The companion `.feature` files are
machine-linted examples, not a product test suite: `@template` files still
require replacement of every `<...>` marker and validation against the current
step catalog, metadata, and runtime form. The portable unit-like example has no
such marker and may be syntax-checked as-is.

Do not copy an upstream prompt, an entire external scenario, or all recipes into
the task context. Adapt the smallest matching pattern and retain only steps that
prove the changed behavior.

## Reliability

- Create minimal test data in the scenario or library step; use only agreed database fixtures.
- Make test object names unique, for example with the change id plus date or UUID.
- Assert observable results: value, record, movement, table row, command availability, not just absence of errors.
- After opening a form, check warnings and `ErrorWindow` when the next step assumes a successful open.
- Use explicit waits such as `я жду закрытия окна ... в течение 20 секунд`. Use blind pauses only when no stable event exists, and comment why.
- For UI steps, use `с именем '<ИмяЭлемента>'` when the element name is known; window captions can change.
- An unexpected modal fails the automated run; never ask the user to click it. Handle an expected dialog in the scenario.
- After `/itl-check` fails, diagnose before editing. For infrastructure failure, freeze it during infrastructure diagnosis. Never weaken its core assertion.
- Do not stop or touch another worktree's `TESTMANAGER`/`TESTCLIENT`; the helper owns the final run.

## Libraries And Custom Steps

- Move an action to `Libraries` only when at least two scenarios reuse it or it removes real noise.
- Mark library `.feature` files with the Vanessa-canonical, case-sensitive `@ExportScenarios`; application scenarios in `tests/features` call them with a business phrase.
- Add a custom EPF step only when standard Vanessa steps and a library scenario cannot express the action reliably.
- If a custom step is added, keep a minimal `.feature` example next to it.

## Do Not

- Do not write a "smoke test for the whole configuration" for one feature.
- Do not go through menus and forms when server code and assertions can prove the result.
- Do not copy large scenarios from external repositories.
- Do not create more than 4 feature checks without explaining why in `test-plan.md`.
- Do not replace the final ITL check flow with Vanessa UI MCP, a headless EPF launch, or `/deploy-and-test`.
