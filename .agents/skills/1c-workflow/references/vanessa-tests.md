# Vanessa Automation: Agent Guide

> Agent reference. Read this file only before creating or editing Vanessa Automation feature tests. Do not load it for routine lifecycle commands.

Verify the behavior currently being changed. Add broad smoke, whole-system E2E,
or long regressions only when explicitly requested.

## Quick Algorithm

1. Identify the behavior changed by the feature.
2. Choose the cheapest reliable check type:
   - `unit-like`: calculation, condition, filling, or local applied logic;
   - `integration`: object, document, register, exchange, or data movement between subsystems;
   - `UI`: form, command, or visible user behavior.
3. Search existing steps and local `Libraries`/`@exportscenarios` before inventing new steps.
4. For OpenSpec, write 2-3 small scenarios: the main path and one meaningful
   boundary or negative case. A fourth needs justification. A quick-fix starts
   with one focused regression and adds another only for a separate boundary.
5. Run the final ITL check flow. Vanessa UI MCP is only for runtime UI research, authoring support, step search, recording, and debugging; it is not the test runner.

## Mandatory Authoring Gate

Changed `.feature` files require `/itl-vanessa-author`; see `vanessa-authoring.md`. MCP never replaces `/itl-check`.

## Context Economy

- Search known steps by meaning or, for runtime UI evidence, through Vanessa UI MCP; do not paste full catalogs.
- Prefer data/object/register checks over long UI sequences when they prove the same behavior.
- Reuse an existing library step when it already expresses the business action.
- Keep each scenario short: setup, action, 1-3 observable assertions, cleanup if needed.

## UI Authoring Rules

- In single-quoted Gherkin parameters and table cells, escape an apostrophe as `\'`; do not use the BSL/SQL `''` convention.
- Make UI setup self-contained: do not depend on saved form state, the current row, or an active page or mode left by another scenario. Establish the relevant page or mode explicitly.
- Before selecting the current table row, position it by a stable business key; add columns when one value is not unique.
- Clear a field before selection only when it is known to add or restore values and the scenario expects an exact set. Assert the resulting value or set when it is observable; do not inspect every form merely to justify clearing.
- Base assertions on runtime-visible and available elements. Static visibility of a child does not prove user availability under the current page or mode; explicitly select the relevant state and assert only its active elements.
- If a selector is already known, do no extra discovery. For unknown static structure, query targeted graph/code metadata or source; for dynamic visibility or availability, use targeted Vanessa UI MCP evidence. Read only the relevant `Form.xml` fragment as a final fallback, never require a full-form scan.
- For that local source fallback, call `scripts/get-form-element-context.ps1` with exact element names; it returns only bounded `DataPath`, multi-value, and group/page ancestry records.
- Keep acceptance scenarios fully automated. Interactive profiling is separate tooling, not a reason to add manual pauses or profiling tags to ordinary features.

## BSL Context And Extension UI

- Vanessa's `Объект` scenario context is not an arbitrary `Структура`. Do not add fields with `Объект.Поле = ...` or `Объект.Вставить(...)`.
- Values that live only inside one BSL block belong in a local `Структура` created and consumed in that same block. Across steps, use an existing supported Vanessa context mechanism or a reusable library step instead of inventing fields on `Объект`.
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
- Name scenarios by checked behavior, not by internal task number.
- Keep independent acceptance scenarios flat so each produces its own JUnit verdict. Do not use `@tree` to group them; reserve it for deliberately aggregated non-acceptance output.
- Add `@exportscenarios` only to library feature files that are actually reused.
- Do not add tags for large smoke/E2E suites to feature-focused checks.

## Unit-Like Template

Use this when logic can be checked without a form. Create and assert local data in
the same BSL block; replace the placeholder call and expected value.

```gherkin
Сценарий: Проверяемая логика возвращает ожидаемый результат
	И я выполняю код встроенного языка на сервере
		"""bsl
			Результат = 100; // Вызов проверяемой логики.
			Если Результат <> 100 Тогда
				ВызватьИсключение "Ожидался результат 100";
			КонецЕсли;
		"""
```

## Integration Template

Use this when persistence, posting, register movements, objects, or exchange
behavior matters. In one focused scenario:

```gherkin
	# Подготовка
		И я создаю только необходимые уникальные данные
	# Действие
		И я выполняю одну проверяемую прикладную операцию
	# Проверка
		И я читаю измененный объект или регистр и проверяю точный результат
```

## UI Template

Use UI checks only for forms, commands, or visible behavior. Prefer form element names over captions and coordinates.

```gherkin
#language: ru

@feature_order_command

Функционал: Команда заполнения заказа

Контекст:
	Дано Я запускаю сценарий открытия TestClient или подключаю уже существующий
	И я закрываю все окна клиентского приложения

Сценарий: Команда Заполнить добавляет строку товара
	# Подготовка
		И я выполняю код встроенного языка на сервере
		"""bsl
			// Создайте минимальные данные и получите навигационную ссылку.
		"""

	# Действие
		И Я открываю навигационную ссылку "$НавигационнаяСсылка$"
		Если появилось предупреждение Тогда
			Тогда я вызываю исключение "Не удалось открыть заказ для проверки команды заполнения"
		Если имя текущей формы "ErrorWindow" Тогда
			Тогда я вызываю исключение "Открылась форма ошибки при открытии заказа"
		И я нажимаю на кнопку с именем 'ФормаЗаполнить'

	# Проверка
		Тогда в таблице "Товары" количество строк "больше" 0
```

## Reliability

- Create minimal test data in the scenario or library step; use only agreed database fixtures.
- Make test object names unique, for example with the change id plus date or UUID.
- Assert observable results: value, record, movement, table row, command availability, not just absence of errors.
- After opening a form, check warnings and `ErrorWindow` when the next step assumes a successful open.
- Use explicit waits such as `я жду закрытия окна ... в течение 20 секунд`. Use blind pauses only when no stable event exists, and comment why.
- For UI steps, use `с именем '<ИмяЭлемента>'` when the element name is known; window captions can change.
- Do not stop or touch another worktree's `TESTMANAGER`/`TESTCLIENT`; the helper owns the final run.

## Libraries And Custom Steps

- Move an action to `Libraries` only when at least two scenarios reuse it or it removes real noise.
- Mark library `.feature` files with `@exportscenarios`; application scenarios in `tests/features` call them with a business phrase.
- Add a custom EPF step only when standard Vanessa steps and a library scenario cannot express the action reliably.
- If a custom step is added, keep a minimal `.feature` example next to it.

## Do Not

- Do not write a "smoke test for the whole configuration" for one feature.
- Do not go through menus and forms when server code and assertions can prove the result.
- Do not copy large scenarios from external repositories.
- Do not create more than 4 feature checks without explaining why in `test-plan.md`.
- Do not replace the final ITL check flow with Vanessa UI MCP, a headless EPF launch, or `/deploy-and-test`.
