# G3: оставшиеся клиенты и установленный PM5, 2026-10-21

**G3 / AC-39 не принят целиком.** Source `73f44caf65061bd290e0540b2952d3b72fc4f135`, runtime без изменений относительно `f53b9247`. Это квалификация и документация; код workflow, серверы и controlled fork не менялись. Точные inputs, SHA raw artifacts и границы — [JSON evidence](g3-clients-installed-2026-10-21.json). Результат дополняет [общую матрицу](g3-final-qualification-2026-10-20.md), а не создаёт новый ledger.

## Клиенты

Повтор существующего file reader дал **48/48** проверок: 12 adapters × Code/Graph × PM4/PM5. Это чтение файлов, а не доказательство активации. Нативные проверки выполнялись с отдельными HOME/USERPROFILE/XDG профилями; новые клиенты не устанавливались. Windows 11 Home build 26300, обычный пользователь.

| Adapter | Подтверждённая граница | Остаток |
|---|---|---|
| codex | Переиспользован прежний native core/API Code/Graph, ПРОФ → КОРП и reload proof на неизменённых runtime inputs | Desktop frontend и полный installed journey не приняты |
| kilocode | Обнаружен bundled CLI 7.8.15 вне PATH; native discovery и два disconnect/connect цикла passed | Функциональные tools, VS Code frontend и отсутствие повторного импорта не приняты |
| opencode | Desktop 1.18.11 обнаружен; file adapter passed | Отдельный CLI не найден, native desktop activation не проверена |
| cursor | Cursor 3.25.9 обнаружен; file adapter passed | Native IDE activation/reload не проверены |
| cline | File adapter passed | Расширение не найдено в проверенных VS Code/Cursor extension roots |
| claude-code | File adapter passed | CLI/расширение не найдены в проверенных местах |
| kimi | File adapter passed | CLI/расширение не найдены в проверенных местах |
| qwen | File adapter passed | CLI/расширение не найдены в проверенных местах |
| command-code | File adapter passed | CLI не найден в PATH |
| zcode | File adapter passed | CLI не найден в PATH |
| mimocode | File adapter passed | CLI не найден в PATH |
| pi | File adapter passed | CLI не найден в PATH |

VS Code 1.142.0 и расширения Kilo 7.8.12/7.8.15 присутствуют; это inventory, не frontend proof. Поддержка не сокращается. Следующий client proof должен использовать отдельный профиль и настоящий клиентский вызов, а не выдавать direct MCP transport или JSON parsing за клиентскую активацию.

## Kilo: соединение, повторный импорт и ограничение API

На прежнем source fixture `Контекст клиента PROF` Kilo разрешил ожидаемые `1c-code-metadata-mcp` и `1c-graph-metadata-mcp` к выбранным PM5 endpoints. Native `/mcp/{name}/disconnect` дал `disabled`, connect вернул `connected` для обеих ролей; два цикла заняли 4.060 s. Это connection proof, не tool read или config reload.

**G3-KILO-MULTICLIENT-ALIASES — подтверждённое integration finding.** В исходном workload сохранены все client config files. Kilo также импортировал `onec-code-metadata-mcp` / `onec-graph-metadata-mcp` из `opencode.json`: четыре connected имени для двух одинаковых физических endpoints. При загрузке клиент добавил `$schema: https://app.kilo.ai/config.json` и в `.kilo/kilo.json`, и в `opencode.json`; endpoint entries сохранены. Private profile не устраняет этот project-local импорт. Рост tool-schema/context cost возможен, но число токенов и факт загрузки всех схем в модель не измерены. Удаление OpenCode-файла или смена aliases ради pass не выполнялись.

**G3-KILO-TOOLS-API-404 — blocker интерфейса квалификации.** Реальный `/doc` объявляет `POST /experimental/mcp/call-tool` с `server/name/arguments`; две безопасные попытки Code `stats` в отдельных сохранённых runs получили от локального Kilo API HTTP 404 `NotFound`. Graph tool call не достигнут. Первопричина не установлена; это не доказанный дефект Code/Graph и не основание менять их серверы. Следующий шаг — поддерживаемый native tool путь Kilo, затем read/negative scope/reload на том же workload. Не добавляются клиентский bridge, provider patch или новый readiness barrier.

## Установленный PM5: совместимость и восстановление

Использован прежний отдельный stand из capsule:
`C:\itlj\g3-capsule-recovery-20261020\q Проект\develop-c2c570fe1ec5-b4338057d74f-e77efefc\project` и sibling `branch`.
Его installed workflow — **b4338057d74f88f2577daff6a828602170c7512f**, controlled fork r43 `987320be139b4ac0d28f1f5b0f2515f63c7f140f`. Это не установка текущего source `73f44caf/f53b9247`.

С отдельным synthetic catalog выполнены настоящие public `agent-1c.ps1` команды: preview → select → context, затем context соседней ветки → native Kilo discovery → **owned failure recovery restore**. Все эти команды завершились exit 0; соседняя ветка осталась `unbound`. Native клиент увидел две выбранные роли и три прежних common MCP (`agent-browser`, `itl-roctup-data`, `itl-vanessa-ui`). После restore новый процесс Kilo увидел только прежние три; выбранные Code/Graph entries отсутствуют. Общие MCP не удалялись.

Исходный driver run сохранён как **failed**: ошибочно ожидал всего два connected MCP вместо двух выбранных плюс три общих. Отдельный validator проверяет те же raw snapshots/logs как **owner recovery/discovery subset**, не переименовывает исходный run в uninterrupted pass и не меняет reproducer. Добавленную native Kilo строку `$schema` размером 52 bytes writer правомерно сохранил как чужую правку. Поэтому whole-file byte equality основного Kilo config **не выполнено**; исключение ровно этой строки в памяти даёт исходные bytes/SHA. Descriptor/dependency lock восстановлены точно; catalog ownership пуст, operation terminal `restored`. Ownership receipt не побайтно прежний: добавлена пустая owner-запись. Ручного отката файлов или удаления клиентской правки не было.

