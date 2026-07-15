# Vanessa Automation: Agent Guide

> Agent reference. Read this file only before creating or editing Vanessa Automation feature tests. Do not load it for routine lifecycle commands.

The goal of ITL feature tests is to verify the behavior currently being changed. Do not create broad smoke coverage, whole-system E2E flows, or long user regressions unless the developer explicitly asks for that.

## Quick Algorithm

1. Identify the behavior changed by the feature.
2. Choose the cheapest reliable check type:
   - `unit-like`: calculation, condition, filling, or local applied logic;
   - `integration`: object, document, register, exchange, or data movement between subsystems;
   - `UI`: form, command, or visible user behavior.
3. Search existing steps and local `Libraries`/`@exportscenarios` before inventing new steps.
4. For OpenSpec, write 2-3 small scenarios: the main successful path and one meaningful boundary or negative case; a fourth needs explicit justification. A quick-fix needs at least one focused regression scenario and adds a second only for a separate meaningful boundary.
5. Run the final ITL check flow. Vanessa UI MCP is only for runtime UI research, authoring support, step search, recording, and debugging; it is not the test runner.

## Context Economy

- Read large external smoke suites only as pattern references.
- Search known steps by meaning or, for runtime UI evidence, through Vanessa UI MCP; do not paste full catalogs.
- Prefer data/object/register checks over long UI sequences when they prove the same behavior.
- Reuse an existing library step when it already expresses the business action.
- Keep each scenario short: setup, action, 1-3 observable assertions, cleanup if needed.
- Keep Vanessa history and unrelated suites out of `test-plan.md`.

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

Use this when logic can be checked without walking through a form.

```gherkin
#language: ru

@feature_discount_rule

Функционал: Расчет скидки договора

Контекст:
	Дано Я запускаю сценарий открытия TestClient или подключаю уже существующий

Сценарий: Скидка применяется для договора с действующим условием
	И я выполняю код встроенного языка на сервере
		"""bsl
			ЛокальныеДанные = Новый Структура;
			ЛокальныеДанные.Вставить("Результат", 100); // Вызов проверяемой логики.
			Если ЛокальныеДанные.Результат <> 100 Тогда
				ВызватьИсключение "Ожидался результат 100";
			КонецЕсли;
		"""
```

## Integration Template

Use this when persistence, posting, register movements, documents, objects, or exchange behavior matters.

```gherkin
#language: ru

@feature_order_posting

Функционал: Проведение заказа с резервом

Контекст:
	Дано Я запускаю сценарий открытия TestClient или подключаю уже существующий
	И я закрываю все окна клиентского приложения

Сценарий: Проведение заказа создает резерв по складу
	# Подготовка
		И я выполняю код встроенного языка на сервере
		"""bsl
			// Создайте только необходимые справочники, документ и остатки.
		"""

	# Действие
		И я выполняю код встроенного языка на сервере
		"""bsl
			// Проведите документ или вызовите прикладную операцию.
		"""

	# Проверка
		И я выполняю код встроенного языка на сервере
		"""bsl
			// Прочитайте регистр в локальную переменную и проверьте результат в этом же блоке.
			КоличествоРезерва = 5; // Замените чтением проверяемого регистра.
			Если КоличествоРезерва <> 5 Тогда
				ВызватьИсключение "Ожидался резерв 5";
			КонецЕсли;
		"""
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
