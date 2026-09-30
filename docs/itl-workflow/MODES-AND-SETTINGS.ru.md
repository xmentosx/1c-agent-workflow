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

Штатные значения: `VERIFICATION_DEPTH=standard`, `UI_TESTING=manual`, `ORCHESTRATION=standard`, `ITL_ROUTINE_MODE=off`, `CAVEMAN=auto` (уровень `full` в текущей сессии), `AGENT_MODEL=` (`auto`), `SUPPORT_GUARD=deny`, `ITL_YAXUNIT_TESTING=auto`, `ITL_VANESSA_TESTING=auto`, `ITL_CHECK_EVENT_LOG=auto`, `DEPENDENCY_MODE=fresh`, `VERIFICATION_POLICY=warn`.

Меняйте режим только ради понятной цели: уменьшить глубину низкорисковой статической проверки, вручную отключить компонент executable verification, выбрать экономную оркестрацию или запретить непроверенную выгрузку.

## Kilo Browser Automation и контекст

После инициализации, создания ветки и в `/itl-status` workflow показывает определённое состояние Kilo Browser Automation. Если `kilo-code.new.browserAutomation.enabled=true`, workflow рекомендует отключить этот скрытый Playwright MCP: он заметно увеличивает набор tools, контекст и расход токенов. Для веб-задач используйте workflow `agent-browser`; если он отсутствует, статус сразу показывает helper-команду установки. При `false` выводится только нормальный статус, при неизвестном состоянии — просьба проверить Kilo Settings. Workflow сам настройку Kilo не меняет.

`agent-browser` и Windows-MCP регистрируются напрямую через `stdio`: первый предпочтителен для веб-клиента 1С, второй нужен только для неизбежной автоматизации desktop/thick-client UI. Оба процесса запускает сам MCP-клиент; on-demand facade, фиксированные UI-порты и desktop lock не используются.

В проекте можно подключить несколько клиентов через `aiRules.tools`; выбор клиента текущего вызова не меняет этот набор. ITL формирует ZCode MCP в `.zcode/config.json` → `mcp.servers`, MiMo Code — в `.mimocode/mimocode.json` → `mcp`, сохраняя соседние пользовательские поля и серверы. Если у MiMo Code уже есть `.mimocode/mimocode.jsonc`, helper сохраняет его и просит явно объединить настройки в JSON перед записью: параллельные JSON/JSONC не выдаются за проверенную конфигурацию. `itl-doctor` показывает настроенные клиенты и отдельно указывает, что наличие файла не доказывает подключение сервера, доступность инструмента в текущем чате или загрузку native-команды. Для Cline отдельно проверяйте вариант и версию CLI/editor, в котором открыт проект.

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
| Модели субагентов | `aiRules.modelTiersByClient.<client>.<tier>` в `.agent-1c/project.json` | model id данного клиента или пусто | модель данного клиента | после re-render/restart |
| Профиль головной модели | `/rulesmodel`, `AGENT_MODEL` | `opus5`, `sonnet5`, `fable5`, `gpt56`, `auto` | `auto` | новый чат после смены |
| Защита объектов на поддержке | `SUPPORT_GUARD` | `deny`, `warn`, `off` | `deny` | сразу |
| Стиль ответов | `/caveman`, `CAVEMAN` | mode: `on`, `auto`, `off`; session level: `lite`, `full`, `ultra` | `auto/full` | режим — проект, уровень — сессия |
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

Обычные agent-facing маршруты используют `command` для `/itl-check` и `repair` для `/itl-verify-fix`, поэтому в них `auto` и `manual` запускают компонент одинаково. `implicit` зарезервирован для script-owned completion и сейчас не имеет production-caller. `off` запускается только при отдельном advanced-запросе именно этого компонента; обычные `/itl-check` и `/itl-verify-fix` его не переопределяют. Явно запрошенный `/test-fix-loop` может на время своей `scenario-loop` сессии выполнить названную Vanessa-проверку при постоянном `off`, не записывая новое значение в `.dev.env`; широкий запрет UI и требования к целевой базе сохраняются. Сессия ограничена тремя раундами по умолчанию либо явно заданным N; после успешной проверки названного сценария тот же раунд выполняет нефильтрованную проверку всех разрешённых компонентов. Поэтому `standard` и `full` сейчас эквивалентны для обычного `/itl-check`. Пропуск дает partial evidence и не считается fresh pass; при `VERIFICATION_POLICY=block` после `lite` потребуется явная полная проверка до result/close.

## `/economymode` и модели

`ITL_ROUTINE_MODE=off` выполняет все `/itl*` в основном агенте и не создает управляемый `itl-routine`. `auto` оставляет `/itl`, `/itl-status`, `/itl-litemode` и `/itl-result` прямыми, а остальные подходящие длинные команды делегирует только при явно заданном `light` в карте соответствующего клиента. `on` делегирует все подходящие команды, кроме `/itl-result`, и требует явную light-модель для Kilo/OpenCode. `/itl-result` всегда остаётся в агенте текущего диалога: после неизменённого отчёта экспорта он добавляет итог уже выполненной задачи только из известного контекста, а без такого контекста возвращает один отчёт. Пустое или неизвестное значение безопасно означает `off`; routine никогда не наследует модель родительского агента.

