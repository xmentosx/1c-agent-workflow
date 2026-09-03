# Режимы и пользовательские настройки

Настройки проекта находятся в локальном файле `.dev.env`, который Git не отслеживает. Большинство режимов можно переключить slash-командой или обычным запросом агенту. Полный перечень переменных приведен в [справочнике `.dev.env`](DEV-ENV-REFERENCE.ru.md).

## Что использовать обычно

Для большинства задач ничего менять не нужно:

```text
стандартная разработка
  ├─ статические проверки: VERIFICATION_DEPTH=standard
  ├─ YAxUnit: ITL_YAXUNIT_TESTING=auto
  ├─ Vanessa: ITL_VANESSA_TESTING=auto
  ├─ журнал регистрации: ITL_CHECK_EVENT_LOG=auto
  ├─ зависимости: DEPENDENCY_MODE=fresh
  └─ непроверенный результат: VERIFICATION_POLICY=warn
```

Штатные значения: `VERIFICATION_DEPTH=standard`, `UI_TESTING=manual`, `ORCHESTRATION=standard`, `ITL_ROUTINE_MODE=off`, `CAVEMAN=on`, `CAVEMAN_LEVEL=full`, `AGENT_MODEL=` (`auto`), `SUPPORT_GUARD=deny`, `ITL_YAXUNIT_TESTING=auto`, `ITL_VANESSA_TESTING=auto`, `ITL_CHECK_EVENT_LOG=auto`, `DEPENDENCY_MODE=fresh`, `VERIFICATION_POLICY=warn`.

Меняйте режим только ради понятной цели: уменьшить глубину низкорисковой статической проверки, вручную отключить компонент executable verification, выбрать экономную оркестрацию или запретить непроверенную выгрузку.

## Kilo Browser Automation и контекст

После инициализации, создания ветки и в `/itl-status` workflow показывает определённое состояние Kilo Browser Automation. Если `kilo-code.new.browserAutomation.enabled=true`, workflow рекомендует отключить этот скрытый Playwright MCP: он заметно увеличивает набор tools, контекст и расход токенов. Для веб-задач используйте workflow `agent-browser`; если он отсутствует, статус сразу показывает helper-команду установки. При `false` выводится только нормальный статус, при неизвестном состоянии — просьба проверить Kilo Settings. Workflow сам настройку Kilo не меняет.

`agent-browser` и Windows-MCP регистрируются напрямую через `stdio`: первый предпочтителен для веб-клиента 1С, второй нужен только для неизбежной автоматизации desktop/thick-client UI. Оба процесса запускает сам MCP-клиент; on-demand facade, фиксированные UI-порты и desktop lock не используются.

ITL не включает и не выключает Browser Automation и не создаёт для этого `.vscode/settings.json`. Если состояние нельзя однозначно определить из workspace, пользовательских настроек и default установленного Kilo, выводится `unknown`.

Для воспроизводимого замера попросите агента «замерь контекст». Диагностика умеет сделать один автоматический CLI baseline либо разобрать и сравнить чистые IDE-сессии. Для Browser A/B переключайте настройку вручную, перезагружайте Kilo и создавайте отдельную односообщенческую сессию для каждого состояния.

## Краткая карта

| Назначение | Команда/параметр | Значения | По умолчанию | Область действия |
|---|---|---|---|---|
| Глубина статических проверок `ai_rules_1c` | `/litemode`, `VERIFICATION_DEPTH` | `full`, `standard`, `lite` | `standard` | проект |
| Проверка веб-интерфейса по правилам `ai_rules_1c` | `UI_TESTING` | `auto`, `manual`, `off` | `manual` | проект |
| ITL YAxUnit | `/itl-litemode`, `ITL_YAXUNIT_TESTING` | `auto`, `manual`, `off` | `auto` | проект/worktree |
| ITL Vanessa Automation | `/itl-litemode`, `ITL_VANESSA_TESTING` | `auto`, `manual`, `off` | `auto` | проект/worktree |
| ITL журнал регистрации | `/itl-litemode`, `ITL_CHECK_EVENT_LOG` | `auto`, `manual`, `off` | `auto` | проект/worktree |
| Обновление source из хранилища 1С | `/itl-repository-mode`, `SOURCE_REPOSITORY_UPDATE_MODE` | `workflow`, `external` | `workflow` | основной `master` |
| Оркестрация | `/economymode`, `ORCHESTRATION` | `standard`, `economy` | `standard` | проект |
| Модели субагентов | `SUBAGENT_MODEL_CODING`, `SUBAGENT_MODEL_ANALYSIS`, `SUBAGENT_MODEL_LIGHT` | model id клиента или пусто | модель клиента | после re-render/restart |
| Профиль головной модели | `/rulesmodel`, `AGENT_MODEL` | `opus5`, `sonnet5`, `fable5`, `gpt56`, `auto` | `auto` | новый чат после смены |
| Защита объектов на поддержке | `SUPPORT_GUARD` | `deny`, `warn`, `off` | `deny` | сразу |
| Стиль ответов | `/caveman`, `CAVEMAN`, `CAVEMAN_LEVEL` | mode: `on`, `auto`, `off`; level: `lite`, `full`, `ultra` | `on/full` | проект; явный session override приоритетнее |
| Лимит quick-fix | `QUICKFIX_MAX_LINES` | положительное число | `40` | проект |
| Быстрый путь отладки | `DEBUG_FAST_PATH` | `standard`, `extended`, `off` | `standard` | проект |
| Зависимости | `DEPENDENCY_MODE` | `fresh`, `locked` | `fresh` | проект |
| Выгрузка без fresh pass | `VERIFICATION_POLICY` | `warn`, `block` | `warn` | проект |

