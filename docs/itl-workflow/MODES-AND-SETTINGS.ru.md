# Режимы и пользовательские настройки

Настройки проекта находятся в ignored-файле `.dev.env`. Большинство режимов можно переключить slash-командой или обычным запросом агенту. Полный перечень переменных приведен в [справочнике `.dev.env`](DEV-ENV-REFERENCE.ru.md).

Штатные значения: `VERIFICATION_DEPTH=full`, `UI_TESTING=manual`, `ORCHESTRATION=standard`, `CAVEMAN=on`, `ITL_VANESSA_TESTING=auto`, `ITL_CHECK_EVENT_LOG=auto`, `DEPENDENCY_MODE=fresh`, `VERIFICATION_POLICY=warn`.

## Краткая карта

| Назначение | Команда/параметр | Значения | Default | Область действия |
|---|---|---|---|---|
| Глубина upstream статических проверок | `/litemode`, `VERIFICATION_DEPTH` | `full`, `standard`, `lite` | `full` | проект |
| Browser UI testing upstream | `UI_TESTING` | `auto`, `manual`, `off` | `manual` | проект |
| ITL Vanessa Automation | `/itl-litemode`, `ITL_VANESSA_TESTING` | `auto`, `manual`, `off` | `auto` | проект/worktree |
| ITL журнал регистрации | `/itl-litemode`, `ITL_CHECK_EVENT_LOG` | `auto`, `manual`, `off` | `auto` | проект/worktree |
| Оркестрация | `/economymode`, `ORCHESTRATION` | `standard`, `economy` | `standard` | проект |
| Модели субагентов | `SUBAGENT_MODEL_CODING`, `SUBAGENT_MODEL_ANALYSIS`, `SUBAGENT_MODEL_LIGHT` | model id клиента или пусто | модель клиента | после re-render/restart |
| Стиль ответов | `/caveman`, `CAVEMAN` | `on`, `auto`, `off` | `on` | проект; level может быть session-only |
| Лимит quick-fix | `QUICKFIX_MAX_LINES` | положительное число | `40` | проект |
| Быстрый путь отладки | `DEBUG_FAST_PATH` | `standard`, `extended`, `off` | `standard` | проект |
| Зависимости | `DEPENDENCY_MODE` | `fresh`, `locked` | `fresh` | проект |
| Выгрузка без fresh pass | `VERIFICATION_POLICY` | `warn`, `block` | `warn` | проект |

## Upstream `/litemode`

`/litemode` управляет `VERIFICATION_DEPTH` — глубиной статических проверок BSL для низкорисковых изменений.

| Режим | Поведение |
|---|---|
| `full` / `/litemode off` | Все три валидатора; обычный полный retry budget. |
| `standard` | Все три валидатора, но без открытого цикла повторов: после blocking fix обязателен один подтверждающий прогон. |
| `lite` / `/litemode on` | `syntaxcheck` остается обязательным для каждого измененного модуля; глубокие валидаторы запускаются для high-risk изменений или по явному запросу. |

При включении `lite` команда также ставит `UI_TESTING=off`. Возврат в `full` восстанавливает `manual`, только если значение все еще `off`; прежнее `auto` автоматически не запоминается. Транзакции, публичные `Экспорт`-контракты, RLS, подписки, регламентные задания и связанные метаданные всегда получают полную цепочку. Impact analysis и XML gates этим режимом не отключаются.

## ITL `/itl-litemode`

Это отдельный режим executable verification. Он не меняет `VERIFICATION_DEPTH` или `UI_TESTING`.

| Команда | `ITL_VANESSA_TESTING` | `ITL_CHECK_EVENT_LOG` |
|---|---:|---:|
| `/itl-litemode lite` или `on` | `off` | `off` |
| `/itl-litemode standard` | `auto` | `manual` |
| `/itl-litemode full` или `off` | `auto` | `auto` |
| `/itl-litemode status` | без изменения | без изменения |

`auto` разрешает компонент для implicit completion, `/itl-check`, repair и прямого запроса. `manual` — для команды, repair или прямого запроса. `off` запускается только при явном запросе именно этого компонента. Пропуск дает partial evidence и не считается fresh pass.

## `/economymode` и модели

`ORCHESTRATION=standard` оставляет обычную политику делегирования. `ORCHESTRATION=economy` передает больше исполнения субагентам, а решения, спецификации и финальная проверка остаются у головного агента.

Три model tier:

- `coding` — код, метаданные, архитектура;
- `analysis` — планирование, анализ, review, тесты и документация;
- `light` — поиск, scouting и небольшие механические задачи.

Пустой `SUBAGENT_MODEL_*` означает наследование модели AI-клиента. После изменения model id нужно перерендерить правила и перезапустить клиент; изменение `ORCHESTRATION` применяется без re-render.

### RTK

`rtk` — независимый third-party CLI proxy, а не значение `ORCHESTRATION`. Он сжимает вывод shell-команд до передачи модели. Built-in Read/Grep/Glob и MCP через него не проходят.

Настройка запускается `/economymode rtk` и требует отдельного подтверждения, потому что устанавливает user-global binary/hooks. После настройки клиент нужно перезапустить. RTK работает и при `ORCHESTRATION=standard`; удаление или переключение клиента не должно молча удалять его integration.

## `/caveman`

Постоянные значения записываются в `CAVEMAN`:

- `on` — default, краткий стиль для всех задач;
- `auto` — краткий стиль для разработки, обычный для анализа, review и документации;
- `off` — автоматическая активация выключена.

`/caveman lite|full|ultra` меняет только уровень текущей сессии. Фразы `caveman please` и `stop caveman` также действуют только в текущем чате и имеют приоритет над `.dev.env`. Режим влияет на форму ответа, но не на верификацию, модели или обязательные отчеты.

## Process tuning

- `QUICKFIX_MAX_LINES=40` — максимальный объем затронутых BSL-строк для локального quick-fix. Risk promotion важнее числа строк.
- `DEBUG_FAST_PATH=standard` — допускает сокращенный путь отладки только при непосредственно доказанной причине. `extended` расширяет применимость, `off` всегда требует полный диагностический цикл.

## Зависимости и политика результата

`DEPENDENCY_MODE=fresh` разрешает получать актуальные версии зависимостей в пределах configured source и записывает разрешенные версии/hashes в lock. `locked` использует только уже зафиксированные значения.

`VERIFICATION_POLICY=warn` требует явного подтверждения перед `/itl-result`, если проверка отсутствует, failed, stale, unknown или partial. `block` запрещает result и advanced close до fresh passed `/itl-check`; override отсутствует.