`ORCHESTRATION=standard` оставляет обычную политику делегирования. `ORCHESTRATION=economy` передает больше исполнения субагентам, а решения, спецификации и финальная проверка остаются у головного агента.

Три model tier:

- `coding` — код, метаданные, архитектура;
- `analysis` — планирование, анализ, review, тесты и документация;
- `light` — поиск, scouting и небольшие механические задачи.

Прежние `SUBAGENT_MODEL_*` из `.dev.env` однократно закрепляются за исходным клиентом в `aiRules.modelTiersByClient`. Для нового клиента задайте его собственные `coding`, `analysis`, `light` или оставьте пустые значения: это наследование модели этого клиента. `itl-routine` в Kilo/OpenCode использует `light` именно своего клиента; режим `on` требует явного значения для каждого подключённого такого клиента. После изменения model id нужно перерендерить правила и перезапустить соответствующий клиент; изменение `ORCHESTRATION` применяется без re-render.

### RTK

`rtk` — независимый third-party CLI proxy, а не значение `ORCHESTRATION`. Он сжимает вывод shell-команд до передачи модели. Built-in Read/Grep/Glob и MCP через него не проходят.

Настройка запускается `/economymode rtk` и требует отдельного подтверждения, потому что устанавливает user-global binary/hooks. После настройки клиент нужно перезапустить. RTK работает и при `ORCHESTRATION=standard`; удаление или переключение клиента не должно молча удалять его integration.

## `/caveman`

Постоянные значения записываются в `CAVEMAN`:

- `on` — default, краткий стиль для всех задач;
- `auto` — краткий стиль для разработки, обычный для анализа, review и документации;
- `off` — автоматическая активация выключена.

Уровень не хранится в `.dev.env`: `/caveman lite|full|ultra` меняет его только для текущей сессии, по умолчанию `full`. Прежний `CAVEMAN_LEVEL` игнорируется. Фразы `caveman please` и `stop caveman` также действуют только в текущем чате. Приоритет: session override → `CAVEMAN` проекта → `auto/full`. При `auto` исполняющие `itl-*` и `opsx-apply` используют Caveman, а исследование, обсуждение, документация и остальные planning-фазы — обычный стиль. Режим не сокращает `userReport`, OpenSpec-артефакты, проверки, safety-контракты или обязательные отчеты.

## Хранилище OpenSpec

По умолчанию существующий и новый проект хранит `openspec/specs` и `openspec/changes` внутри своего checkout. Закреплённый OpenSpec CLI выбирается по `.agent-1c/dependency-lock.json`; глобальная команда `openspec` не определяет версию проекта. Если CLI ещё не подготовлен, выполните `agent-1c.ps1 -Action provision-openspec-cli` для этого checkout.

В этом выпуске ITL работает только с локальным `openspec/` текущего checkout. Значение `openSpec.storeId` в `.agent-1c/project.json`, `store:` в `openspec/config.yaml` и пользовательский `defaultStore` понимаются закреплённым CLI, но выбранное через них внешнее хранилище останавливает managed OpenSpec-маршрут с `OPEN_SPEC_EXTERNAL_STORE_DEFERRED` до записи. ITL сохраняет привязку и не создаёт локальную замену. Если нужно продолжить сейчас, явно выберите локальный workspace для этого проекта и решите, какие документы должны в нём находиться; само изменение выбора ничего не переносит. Поддержка внешнего store готовится отдельной задачей `add-external-openspec-store`.

Перед записью или работой с существующим change вызовите `agent-1c.ps1 -Action openspec-context -OpenSpecChangeId <change-id>`: ответ JSON связывает checkout, локальный root, CLI, change root и hash `.openspec.yaml`. Ошибка выбора внешнего store запрещает прямой обход через upstream CLI или bundle.

Read-only `doctor` показывает известные устаревшие директивы вне управляемого блока `USER-RULES.md` и в `LLM-RULES.md` с точной строкой и затронутой операцией. Он сохраняет пользовательский текст; обязательный `test-plan.md`, противоречащий согласованному OpenSpec-маршруту, останавливает только этот маршрут до адресного согласования. Старый `CAVEMAN_LEVEL` диагностируется, но не задаёт session level.

## Настройка процесса

- `QUICKFIX_MAX_LINES=40` — максимальный объем затронутых BSL-строк для локального quick-fix. Risk promotion важнее числа строк.
- `DEBUG_FAST_PATH=standard` — допускает сокращенный путь отладки только при непосредственно доказанной причине. `extended` расширяет применимость, `off` всегда требует полный диагностический цикл.

## Зависимости и политика результата

`DEPENDENCY_MODE=fresh` разрешает получать актуальные версии зависимостей в пределах configured source и записывает разрешенные версии/hashes в lock. `locked` использует только уже зафиксированные значения.

`VERIFICATION_POLICY=warn` показывает заметное предупреждение, но не останавливает `/itl-result`, если проверка отсутствует, failed, stale, unknown или partial. `block` запрещает result до fresh passed `/itl-check`. Advanced `close-dev-branch` сохраняет отдельный явный override-контракт.