## ITL `/itl-repository-mode`

Команда доступна только в основной worktree `master` и меняет локальный `.dev.env`, не создавая Git-изменений:

- `workflow` — перед фиксацией source в `master` ITL выполняет `/ConfigurationRepositoryUpdateCfg` и `/UpdateDBCfg`;
- `external` — пользователь обновляет source сам, а ITL только фиксирует её текущее состояние в `master` и latest-only seed;
- `status` — показать режим без изменения.

`SOURCE_USES_REPOSITORY` при этом остается `true`: режим не скрывает топологию хранилища, поэтому seed и базы веток по-прежнему безопасно отвязываются. Неизвестное значение блокирует синхронизацию до исправления режима, чтобы ITL не мутировал source по неясной политике.

## Статические проверки `ai_rules_1c`: `/litemode`

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

Обычные agent-facing маршруты используют `command` для `/itl-check` и `repair` для `/itl-verify-fix`, поэтому в них `auto` и `manual` запускают компонент одинаково. `implicit` зарезервирован для script-owned completion и сейчас не имеет production-caller. `off` запускается только при отдельном advanced-запросе именно этого компонента; обычные `/itl-check` и `/itl-verify-fix` его не переопределяют. Поэтому `standard` и `full` сейчас эквивалентны для обычного `/itl-check`. Пропуск дает partial evidence и не считается fresh pass; при `VERIFICATION_POLICY=block` после `lite` потребуется явная полная проверка до result/close.

## `/economymode` и модели

`ITL_ROUTINE_MODE=off` выполняет все `/itl*` в основном агенте и не создает управляемый `itl-routine`. `auto` оставляет `/itl`, `/itl-status` и `/itl-litemode` прямыми, а семь длинных команд делегирует только при явно заданном `SUBAGENT_MODEL_LIGHT`. `on` делегирует все десять команд и требует явную light-модель. Пустое или неизвестное значение безопасно означает `off`; routine никогда не наследует модель родительского агента.

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

Постоянный уровень хранится отдельно в `CAVEMAN_LEVEL=lite|full|ultra`; отсутствующее или невалидное значение означает `full`. `/caveman persist <level>` меняет только `CAVEMAN_LEVEL` и не включает `CAVEMAN`.

`/caveman lite|full|ultra` меняет только уровень текущей сессии и не пишет `.dev.env`. Фразы `caveman please` и `stop caveman` также действуют только в текущем чате. Приоритет: session override → `CAVEMAN`/`CAVEMAN_LEVEL` проекта → `on/full`. При `auto` все `itl-*` и `opsx-apply` используют Caveman, а `opsx-explore`, `opsx-propose` и `opsx-archive` — обычный стиль. Режим влияет на форму рабочего ответа и heartbeat, но не сокращает `userReport`, OpenSpec-артефакты, проверки, safety-контракты или обязательные отчеты.

## Настройка процесса

- `QUICKFIX_MAX_LINES=40` — максимальный объем затронутых BSL-строк для локального quick-fix. Risk promotion важнее числа строк.
- `DEBUG_FAST_PATH=standard` — допускает сокращенный путь отладки только при непосредственно доказанной причине. `extended` расширяет применимость, `off` всегда требует полный диагностический цикл.

## Зависимости и политика результата

`DEPENDENCY_MODE=fresh` разрешает получать актуальные версии зависимостей в пределах configured source и записывает разрешенные версии/hashes в lock. `locked` использует только уже зафиксированные значения.

`VERIFICATION_POLICY=warn` показывает заметное предупреждение, но не останавливает `/itl-result`, если проверка отсутствует, failed, stale, unknown или partial. `block` запрещает result до fresh passed `/itl-check`. Advanced `close-dev-branch` сохраняет отдельный явный override-контракт.