Оба Git HEAD и clean state сохранены: project `9f7f2e637c62bde39df0b50b7dd49ea9fb790c87`, branch `df9f63f00c2f3d627aec16b7cab1c1754f6f87c0`. Все четыре protected branch files неизменны. База **3295928320 bytes**, SHA-256 **c323a334fdd08907a31e783bc2f57e4dbacf98de192aff569a6a119d097ae045**, совпала до select, после select и после recovery. Init/update/new branch/downgrade/1C launches не выполнялись. Актуальный installed source, полные веточные и lifecycle journeys этим не приняты; PM4 installed stand отсутствует.

## Публичный context: данные есть, стандартный stdout их скрывает

**G3-CONTEXT-CLI-OUTPUT — подтверждённый source presentation defect, задача 3.5 / AC-08/13/20.** В новом child-process вызове текущего public context с прежним explicit Codex observation exit 0, но default PowerShell formatting показывает `projectDifferences: {customizations, customized}` и `sources: {System.Collections.Specialized.OrderedDictionary, ...}`. Значения source origin `qual-pm5corp`, usage `reference-product`, версии `5.0.3.66`, ограничения ПРОФ и результаты source observation напрямую не видны. 842 bytes неполного stdout не доказывают полезный bounded context.

При этом DTO корректен: тот же public helper с явным `| ConvertTo-Json -Depth 20` выдал selected projection размером 7725 UTF-8 bytes со всеми этими полями и прежним registry provenance. Это проверенное диагностическое продолжение, не исправление default CLI и не новая always-on инструкция. Отдельный `read-context-json.ps1` только нормализует UTF-8/Windows PowerShell environment и сериализует вывод существующего helper. Следующий owner-local шаг — bounded default renderer и regression настоящего child stdout для custom → typical / ПРОФ → КОРП, без второго resolver, новых probes или backend protocol. В этой квалификации runtime не исправлялся.

## Сохранность, стоимость и исправление прежнего evidence claim

Новая read-only context проверка отдельно записала **SHA и настоящий `stat.mtime_ns` до/после на 20 paths**: всё совпало, whole CLI 3.676 s, новых MCP/LLM calls 0. Это один diagnostic invocation, не Startup benchmark и не замена paired 20-warm измерений. Новый native Kilo discovery после restore также сохранил bytes/actual mtime четырёх файлов; 9.837 s включает запуск клиента/common MCP и не сравнивается с engineering целью добавочного Startup hook.

**Коррекция старого утверждения:** `Get-ItlMcpFileState` в `agent-1c.client-adapters.ps1` возвращает только SHA, не timestamp. В двух предыдущих source-model/PROF reports guard всех 20 paths доказывал bytes, но не их mtime. Исторические JSON сохранены; соответствующие MD получили ссылку на эту коррекцию. Отдельный explicit Python byte+mtime restore Codex config остаётся доказанным, как и независимые Startup receipt timestamp controls. Два файла source fixture уже изменены клиентом Kilo до нового read-only guard — это указанная выше schema normalization, а не незаявленная сохранность за весь день.

Семь прежних Gate 6 artifacts и capsule manifest SHA сверены read-only и неизменны. Старые stands/failed copies сохранены; активных fixture 1C процессов после прогона 0. Нативные Kilo процессы с private profiles завершены владельцем. Повторных Pester/Startup suites, model turns, Cognee и deploy нет; backend usage не инструментировался, token cost не измерялся. Глобальные MCP настройки не перенастраивались; хеши двух ранее наблюдённых personal config files совпали в проверенном интервале, что не расширяется до полного before-first-call снимка профиля.

## Ошибки harness и остающиеся условия

- Первый source-fixture compact wrapper не поддерживает catalog action; до installed writes сохранён failure. Следующий Pester-based source harness завис до полезного action result; точная причина неизвестна. После clean/native-process checks остановлен только exact owned source harness с проверкой script/creation time, не lifecycle/1C процесс. Его logs/snapshot сохранены.
- Первый Python transport не нормализовал PSModulePath, у PS5.1 отсутствовал Get-FileHash; повреждённый CP866 boundary отвергнут, до действий записи не дошло. Повтор использовал существующий Windows PowerShell environment helper и UTF-8. Это tooling failures, не новые workflow defects.
- PM5 corrected validation сохраняет исходный failed run и все strict descriptor/lock/DB/HEAD assertions; common MCP и native `$schema` не удалены ради pass. Новые client/API findings и CLI presentation defect остаются открытыми.

Приоритет продолжения у существующих owners: исправить default context presentation; разобрать Kilo project-local alias interoperability с сохранением исходного workload и custom settings; квалифицировать functional native Kilo API/frontend и остальные доступные frontends; затем актуальные installed journeys и отсутствующие PM4/Windows 10/Server terminal stands. Отсутствие готового стенда не отменяет поддержку. Это перечень остатка, не разрешение кода, установки клиентов или миграции.

Registry 3.5/5.2/5.4–5.6 и full AC-39 открыты. Memory consumer 4.2/G4, installed AC-43/G5 и AC-44 не реализованы/не приняты. Шесть областей, canonical home, Q1–Q7/D9/G2 и ai_rules_1c не меняются; Kilo aliases/schema не становятся business IDs или памятью. Обязательное выпускное наполнение registry 5.7/AC-36–38 прежнее. **Gate 6 не запускался и не исправлялся; G4, рабочая миграция и публикация не начинались.**
